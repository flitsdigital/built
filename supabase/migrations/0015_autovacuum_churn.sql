-- Agressiever vacuümen op de tabellen met het meeste rij-verloop.
--
-- `sync_push` (v1) verwijdert en herschrijft álle rijen van de gebruiker bij elke push.
-- Postgres verwijdert niet echt: elke delete laat een dode tuple achter en elke insert
-- schrijft nieuwe index-entries. `set_entries` van een actieve gebruiker werd zo ~180 keer
-- per training volledig herschreven.
--
-- Autovacuum draait standaard pas bij 20% van de tabel. Op een tabel met permanent 100%
-- verloop is dat te laat en te weinig: dode tuples stapelen sneller dan ze opgeruimd
-- worden, de tabel groeit naar een veelvoud van de live data, indexen bloaten mee en de
-- cache hit ratio zakt. Dat is een sluipend proces — je ziet het pas als het al erg is.
--
-- 0014 haalt de oorzaak weg: sync_push_v2 upsert alleen de gewijzigde rijen. Deze
-- instellingen blijven nodig zolang er clients in het veld zijn die nog v1 aanroepen.
-- Zodra die weg zijn mogen ze terug naar de standaard:
--
--   alter table public.set_entries reset (autovacuum_vacuum_scale_factor,
--                                         autovacuum_vacuum_cost_delay,
--                                         autovacuum_analyze_scale_factor);

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

-- Meten (los draaien in de SQL Editor, niet als onderdeel van de migratie).
--
-- Hoeveel dode tuples staan er, en haalt autovacuum het bij?
--
--   select relname,
--          n_live_tup, n_dead_tup,
--          round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
--          last_autovacuum, autovacuum_count
--   from pg_stat_user_tables
--   where schemaname = 'public'
--   order by n_dead_tup desc;
--
-- Hoe verhoudt de omvang op schijf zich tot de live data?
--
--   select relname,
--          pg_size_pretty(pg_total_relation_size(relid))    as totaal,
--          pg_size_pretty(pg_relation_size(relid))          as tabel,
--          pg_size_pretty(pg_indexes_size(relid))           as indexen,
--          n_live_tup
--   from pg_stat_user_tables
--   where schemaname = 'public'
--   order by pg_total_relation_size(relid) desc;
--
-- Draai beide nu, en een week na deze migratie opnieuw. `dead_pct` hoort stabiel te
-- blijven in plaats van op te lopen. Loopt hij alsnog op, dan is de scale factor nog te
-- hoog voor het verloop dat er is.
