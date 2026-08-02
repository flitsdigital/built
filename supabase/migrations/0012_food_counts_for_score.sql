-- Eten los kunnen koppelen van de Groei Score.
--
-- `tracks_food` is de grove knop: die haalt eten helemaal weg, inclusief de eiwitkaart op
-- het dashboard en de eiwitrij in de widget. Wie wél wil blijven loggen maar niet elke
-- overgeslagen dag 30 punten en z'n streak wil verliezen, had geen optie. Vandaar deze
-- tweede vlag: eiwit blijft zichtbaar en bewerkbaar, maar valt uit `DayCheck.factors`.
--
-- Bestaande profielen staan aan, dus voor iedereen verandert er niets tot je 'm uitzet.

alter table public.profiles
  add column if not exists food_counts_for_score boolean not null default true;

-- sync_push moet de kolom kennen, anders valt de instelling bij elke push terug op de
-- default. Zelfde functie als in 0011, met food_counts_for_score erbij.
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
