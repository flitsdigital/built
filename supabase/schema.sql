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

create table if not exists public.day_habits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  creatine boolean not null default false,
  slept_enough boolean not null default false,
  note text not null default '',
  bed_time timestamptz,
  wake_time timestamptz,
  sleep_quality int not null default 0
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
  foreach t in array array['profiles','weight_entries','protein_entries','set_entries','day_habits','routines','meals','scales','custom_habits','habit_logs','food_products']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format('create policy "own rows" on public.%I for all using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
    execute format('create index if not exists %I on public.%I (user_id)', t || '_user_idx', t);
  end loop;
end $$;

-- Atomaire push: vervangt alle data van de ingelogde gebruiker in één transactie,
-- zodat netwerkuitval nooit een half-gewiste server achterlaat.
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
    insert into public.profiles (user_id, name, age, height_cm, start_weight, goal_weight, start_date, goal_date, trainings_per_week, tracks_creatine, tracks_sleep, training_days, kcal_target)
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
      coalesce((payload#>>'{profile,kcal_target}')::int, 0)
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
      kcal_target = excluded.kcal_target;
  end if;

  delete from public.weight_entries where user_id = uid;
  insert into public.weight_entries (user_id, date, kg, scale)
    select uid, (e->>'date')::timestamptz, (e->>'kg')::float8, coalesce(e->>'scale', '')
    from jsonb_array_elements(coalesce(payload->'weights', '[]'::jsonb)) e;

  delete from public.protein_entries where user_id = uid;
  insert into public.protein_entries (user_id, date, grams, label, kcal, carbs, fat, meal)
    select uid, (e->>'date')::timestamptz, (e->>'grams')::int, e->>'label', coalesce((e->>'kcal')::int, 0),
           coalesce((e->>'carbs')::int, 0), coalesce((e->>'fat')::int, 0),
           coalesce(e->>'meal', '')
    from jsonb_array_elements(coalesce(payload->'proteins', '[]'::jsonb)) e;

  delete from public.set_entries where user_id = uid;
  insert into public.set_entries (user_id, date, exercise, weight_kg, reps)
    select uid, (e->>'date')::timestamptz, e->>'exercise', (e->>'weight_kg')::float8, (e->>'reps')::int
    from jsonb_array_elements(coalesce(payload->'sets', '[]'::jsonb)) e;

  delete from public.day_habits where user_id = uid;
  insert into public.day_habits (user_id, date, creatine, slept_enough, note, bed_time, wake_time, sleep_quality)
    select uid, (e->>'date')::timestamptz, (e->>'creatine')::boolean, (e->>'slept_enough')::boolean,
           coalesce(e->>'note', ''), (e->>'bed_time')::timestamptz, (e->>'wake_time')::timestamptz,
           coalesce((e->>'sleep_quality')::int, 0)
    from jsonb_array_elements(coalesce(payload->'habits', '[]'::jsonb)) e;

  delete from public.routines where user_id = uid;
  insert into public.routines (user_id, name, exercises, created_at)
    select uid, e->>'name', coalesce(e->'exercises', '[]'::jsonb), (e->>'created_at')::timestamptz
    from jsonb_array_elements(coalesce(payload->'routines', '[]'::jsonb)) e;

  delete from public.meals where user_id = uid;
  insert into public.meals (user_id, name, protein, kcal, created_at, servings, ingredients, favorite)
    select uid, e->>'name', (e->>'protein')::int, coalesce((e->>'kcal')::int, 0),
           (e->>'created_at')::timestamptz, coalesce((e->>'servings')::float8, 1),
           coalesce(e->'ingredients', '[]'::jsonb), coalesce((e->>'favorite')::boolean, false)
    from jsonb_array_elements(coalesce(payload->'meals', '[]'::jsonb)) e;

  delete from public.food_products where user_id = uid;
  insert into public.food_products (user_id, name, brand, barcode, protein100, kcal100, carbs100, fat100, favorite, image_url, created_at)
    select uid, e->>'name', coalesce(e->>'brand', ''), coalesce(e->>'barcode', ''),
           (e->>'protein100')::float8, (e->>'kcal100')::float8,
           coalesce((e->>'carbs100')::float8, 0), coalesce((e->>'fat100')::float8, 0),
           coalesce((e->>'favorite')::boolean, false), coalesce(e->>'image_url', ''), (e->>'created_at')::timestamptz
    from jsonb_array_elements(coalesce(payload->'foods', '[]'::jsonb)) e;

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
