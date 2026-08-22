-- Een eigen habit kan een supplement zijn: met dosering, en desgewenst een voorraad.
--
-- `dose` is vrije tekst ("5 g", "2 capsules") omdat de eenheid per middel verschilt.
--
-- `stock_left` telt de doses die je nog in huis hebt; elk vinkje haalt er één af. -1 =
-- je houdt geen voorraad bij, 0 = op. Dat onderscheid moet er zijn: zonder de -1 is
-- "niet bijhouden" niet te scheiden van "de kolom bestaat daar nog niet", en dan wist
-- een pull de teller op een toestel dat de migration nog niet gedraaid heeft.
--
-- Herhaalbaar: `add column if not exists` en `create or replace`.

alter table public.custom_habits add column if not exists dose text not null default '';
alter table public.custom_habits add column if not exists stock_left integer not null default -1;
-- Zelfgekozen icoon (SF Symbol) en kleur (een sleutel uit de app, geen hex — zie
-- Color.habitTints). Leeg = de app kiest, en dat is ook de waarde voor elke bestaande rij.
alter table public.custom_habits add column if not exists symbol text not null default '';
alter table public.custom_habits add column if not exists tint text not null default '';

-- sync_push_v2 opnieuw, met de twee kolommen erin. Verder identiek aan 0020.

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

  insert into public.set_entries as t (id, user_id, date, exercise, weight_kg, reps, dropset, failure, seconds, workout_id, updated_at, deleted_at)
  select r.id, uid, r.date, r.exercise, r.weight_kg, r.reps, coalesce(r.dropset, false),
         coalesce(r.failure, false), coalesce(r.seconds, 0), r.workout_id,
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.set_entries, coalesce(payload->'sets', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    date = excluded.date, exercise = excluded.exercise, weight_kg = excluded.weight_kg,
    reps = excluded.reps, dropset = excluded.dropset, failure = excluded.failure,
    seconds = excluded.seconds, workout_id = excluded.workout_id,
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
  where t.updated_at <= excluded.updated_at;

  insert into public.exercises as t (id, user_id, name, muscle, type, created_at, secondary_muscles, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.muscle, 'Overig'), coalesce(r.type, 'Overig'),
         r.created_at, coalesce(r.secondary_muscles, '[]'::jsonb),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.exercises, coalesce(payload->'exercises', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, muscle = excluded.muscle, type = excluded.type,
    created_at = excluded.created_at, secondary_muscles = excluded.secondary_muscles,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.scales as t (id, user_id, name, correction, updated_at, deleted_at)
  select r.id, uid, r.name, coalesce(r.correction, 0), least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.scales, coalesce(payload->'scales', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, correction = excluded.correction,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.custom_habits as t (id, user_id, name, created_at, dose, stock_left, symbol, tint, updated_at, deleted_at)
  select r.id, uid, r.name, r.created_at, coalesce(r.dose, ''), coalesce(r.stock_left, -1),
         coalesce(r.symbol, ''), coalesce(r.tint, ''),
         least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.custom_habits, coalesce(payload->'customHabits', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, created_at = excluded.created_at,
    dose = excluded.dose, stock_left = excluded.stock_left,
    symbol = excluded.symbol, tint = excluded.tint,
    updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
  where t.updated_at <= excluded.updated_at;

  insert into public.habit_logs as t (id, user_id, name, date, updated_at, deleted_at)
  select r.id, uid, r.name, r.date, least(coalesce(r.updated_at, stamp), stamp), r.deleted_at
  from jsonb_populate_recordset(null::public.habit_logs, coalesce(payload->'habitLogs', '[]'::jsonb)) r
  on conflict (id, user_id) do update set
    name = excluded.name, date = excluded.date,
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
