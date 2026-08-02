-- Built — Supabase als single source of truth.
-- Idempotent: dit hele bestand mag je opnieuw draaien (SQL Editor → Run).

create table if not exists public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  age int not null,
  height_cm int not null,
  start_weight float8 not null,
  goal_weight float8 not null,
  start_date timestamptz not null,
  goal_date timestamptz not null,
  trainings_per_week int not null
);
alter table public.profiles add column if not exists tracks_creatine boolean not null default true;
alter table public.profiles add column if not exists tracks_sleep boolean not null default true;
alter table public.profiles add column if not exists training_days jsonb not null default '[]';
alter table public.protein_entries add column if not exists meal text not null default '';
alter table public.protein_entries add column if not exists carbs int not null default 0;
alter table public.protein_entries add column if not exists fat int not null default 0;
-- Portie zoals gelogd; 0 = oudere invoer zonder portie (dan blijft bewerken op macro-niveau).
alter table public.protein_entries add column if not exists amount float8 not null default 0;
alter table public.protein_entries add column if not exists unit   text   not null default 'g';
alter table public.profiles add column if not exists kcal_target int not null default 0;
alter table public.meals add column if not exists favorite boolean not null default false;

create table if not exists public.food_products (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  brand text not null default '',
  barcode text not null default '',
  protein100 float8 not null,
  kcal100 float8 not null,
  carbs100 float8 not null default 0,
  fat100 float8 not null default 0,
  favorite boolean not null default false,
  created_at timestamptz not null
);
alter table public.food_products add column if not exists image_url text not null default '';
alter table public.food_products add column if not exists serving_grams float8 not null default 0;
alter table public.routines add column if not exists alternatives jsonb not null default '{}';
alter table public.routines add column if not exists targets jsonb not null default '{}';
alter table public.routines add column if not exists supersets jsonb not null default '{}';
alter table public.routines add column if not exists rest_by_exercise jsonb not null default '{}';
alter table public.profiles add column if not exists schedule jsonb not null default '{}';
alter table public.profiles add column if not exists tracks_food boolean not null default true;
-- tracks_food haalt eten helemaal weg; deze bepaalt alleen of eiwit meeweegt in de score.
alter table public.profiles add column if not exists food_counts_for_score boolean not null default true;

create table if not exists public.exercises (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  muscle text not null default 'Overig',
  type text not null default 'Overig',
  created_at timestamptz not null
);
alter table public.food_products add column if not exists serving_name text not null default '';
-- 'g' of 'ml' per product, plus de laatst gelogde portie en de OFF-categorieën.
alter table public.food_products add column if not exists unit        text   not null default 'g';
alter table public.food_products add column if not exists last_amount float8 not null default 0;
alter table public.food_products add column if not exists categories  text   not null default '';

create table if not exists public.weight_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  kg float8 not null,
  scale text not null default ''
);

create table if not exists public.protein_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  grams int not null,
  label text not null,
  kcal int not null default 0
);

create table if not exists public.set_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  exercise text not null,
  weight_kg float8 not null,
  reps int not null
);
alter table public.set_entries add column if not exists dropset boolean not null default false;
alter table public.set_entries add column if not exists failure boolean not null default false;
alter table public.set_entries add column if not exists seconds int not null default 0;

create table if not exists public.day_habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  creatine boolean not null default false,
  slept_enough boolean not null default false,
  note text not null default '',
  bed_time timestamptz,
  wake_time timestamptz,
  sleep_quality int not null default 0,
  journal jsonb not null default '[]',
  workout_note text not null default '',
  energy int not null default 0,
  mood int not null default 0,
  soreness int not null default 0,
  stress int not null default 0,
  -- Notitie per oefening; verving de geparsede "Naam: tekst"-regels in `note`.
  exercise_notes jsonb not null default '{}'::jsonb
);

create table if not exists public.routines (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  exercises jsonb not null default '[]',
  created_at timestamptz not null
);

create table if not exists public.meals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  protein int not null,
  kcal int not null default 0,
  created_at timestamptz not null,
  servings float8 not null default 1,
  ingredients jsonb not null default '[]'
);

create table if not exists public.scales (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  correction float8 not null default 0
);

create table if not exists public.custom_habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  created_at timestamptz not null
);

create table if not exists public.habit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null,
  date timestamptz not null
);

-- Row level security: iedereen kan alleen zijn eigen rijen zien/schrijven.
do $$
declare t text;
begin
  foreach t in array array['profiles','weight_entries','protein_entries','set_entries','day_habits','routines','meals','scales','custom_habits','habit_logs','food_products','exercises']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own rows" on public.%I', t);
    -- (select auth.uid()) i.p.v. auth.uid(): met de subquery maakt de planner er een
    -- InitPlan van — één evaluatie per query in plaats van één per rij.
    execute format(
      'create policy "own rows" on public.%I for all '
      || 'using ((select auth.uid()) = user_id) '
      || 'with check ((select auth.uid()) = user_id)', t);
    execute format('create index if not exists %I on public.%I (user_id)', t || '_user_idx', t);
  end loop;
end $$;

-- Delta-sync: adresseerbare rijen (client levert het id), een spoor van wanneer een rij
-- gewijzigd is, en tombstones voor wat verwijderd is. De unieke index op (id, user_id) is
-- het conflictdoel van de upsert in sync_push_v2 — op `id` alleen zou een client een id
-- van iemand anders kunnen meesturen.
do $$
declare t text;
begin
  foreach t in array array['weight_entries','protein_entries','set_entries','day_habits',
                           'routines','meals','scales','custom_habits','habit_logs',
                           'food_products','exercises']
  loop
    execute format('alter table public.%I add column if not exists updated_at timestamptz not null default now()', t);
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    execute format('create index if not exists %I on public.%I (user_id, updated_at)', t || '_user_updated_idx', t);
    execute format('create unique index if not exists %I on public.%I (id, user_id)', t || '_id_user_key', t);
  end loop;
end $$;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

-- Atomaire push: vervangt alle data van de ingelogde gebruiker in één transactie,
-- zodat netwerkuitval nooit een half-gewiste server achterlaat.
--
-- Dit is v1: full-replace. Blijft staan zolang er clients in het veld zijn die 'm
-- aanroepen; nieuwe clients gebruiken sync_push_v2 (onderaan dit bestand).
create or replace function public.sync_push(payload jsonb)
returns void
language plpgsql
security invoker
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;

  if jsonb_typeof(payload->'profile') = 'object' then
    insert into public.profiles (user_id, name, age, height_cm, start_weight, goal_weight, start_date, goal_date, trainings_per_week, tracks_creatine, tracks_sleep, training_days, kcal_target, schedule, tracks_food, food_counts_for_score)
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
      coalesce((payload#>>'{profile,food_counts_for_score}')::boolean, true)
    )
    on conflict (user_id) do update set
      name = excluded.name,
      age = excluded.age,
      height_cm = excluded.height_cm,
      start_weight = excluded.start_weight,
      goal_weight = excluded.goal_weight,
      start_date = excluded.start_date,
      goal_date = excluded.goal_date,
      trainings_per_week = excluded.trainings_per_week,
      tracks_creatine = excluded.tracks_creatine,
      tracks_sleep = excluded.tracks_sleep,
      training_days = excluded.training_days,
      kcal_target = excluded.kcal_target,
      schedule = excluded.schedule,
      tracks_food = excluded.tracks_food,
      food_counts_for_score = excluded.food_counts_for_score;
  end if;

  delete from public.weight_entries where user_id = uid;
  insert into public.weight_entries (user_id, date, kg, scale)
    select uid, (e->>'date')::timestamptz, (e->>'kg')::float8, coalesce(e->>'scale', '')
    from jsonb_array_elements(coalesce(payload->'weights', '[]'::jsonb)) e;

  delete from public.protein_entries where user_id = uid;
  insert into public.protein_entries (user_id, date, grams, label, kcal, carbs, fat, meal, amount, unit)
    select uid, (e->>'date')::timestamptz, (e->>'grams')::int, e->>'label', coalesce((e->>'kcal')::int, 0),
           coalesce((e->>'carbs')::int, 0), coalesce((e->>'fat')::int, 0),
           coalesce(e->>'meal', ''),
           coalesce((e->>'amount')::float8, 0), coalesce(e->>'unit', 'g')
    from jsonb_array_elements(coalesce(payload->'proteins', '[]'::jsonb)) e;

  delete from public.set_entries where user_id = uid;
  insert into public.set_entries (user_id, date, exercise, weight_kg, reps, dropset, failure, seconds)
    select uid, (e->>'date')::timestamptz, e->>'exercise', (e->>'weight_kg')::float8, (e->>'reps')::int,
           coalesce((e->>'dropset')::boolean, false), coalesce((e->>'failure')::boolean, false),
           coalesce((e->>'seconds')::int, 0)
    from jsonb_array_elements(coalesce(payload->'sets', '[]'::jsonb)) e;

  delete from public.day_habits where user_id = uid;
  insert into public.day_habits (user_id, date, creatine, slept_enough, note, bed_time, wake_time, sleep_quality, journal, workout_note, energy, mood, soreness, stress, exercise_notes)
    select uid, (e->>'date')::timestamptz, (e->>'creatine')::boolean, (e->>'slept_enough')::boolean,
           coalesce(e->>'note', ''), (e->>'bed_time')::timestamptz, (e->>'wake_time')::timestamptz,
           coalesce((e->>'sleep_quality')::int, 0),
           coalesce(e->'journal', '[]'::jsonb), coalesce(e->>'workout_note', ''),
           coalesce((e->>'energy')::int, 0), coalesce((e->>'mood')::int, 0),
           coalesce((e->>'soreness')::int, 0), coalesce((e->>'stress')::int, 0),
           coalesce(e->'exercise_notes', '{}'::jsonb)
    from jsonb_array_elements(coalesce(payload->'habits', '[]'::jsonb)) e;

  delete from public.routines where user_id = uid;
  insert into public.routines (user_id, name, exercises, alternatives, targets, supersets, rest_by_exercise, created_at)
    select uid, e->>'name', coalesce(e->'exercises', '[]'::jsonb),
           coalesce(e->'alternatives', '{}'::jsonb), coalesce(e->'targets', '{}'::jsonb),
           coalesce(e->'supersets', '{}'::jsonb), coalesce(e->'rest_by_exercise', '{}'::jsonb),
           (e->>'created_at')::timestamptz
    from jsonb_array_elements(coalesce(payload->'routines', '[]'::jsonb)) e;

  delete from public.meals where user_id = uid;
  insert into public.meals (user_id, name, protein, kcal, created_at, servings, ingredients, favorite)
    select uid, e->>'name', (e->>'protein')::int, coalesce((e->>'kcal')::int, 0),
           (e->>'created_at')::timestamptz, coalesce((e->>'servings')::float8, 1),
           coalesce(e->'ingredients', '[]'::jsonb), coalesce((e->>'favorite')::boolean, false)
    from jsonb_array_elements(coalesce(payload->'meals', '[]'::jsonb)) e;

  delete from public.food_products where user_id = uid;
  insert into public.food_products (user_id, name, brand, barcode, protein100, kcal100, carbs100, fat100, favorite, image_url, serving_grams, serving_name, created_at, unit, last_amount, categories)
    select uid, e->>'name', coalesce(e->>'brand', ''), coalesce(e->>'barcode', ''),
           (e->>'protein100')::float8, (e->>'kcal100')::float8,
           coalesce((e->>'carbs100')::float8, 0), coalesce((e->>'fat100')::float8, 0),
           coalesce((e->>'favorite')::boolean, false), coalesce(e->>'image_url', ''),
           coalesce((e->>'serving_grams')::float8, 0), coalesce(e->>'serving_name', ''), (e->>'created_at')::timestamptz,
           coalesce(e->>'unit', 'g'), coalesce((e->>'last_amount')::float8, 0), coalesce(e->>'categories', '')
    from jsonb_array_elements(coalesce(payload->'foods', '[]'::jsonb)) e;

  delete from public.exercises where user_id = uid;
  insert into public.exercises (user_id, name, muscle, type, created_at)
    select uid, e->>'name', coalesce(e->>'muscle', 'Overig'), coalesce(e->>'type', 'Overig'),
           (e->>'created_at')::timestamptz
    from jsonb_array_elements(coalesce(payload->'exercises', '[]'::jsonb)) e;

  delete from public.scales where user_id = uid;
  insert into public.scales (user_id, name, correction)
    select uid, e->>'name', coalesce((e->>'correction')::float8, 0)
    from jsonb_array_elements(coalesce(payload->'scales', '[]'::jsonb)) e;

  delete from public.custom_habits where user_id = uid;
  insert into public.custom_habits (user_id, name, created_at)
    select uid, e->>'name', (e->>'created_at')::timestamptz
    from jsonb_array_elements(coalesce(payload->'customHabits', '[]'::jsonb)) e;

  delete from public.habit_logs where user_id = uid;
  insert into public.habit_logs (user_id, name, date)
    select uid, e->>'name', (e->>'date')::timestamptz
    from jsonb_array_elements(coalesce(payload->'habitLogs', '[]'::jsonb)) e;
end;
$$;

-- Account verwijderen vanuit de app (App Store 5.1.1(v)). security definer draait als
-- eigenaar (postgres), die auth.users mag wissen; de on-delete-cascade ruimt alle
-- public.* rijen van de gebruiker op.
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

-- MARK: - Delta-sync (v2)
--
-- Toegevoegd in migration 0014. sync_push_v2 raakt alleen de meegestuurde rijen; sync_pull
-- geeft alleen terug wat sinds een tijdstip gewijzigd is.


-- `full_replace = false` (het normale pad): alleen de meegestuurde rijen worden geraakt.
-- Een rij die de client niet noemt blijft staan zoals hij is.
--
-- `full_replace = true`: dit toestel is de waarheid. Alles wat de client níet meestuurt
-- wordt als tombstone gemarkeerd, en de conflictregel wordt genegeerd. Dit is wat "Sync
-- nu" in Profiel doet, en waar de app op terugvalt als hij niet weet wat er sinds de
-- laatste push gewijzigd is (koude start met openstaande wijzigingen).
--
-- Retourneert de servertijd; die bewaart de client als anker voor de volgende pull.
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
                         'food_products','exercises'];
  keys   text[] := array['weights','proteins','sets','habits',
                         'routines','meals','scales','customHabits','habitLogs',
                         'foods','exercises'];
  rec record;
  i int;
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
  -- Bij full_replace vervalt die regel — dan is dit toestel per definitie de waarheid.

  insert into public.weight_entries as t (id, user_id, date, kg, scale, updated_at, deleted_at)
  select r.id, uid, r.date, r.kg, coalesce(r.scale, ''), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.weight_entries, coalesce(payload->'weights', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, kg = excluded.kg, scale = excluded.scale,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.protein_entries as t (id, user_id, date, grams, label, kcal, carbs, fat, meal, amount, unit, updated_at, deleted_at)
  select r.id, uid, r.date, r.grams, r.label, coalesce(r.kcal, 0), coalesce(r.carbs, 0),
         coalesce(r.fat, 0), coalesce(r.meal, ''), coalesce(r.amount, 0), coalesce(r.unit, 'g'),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.protein_entries, coalesce(payload->'proteins', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, grams = excluded.grams, label = excluded.label, kcal = excluded.kcal,
    carbs = excluded.carbs, fat = excluded.fat, meal = excluded.meal, amount = excluded.amount,
    unit = excluded.unit, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.set_entries as t (id, user_id, date, exercise, weight_kg, reps, dropset, failure, seconds, updated_at, deleted_at)
  select r.id, uid, r.date, r.exercise, r.weight_kg, r.reps, coalesce(r.dropset, false),
         coalesce(r.failure, false), coalesce(r.seconds, 0), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.set_entries, coalesce(payload->'sets', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, exercise = excluded.exercise, weight_kg = excluded.weight_kg,
    reps = excluded.reps, dropset = excluded.dropset, failure = excluded.failure,
    seconds = excluded.seconds, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.day_habits as t (id, user_id, date, creatine, slept_enough, note, bed_time, wake_time, sleep_quality, journal, workout_note, energy, mood, soreness, stress, exercise_notes, updated_at, deleted_at)
  select r.id, uid, r.date, coalesce(r.creatine, false), coalesce(r.slept_enough, false),
         coalesce(r.note, ''), r.bed_time, r.wake_time, coalesce(r.sleep_quality, 0),
         coalesce(r.journal, '[]'::jsonb), coalesce(r.workout_note, ''),
         coalesce(r.energy, 0), coalesce(r.mood, 0), coalesce(r.soreness, 0), coalesce(r.stress, 0),
         coalesce(r.exercise_notes, '{}'::jsonb), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.day_habits, coalesce(payload->'habits', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, creatine = excluded.creatine, slept_enough = excluded.slept_enough,
    note = excluded.note, bed_time = excluded.bed_time, wake_time = excluded.wake_time,
    sleep_quality = excluded.sleep_quality, journal = excluded.journal,
    workout_note = excluded.workout_note, energy = excluded.energy, mood = excluded.mood,
    soreness = excluded.soreness, stress = excluded.stress, exercise_notes = excluded.exercise_notes,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

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
  where full_replace or t.updated_at <= excluded.updated_at;

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
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.food_products as t (id, user_id, name, brand, barcode, protein100, kcal100, carbs100, fat100, favorite, image_url, serving_grams, serving_name, created_at, unit, last_amount, categories, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.brand, ''), coalesce(r.barcode, ''), r.protein100, r.kcal100,
         coalesce(r.carbs100, 0), coalesce(r.fat100, 0), coalesce(r.favorite, false),
         coalesce(r.image_url, ''), coalesce(r.serving_grams, 0), coalesce(r.serving_name, ''),
         r.created_at, coalesce(r.unit, 'g'), coalesce(r.last_amount, 0), coalesce(r.categories, ''),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.food_products, coalesce(payload->'foods', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, brand = excluded.brand, barcode = excluded.barcode,
    protein100 = excluded.protein100, kcal100 = excluded.kcal100, carbs100 = excluded.carbs100,
    fat100 = excluded.fat100, favorite = excluded.favorite, image_url = excluded.image_url,
    serving_grams = excluded.serving_grams, serving_name = excluded.serving_name,
    created_at = excluded.created_at, unit = excluded.unit, last_amount = excluded.last_amount,
    categories = excluded.categories, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.exercises as t (id, user_id, name, muscle, type, created_at, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.muscle, 'Overig'), coalesce(r.type, 'Overig'),
         r.created_at, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.exercises, coalesce(payload->'exercises', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, muscle = excluded.muscle, type = excluded.type,
    created_at = excluded.created_at, updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.scales as t (id, user_id, name, correction, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.correction, 0), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.scales, coalesce(payload->'scales', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, correction = excluded.correction,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.custom_habits as t (id, user_id, name, created_at, updated_at, deleted_at)
  select r.id, uid, r.name, r.created_at, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.custom_habits, coalesce(payload->'customHabits', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, created_at = excluded.created_at,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

  insert into public.habit_logs as t (id, user_id, name, date, updated_at, deleted_at)
  select r.id, uid, r.name, r.date, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.habit_logs, coalesce(payload->'habitLogs', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, date = excluded.date,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where full_replace or t.updated_at <= excluded.updated_at;

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

  -- Volledige push: wat de client níet noemt, bestaat niet meer. Als tombstone, niet als
  -- delete — anders ziet een tweede toestel de verwijdering nooit.
  if full_replace then
    for i in 1 .. array_length(tables, 1) loop
      execute format(
        'update public.%I t set deleted_at = $1, updated_at = $1 '
     || 'where t.user_id = $2 and t.deleted_at is null '
     || 'and not exists (select 1 from jsonb_array_elements($3) e where (e->>''id'')::uuid = t.id)',
        tables[i])
        using stamp, uid, coalesce(payload->keys[i], '[]'::jsonb);
    end loop;
  end if;

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

-- MARK: - Pull

-- `since = null` geeft alles (verse install, of "Data ophalen van server"); met een
-- tijdstip alleen wat sindsdien gewijzigd is, inclusief tombstones zodat de client weet
-- wat hij lokaal moet verwijderen. Bij een volledige pull blijven tombstones weg — daar
-- valt niets te verwijderen.
--
-- De grens is inclusief (`>=`). Een rij die precies tijdens de vorige pull geschreven werd
-- komt dan een keer dubbel mee; toepassen is idempotent, dus dat is onschadelijk — een
-- gemiste rij zou dat niet zijn.
--
-- `server_time` is het anker voor de vólgende pull. Bewust de servertijd en niet de klok
-- van het toestel: klokverschil zou anders wijzigingen laten missen.
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
                  and (since is not null or x.deleted_at is null))
  );
$$;

-- Tombstones die elke client allang gezien heeft, hoeven niet te blijven staan. 90 dagen
-- is ruim: een toestel dat langer offline was, doet sowieso een volledige pull.
create or replace function public.sync_prune_tombstones(older_than interval default '90 days')
returns void
language plpgsql
security invoker
as $$
declare t text;
begin
  foreach t in array array['weight_entries','protein_entries','set_entries','day_habits',
                           'routines','meals','scales','custom_habits','habit_logs',
                           'food_products','exercises']
  loop
    execute format('delete from public.%I where deleted_at is not null and deleted_at < now() - $1', t)
      using older_than;
  end loop;
end $$;


-- MARK: - OpenFoodFacts-cache (migration 0016)
--
-- Gedeelde, niet-persoonlijke data: lezen mag iedereen die is aangemeld, schrijven doet
-- alleen de off-proxy edge function met de service role.

create table if not exists public.off_products (
  -- 'search:volle melk' of 'barcode:8712800147008'. Eén sleutel per soort vraag, zodat
  -- beide paden dezelfde tabel gebruiken.
  cache_key text primary key,
  payload jsonb not null,
  fetched_at timestamptz not null default now()
);

-- Verlopen entries opruimen kan op fetched_at.
create index if not exists off_products_fetched_idx on public.off_products (fetched_at);

alter table public.off_products enable row level security;

drop policy if exists "off cache readable" on public.off_products;
create policy "off cache readable" on public.off_products
  for select
  to authenticated
  using (true);

-- Geen insert/update/delete-policy: schrijven kan alleen met de service role, en die gaat
-- langs RLS heen. Zo kan een client de cache niet vergiftigen.

revoke insert, update, delete on public.off_products from anon, authenticated;

-- Producten wijzigen zelden; weken tot maanden is ruim genoeg. Draai dit periodiek, of
-- laat de function verlopen entries zelf verversen bij een hit.
create or replace function public.off_prune(older_than interval default '90 days')
returns void
language sql
security invoker
as $$
  delete from public.off_products where fetched_at < now() - older_than;
$$;


-- MARK: - Autovacuum op de tabellen met het meeste rij-verloop (migration 0015)
--
-- Nodig zolang er clients zijn die nog sync_push (v1, full-replace) aanroepen. Daarna mag
-- dit terug naar de standaard met `alter table ... reset (...)`.

do $$
declare t text;
begin
  foreach t in array array['set_entries','protein_entries','day_habits',
                           'weight_entries','food_products']
  loop
    execute format('alter table public.%I set ('
                || 'autovacuum_vacuum_scale_factor = 0.02, '
                || 'autovacuum_vacuum_cost_delay = 0, '
                || 'autovacuum_analyze_scale_factor = 0.05)', t);
  end loop;
end $$;


-- MARK: - Anonieme accounts opruimen (migration 0017)

create or replace function public.stale_anonymous_users(older_than interval default '90 days')
returns table (id uuid, created_at timestamptz, last_sign_in_at timestamptz)
language sql
security definer
set search_path = ''
as $$
  select u.id, u.created_at, u.last_sign_in_at
  from auth.users u
  where u.is_anonymous
    and u.created_at < now() - older_than
    and coalesce(u.last_sign_in_at, u.created_at) < now() - older_than
    and not exists (select 1 from public.profiles        p where p.user_id  = u.id)
    and not exists (select 1 from public.set_entries     s where s.user_id  = u.id)
    and not exists (select 1 from public.weight_entries  w where w.user_id  = u.id)
    and not exists (select 1 from public.protein_entries e where e.user_id  = u.id)
    and not exists (select 1 from public.day_habits      h where h.user_id  = u.id)
    and not exists (select 1 from public.routines        r where r.user_id  = u.id);
$$;

create or replace function public.purge_stale_anonymous(older_than interval default '90 days')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare removed integer;
begin
  delete from auth.users
  where id in (select id from public.stale_anonymous_users(older_than));
  get diagnostics removed = row_count;
  return removed;
end;
$$;

-- Niet aanroepbaar vanaf de app. Dit draait alleen als geplande taak.
revoke all on function public.stale_anonymous_users(interval) from public, anon, authenticated;
revoke all on function public.purge_stale_anonymous(interval) from public, anon, authenticated;

-- Wekelijks, op een rustig moment. pg_cron zit niet standaard aan; is het er niet, dan
-- laat deze migratie de functies staan en moet je 'm zelf inplannen (of aanzetten via
-- Dashboard → Database → Extensions).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('purge-stale-anonymous',
                          '17 4 * * 0',
                          $job$select public.purge_stale_anonymous()$job$);
  else
    raise notice 'pg_cron staat uit — purge_stale_anonymous() is aangemaakt maar niet ingepland.';
  end if;
end $$;

