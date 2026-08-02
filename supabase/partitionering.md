# Hash-partitionering op `user_id`

Vastgelegd naar aanleiding van [#25](https://github.com/flitsdigital/built/issues/25). **Dit is
nog niet uitgevoerd** en is dat voorlopig ook niet: het is een besluit met een uitgeschreven
migratiepad, zodat het geen verrassing is als het moment komt.

## Wanneer

De drempel is een **rijaantal, geen gebruikersaantal**. Een miljoen gebruikers die net
begonnen zijn is een kleinere tabel dan tienduizend die drie jaar trainen.

| Signaal | Actie |
|---|---|
| `set_entries` < 100 miljoen rijen | niets doen |
| 100–500 miljoen | migratiepad testen op een branch-database, meten |
| > 500 miljoen, of index groter dan het beschikbare geheugen | uitvoeren |

De praktische grens is niet het rijaantal zelf maar of de index nog in `shared_buffers` +
page cache past. Meten:

```sql
select relname,
       pg_size_pretty(pg_indexes_size(relid)) as indexen,
       n_live_tup
from pg_stat_user_tables
where schemaname = 'public'
order by pg_indexes_size(relid) desc;
```

Zodra de gezamenlijke indexen van de grote tabellen niet meer in het geheugen passen, gaat
elke query naar schijf en zie je de latency oplopen zonder dat er iets aan de queries zelf
veranderd is. Dát is het moment.

## Waarom hash op `user_id`

Elke query in de app is `where user_id = …`. Bij hash-partitionering op `user_id` raakt elke
query exact één partitie: de planner snoeit de rest weg (partition pruning). Dat is precies
het toegangspatroon dat je nodig hebt — bij range-partitionering op datum zou een query over
de historie van één gebruiker juist álle partities raken.

Wat het oplevert:

- Indexen per partitie blijven klein genoeg voor het geheugen.
- `vacuum` draait parallel per partitie in plaats van uren over één tabel.
- DDL raakt één partitie tegelijk in plaats van een operatie te worden.
- Oude gebruikers zijn af te splitsen als dat ooit nodig is.

## Aantal partities

**64.** Achteraf bijstellen betekent alles herverdelen, dus liever ruim. Met 64 partities is
`set_entries` bij vier miljard rijen ~62 miljoen rijen per partitie — comfortabel.

## Wat er in de weg zit

**De partitiesleutel moet in de primary key.** Dat wordt `(user_id, id)` in plaats van `(id)`.
Dat sluit aan op wat er al staat: migration `0013` voegde een unieke index op `(id, user_id)`
toe, en `sync_push_v2` gebruikt die als conflictdoel (`on conflict (id, user_id)`). Er hoeft
op dat vlak dus niets aan de applicatie te veranderen.

**RLS erft van de parent.** Policies op de gepartitioneerde tabel gelden voor alle partities;
`0011` hoeft niet opnieuw.

**Foreign keys naar een gepartitioneerde tabel kunnen niet.** Geen probleem hier: alle FK's
wijzen van deze tabellen naar `auth.users`, niet andersom.

## Migratiepad

Niet in één keer omzetten — `alter table … partition by` bestaat niet. Het is: nieuwe tabel,
in batches kopiëren, omwisselen.

```sql
-- 1. Nieuwe gepartitioneerde tabel naast de oude.
create table public.set_entries_new (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  date timestamptz not null,
  exercise text not null,
  weight_kg float8 not null,
  reps int not null,
  dropset boolean not null default false,
  failure boolean not null default false,
  seconds int not null default 0,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  primary key (user_id, id)
) partition by hash (user_id);

-- 2. 64 partities.
do $$
begin
  for i in 0..63 loop
    execute format(
      'create table public.set_entries_p%s partition of public.set_entries_new '
      || 'for values with (modulus 64, remainder %s)', lpad(i::text, 2, '0'), i);
  end loop;
end $$;

-- 3. In batches kopiëren, zodat er geen uren durende transactie ontstaat.
--    Draaien tot er 0 rijen verplaatst worden.
insert into public.set_entries_new
select * from public.set_entries
order by id
limit 100000
offset :offset;

-- 4. Indexen en RLS op de nieuwe tabel.
create index on public.set_entries_new (user_id, updated_at);
create unique index on public.set_entries_new (id, user_id);
alter table public.set_entries_new enable row level security;
create policy "own rows" on public.set_entries_new for all
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- 5. Omwisselen in één transactie, met een korte lock. Doe dit op een rustig moment;
--    de app valt terug op lokale data en probeert de sync later opnieuw.
begin;
  lock table public.set_entries in access exclusive mode;
  insert into public.set_entries_new             -- inhaalslag sinds stap 3
    select * from public.set_entries s
    where not exists (select 1 from public.set_entries_new n where n.id = s.id and n.user_id = s.user_id);
  alter table public.set_entries rename to set_entries_old;
  alter table public.set_entries_new rename to set_entries;
commit;

-- 6. Controleren dat de planner snoeit vóór je de oude tabel weggooit.
explain (analyze, buffers)
select * from public.set_entries where user_id = '…'::uuid;
-- In het plan hoort exact één partitie te staan, niet 64.

-- 7. Pas na een paar dagen: drop table public.set_entries_old;
```

Zelfde recept voor `protein_entries` en `day_habits`. De kleinere tabellen (`routines`,
`meals`, `scales`, `custom_habits`, `exercises`, `weight_entries`, `habit_logs`,
`food_products`) hebben dit niet nodig — die groeien niet mee met het aantal sets.

## Volgorde

Doen ná [#21](https://github.com/flitsdigital/built/issues/21), niet ervoor. Dit is een
probleem van **datavolume**, niet van het schrijfpatroon: met het oude full-replace-protocol
loop je drie ordes van grootte eerder tegen de schrijfcapaciteit aan dan tegen de omvang van
de tabel. Die volgorde staat inmiddels goed — 0014 heeft de upsert.

## Openstaand

- [ ] Migratiepad daadwerkelijk testen op een branch-database met een realistische dataset
- [ ] Meten hoe lang stap 3 duurt per 100.000 rijen, om stap 5 te kunnen plannen
- [ ] Query-plannen bevestigen partition pruning op `where user_id = …`
