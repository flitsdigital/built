-- Voorwaarde voor delta-sync: adresseerbare rijen, en een spoor van wanneer ze
-- gewijzigd of verwijderd zijn.
--
-- Tot nu toe kon de client geen enkele rij aanwijzen: de primary keys werden server-side
-- gegenereerd en de client kende ze niet. Daarom kon `sync_push` alleen alles wissen en
-- opnieuw schrijven. Vanaf nu levert de client het id mee (`gen_random_uuid()` blijft als
-- vangnet staan voor oude clients).
--
-- Drie dingen per gesynchroniseerde tabel:
--
--  1. `updated_at` — wat `sync_pull(since)` nodig heeft om "alles sinds T" te kunnen
--     beantwoorden. Not null met default now(), zodat bestaande rijen meteen een waarde
--     hebben en een eerste incrementele pull ze meeneemt.
--  2. `deleted_at` — een verwijderde rij blijft staan als tombstone. Zonder dat is een
--     gewiste set op de server niet te onderscheiden van een set die nooit bestaan heeft,
--     en zou een delta-push hem gewoon laten staan.
--  3. `unique (id, user_id)` — het conflictdoel voor de upsert in 0014. Op `id` alleen
--     zou een client een id van iemand anders kunnen meesturen; met user_id erbij valt
--     dat buiten het conflict en loopt het stuk op de primary key in plaats van stilletjes
--     de rij van een ander bij te werken. Dit is ook de vorm die #25 nodig heeft: bij
--     hash-partitionering op user_id moet de partitiesleutel in de sleutel zitten.
--
-- Idempotent: alles met `if not exists`.

do $$
declare t text;
begin
  foreach t in array array['weight_entries','protein_entries','set_entries','day_habits',
                           'routines','meals','scales','custom_habits','habit_logs',
                           'food_products','exercises']
  loop
    execute format('alter table public.%I add column if not exists updated_at timestamptz not null default now()', t);
    execute format('alter table public.%I add column if not exists deleted_at timestamptz', t);
    -- (user_id, updated_at) is wat sync_pull(since) scant.
    execute format('create index if not exists %I on public.%I (user_id, updated_at)', t || '_user_updated_idx', t);
    execute format('create unique index if not exists %I on public.%I (id, user_id)', t || '_id_user_key', t);
  end loop;
end $$;

-- Het profiel heeft user_id als primary key en wordt nooit verwijderd; alleen updated_at
-- is hier zinnig, zodat een incrementele pull 'm kan overslaan als er niets veranderd is.
alter table public.profiles add column if not exists updated_at timestamptz not null default now();
