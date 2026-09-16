-- Kookboek: gerechten en kookbeurten.
--
-- Een gerecht (`dishes`) is iets anders dan een `meal`: dat bestaat om te loggen, dit om
-- te onthouden en te kiezen — link, foto, sterren, labels, en per keer dat je 't maakt een
-- kookbeurt (`dish_cooks`) met een notitie. Zie CONTEXT.md en docs/adr/0001.
--
-- `ingredients` is jsonb: [{id, text, amount, unit, productID}] — productID wijst naar
-- food_products.id. Geen foreign key: een product weggooien mag het gerecht niet raken,
-- de regel valt dan gewoon terug op tekst.
--
-- Herhaalbaar: `if not exists` en `create or replace`.

create table if not exists public.dishes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  url text not null default '',
  image_url text not null default '',
  rating int not null default 0,
  labels jsonb not null default '[]'::jsonb,
  ingredients jsonb not null default '[]'::jsonb,
  steps jsonb not null default '[]'::jsonb,
  servings float8 not null default 0,
  minutes int not null default 0,
  site_protein int not null default 0,
  site_kcal int not null default 0,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table if not exists public.dish_cooks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  dish_id uuid not null,
  date timestamptz not null,
  note text not null default '',
  done boolean not null default false,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

do $$
declare t text;
begin
  foreach t in array array['dishes','dish_cooks']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format(
      'create policy "own rows" on public.%I for all '
      || 'using ((select auth.uid()) = user_id) '
      || 'with check ((select auth.uid()) = user_id)', t);
    execute format('create index if not exists %I on public.%I (user_id)', t || '_user_idx', t);
    execute format('create index if not exists %I on public.%I (user_id, updated_at)', t || '_user_updated_idx', t);
    execute format('create unique index if not exists %I on public.%I (id, user_id)', t || '_id_user_key', t);
  end loop;
end $$;

-- sync_push_v2 opnieuw, met de twee tabellen erin. Verder identiek aan 0023.

create or replace function public.sync_push_v2(payload jsonb, full_replace boolean default false)
returns timestamptz
language plpgsql
security invoker
as $$
declare
  uid uuid := auth.uid();
  stamp timestamptz := now();
  tables text[] := array['weight_entries','protein_entries','set_entries','day_habits',
                         'routines','meals','scales','custom_habits','habit_logs',
                         'food_products','exercises','dishes','dish_cooks'];
  rec record;
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  -- Profiel: één rij, altijd volledig.
  if jsonb_typeof(payload->'profile') = 'object' then
    insert into public.profiles (user_id, name, age, height_cm, start_weight, goal_weight, start_date, goal_date, trainings_per_week, tracks_creatine, tracks_sleep, training_days, kcal_target, schedule, tracks_food, food_counts_for_score, updated_at)
    values (
      uid,
      payload#>>'{profile,name}',
      (payload#>>'{profile,age}')::int,
      (payload#>>'{profile,height_cm}')::int,
      (payload#>>'{profile,start_weight}')::float8,
      (payload#>>'{profile,goal_weight}')::float8,
      (payload#>>'{profile,start_date}')::timestamptz,
      (payload#>>'{profile,goal_date}')::timestamptz,
      (payload#>>'{profile,trainings_per_week}')::int,
      coalesce((payload#>>'{profile,tracks_creatine}')::boolean, true),
      coalesce((payload#>>'{profile,tracks_sleep}')::boolean, true),
      coalesce(payload#>'{profile,training_days}', '[]'::jsonb),
      coalesce((payload#>>'{profile,kcal_target}')::int, 0),
      coalesce(payload#>'{profile,schedule}', '{}'::jsonb),
      coalesce((payload#>>'{profile,tracks_food}')::boolean, true),
      coalesce((payload#>>'{profile,food_counts_for_score}')::boolean, true),
      stamp
    )
    on conflict (user_id) do update set
      name = excluded.name, age = excluded.age, height_cm = excluded.height_cm,
      start_weight = excluded.start_weight, goal_weight = excluded.goal_weight,
      start_date = excluded.start_date, goal_date = excluded.goal_date,
      trainings_per_week = excluded.trainings_per_week,
      tracks_creatine = excluded.tracks_creatine, tracks_sleep = excluded.tracks_sleep,
      training_days = excluded.training_days, kcal_target = excluded.kcal_target,
      schedule = excluded.schedule, tracks_food = excluded.tracks_food,
      food_counts_for_score = excluded.food_counts_for_score,
      updated_at = stamp
    -- Niets veranderd? Dan ook geen nieuwe updated_at, anders pullt het andere toestel
    -- het profiel bij elke push opnieuw op.
    where (public.profiles.name, public.profiles.age, public.profiles.height_cm,
           public.profiles.start_weight, public.profiles.goal_weight, public.profiles.start_date,
           public.profiles.goal_date, public.profiles.trainings_per_week,
           public.profiles.tracks_creatine, public.profiles.tracks_sleep,
           public.profiles.training_days, public.profiles.kcal_target, public.profiles.schedule,
           public.profiles.tracks_food, public.profiles.food_counts_for_score)
       is distinct from
          (excluded.name, excluded.age, excluded.height_cm,
           excluded.start_weight, excluded.goal_weight, excluded.start_date,
           excluded.goal_date, excluded.trainings_per_week,
           excluded.tracks_creatine, excluded.tracks_sleep,
           excluded.training_days, excluded.kcal_target, excluded.schedule,
           excluded.tracks_food, excluded.food_counts_for_score);
  end if;

  -- jsonb_populate_recordset koppelt de sleutels van de payload aan de kolommen van de
  -- tabel, met de juiste types. Een sleutel die ontbreekt wordt NULL — vandaar de
  -- coalesce op kolommen die de client niet meestuurt (scales.correction).
  --
  -- De conflictregel: een rij met een oudere updated_at overschrijft nooit een nieuwere.
  -- Er is geen uitzondering meer op die regel (#42): geen enkele push mag een nieuwere
  -- versie van een rij overschrijven met een oudere.

  insert into public.weight_entries as t (id, user_id, date, kg, scale, updated_at, deleted_at)
  select r.id, uid, r.date, r.kg, coalesce(r.scale, ''), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.weight_entries, coalesce(payload->'weights', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, kg = excluded.kg, scale = excluded.scale,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.protein_entries as t (id, user_id, date, grams, label, kcal, carbs, fat, meal, amount, unit, updated_at, deleted_at)
  select r.id, uid, r.date, r.grams, r.label, coalesce(r.kcal, 0), coalesce(r.carbs, 0),
         coalesce(r.fat, 0), coalesce(r.meal, ''), coalesce(r.amount, 0), coalesce(r.unit, 'g'),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.protein_entries, coalesce(payload->'proteins', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, grams = excluded.grams, label = excluded.label, kcal = excluded.kcal,
    carbs = excluded.carbs, fat = excluded.fat, meal = excluded.meal, amount = excluded.amount,
    unit = excluded.unit, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.set_entries as t (id, user_id, date, exercise, weight_kg, reps, dropset, failure, warmup, seconds, workout_id, updated_at, deleted_at)
  select r.id, uid, r.date, r.exercise, r.weight_kg, r.reps, coalesce(r.dropset, false),
         coalesce(r.failure, false), coalesce(r.warmup, false), coalesce(r.seconds, 0), r.workout_id,
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.set_entries, coalesce(payload->'sets', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, exercise = excluded.exercise, weight_kg = excluded.weight_kg,
    reps = excluded.reps, dropset = excluded.dropset, failure = excluded.failure,
    warmup = excluded.warmup, seconds = excluded.seconds, workout_id = excluded.workout_id,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.day_habits as t (id, user_id, date, creatine, slept_enough, note, bed_time, wake_time, sleep_quality, journal, workout_note, energy, mood, soreness, stress, exercise_notes, workout_name, workout_names, workout_notes, updated_at, deleted_at)
  select r.id, uid, r.date, coalesce(r.creatine, false), coalesce(r.slept_enough, false),
         coalesce(r.note, ''), r.bed_time, r.wake_time, coalesce(r.sleep_quality, 0),
         coalesce(r.journal, '[]'::jsonb), coalesce(r.workout_note, ''),
         coalesce(r.energy, 0), coalesce(r.mood, 0), coalesce(r.soreness, 0), coalesce(r.stress, 0),
         coalesce(r.exercise_notes, '{}'::jsonb), coalesce(r.workout_name, ''),
         coalesce(r.workout_names, '{}'::jsonb), coalesce(r.workout_notes, '{}'::jsonb),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.day_habits, coalesce(payload->'habits', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, creatine = excluded.creatine, slept_enough = excluded.slept_enough,
    note = excluded.note, bed_time = excluded.bed_time, wake_time = excluded.wake_time,
    sleep_quality = excluded.sleep_quality, journal = excluded.journal,
    workout_note = excluded.workout_note, energy = excluded.energy, mood = excluded.mood,
    soreness = excluded.soreness, stress = excluded.stress, exercise_notes = excluded.exercise_notes,
    workout_name = excluded.workout_name, workout_names = excluded.workout_names,
    workout_notes = excluded.workout_notes,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.routines as t (id, user_id, name, exercises, alternatives, targets, supersets, rest_by_exercise, created_at, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.exercises, '[]'::jsonb), coalesce(r.alternatives, '{}'::jsonb),
         coalesce(r.targets, '{}'::jsonb), coalesce(r.supersets, '{}'::jsonb),
         coalesce(r.rest_by_exercise, '{}'::jsonb), r.created_at, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.routines, coalesce(payload->'routines', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, exercises = excluded.exercises, alternatives = excluded.alternatives,
    targets = excluded.targets, supersets = excluded.supersets,
    rest_by_exercise = excluded.rest_by_exercise, created_at = excluded.created_at,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.meals as t (id, user_id, name, protein, kcal, created_at, servings, ingredients, favorite, updated_at, deleted_at)
  select r.id, uid, r.name, r.protein, coalesce(r.kcal, 0), r.created_at, coalesce(r.servings, 1),
         coalesce(r.ingredients, '[]'::jsonb), coalesce(r.favorite, false),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.meals, coalesce(payload->'meals', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, protein = excluded.protein, kcal = excluded.kcal,
    created_at = excluded.created_at, servings = excluded.servings,
    ingredients = excluded.ingredients, favorite = excluded.favorite,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.food_products as t (id, user_id, name, brand, barcode, protein100, kcal100, carbs100, fat100, favorite, image_url, serving_grams, serving_name, created_at, unit, last_amount, categories, portions, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.brand, ''), coalesce(r.barcode, ''), r.protein100, r.kcal100,
         coalesce(r.carbs100, 0), coalesce(r.fat100, 0), coalesce(r.favorite, false),
         coalesce(r.image_url, ''), coalesce(r.serving_grams, 0), coalesce(r.serving_name, ''),
         r.created_at, coalesce(r.unit, 'g'), coalesce(r.last_amount, 0), coalesce(r.categories, ''),
         coalesce(r.portions, '[]'::jsonb),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.food_products, coalesce(payload->'foods', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, brand = excluded.brand, barcode = excluded.barcode,
    protein100 = excluded.protein100, kcal100 = excluded.kcal100, carbs100 = excluded.carbs100,
    fat100 = excluded.fat100, favorite = excluded.favorite, image_url = excluded.image_url,
    serving_grams = excluded.serving_grams, serving_name = excluded.serving_name,
    created_at = excluded.created_at, unit = excluded.unit, last_amount = excluded.last_amount,
    categories = excluded.categories, portions = excluded.portions,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.exercises as t (id, user_id, name, muscle, type, created_at, secondary_muscles, archived, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.muscle, 'Overig'), coalesce(r.type, 'Overig'),
         r.created_at, coalesce(r.secondary_muscles, '[]'::jsonb), coalesce(r.archived, false),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.exercises, coalesce(payload->'exercises', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, muscle = excluded.muscle, type = excluded.type,
    created_at = excluded.created_at, secondary_muscles = excluded.secondary_muscles,
    archived = excluded.archived,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.scales as t (id, user_id, name, correction, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.correction, 0), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.scales, coalesce(payload->'scales', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, correction = excluded.correction,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.custom_habits as t (id, user_id, name, created_at, updated_at, deleted_at)
  select r.id, uid, r.name, r.created_at, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.custom_habits, coalesce(payload->'customHabits', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, created_at = excluded.created_at,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.habit_logs as t (id, user_id, name, date, updated_at, deleted_at)
  select r.id, uid, r.name, r.date, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.habit_logs, coalesce(payload->'habitLogs', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, date = excluded.date,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.dishes as t (id, user_id, name, url, image_url, rating, labels, ingredients, steps, servings, minutes, site_protein, site_kcal, created_at, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.url, ''), coalesce(r.image_url, ''), coalesce(r.rating, 0),
         coalesce(r.labels, '[]'::jsonb), coalesce(r.ingredients, '[]'::jsonb), coalesce(r.steps, '[]'::jsonb), coalesce(r.servings, 0),
         coalesce(r.minutes, 0), coalesce(r.site_protein, 0), coalesce(r.site_kcal, 0), r.created_at,
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.dishes, coalesce(payload->'dishes', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, url = excluded.url, image_url = excluded.image_url, rating = excluded.rating,
    labels = excluded.labels, ingredients = excluded.ingredients, steps = excluded.steps, servings = excluded.servings,
    minutes = excluded.minutes, site_protein = excluded.site_protein, site_kcal = excluded.site_kcal,
    created_at = excluded.created_at,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.dish_cooks as t (id, user_id, dish_id, date, note, done, created_at, updated_at, deleted_at)
  select r.id, uid, r.dish_id, r.date, coalesce(r.note, ''), coalesce(r.done, false), r.created_at,
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.dish_cooks, coalesce(payload->'cooks', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    dish_id = excluded.dish_id, date = excluded.date, note = excluded.note, done = excluded.done,
    created_at = excluded.created_at,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  -- Verwijderingen. De client stuurt ze apart mee: de rij zelf heeft hij niet meer, dus
  -- alleen tabel + id. De tabelnaam gaat door een whitelist voordat hij in dynamische SQL
  -- belandt.
  for rec in
    select e->>'table' as tbl, (e->>'id')::uuid as row_id,
           coalesce((e->>'deleted_at')::timestamptz, stamp) as at
    from jsonb_array_elements(coalesce(payload->'deletions', '[]'::jsonb)) e
  loop
    if not (rec.tbl = any (tables)) then
      raise exception 'onbekende tabel in deletions: %', rec.tbl;
    end if;
    execute format('update public.%I set deleted_at = $1, updated_at = $1 '
                || 'where id = $2 and user_id = $3 and deleted_at is null', rec.tbl)
      using rec.at, rec.row_id, uid;
  end loop;

  return stamp;

exception
  -- Een id uit de payload dat van een andere gebruiker is, valt buiten het conflictdoel
  -- (id, user_id) en loopt stuk op de primary key. Afwijzen zonder te vertellen wélk id
  -- al bestaat en van wie.
  when unique_violation then
    raise exception 'sync afgewezen: de payload bevat een id dat niet van deze gebruiker is'
      using errcode = '23505';
end;
$$;

-- sync_pull met de twee nieuwe sleutels erbij; verder identiek aan 0014.

create or replace function public.sync_pull(since timestamptz default null)
returns jsonb
language sql
security invoker
stable
as $$
  select jsonb_build_object(
    'server_time', now(),
    'full', since is null,
    'profile', (select to_jsonb(p) from public.profiles p
                where p.user_id = (select auth.uid())
                  and (since is null or p.updated_at >= since)),
    'weights', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.weight_entries x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'proteins', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.protein_entries x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'sets', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.set_entries x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'habits', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.day_habits x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'routines', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.routines x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'meals', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.meals x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'foods', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.food_products x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'exercises', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.exercises x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'scales', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.scales x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'customHabits', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.custom_habits x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'habitLogs', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.habit_logs x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'dishes', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.dishes x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null)),
    'cooks', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from public.dish_cooks x
                where x.user_id = (select auth.uid())
                  and (since is null or x.updated_at >= since)
                  and (since is not null or x.deleted_at is null))
  );
$$;

create or replace function public.sync_prune_tombstones(older_than interval default '90 days')
returns void
language plpgsql
security invoker
as $$
declare t text;
begin
  foreach t in array array['weight_entries','protein_entries','set_entries','day_habits',
                           'routines','meals','scales','custom_habits','habit_logs',
                           'food_products','exercises','dishes','dish_cooks']
  loop
    execute format('delete from public.%I where deleted_at is not null and deleted_at < now() - $1', t)
      using older_than;
  end loop;
end $$;
