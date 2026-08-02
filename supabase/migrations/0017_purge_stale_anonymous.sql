-- Anonieme accounts opruimen die nergens toe geleid hebben.
--
-- Iedereen wordt bij eerste gebruik anoniem aangemeld. Dat is een goede keuze — de app
-- werkt meteen, zonder registratiedrempel, en `register()` converteert het anonieme account
-- netjes naar een echt account met behoud van data. Maar elke installatie is daarmee een
-- permanente rij in auth.users, ook iemand die de app één keer opent, rondkijkt en meteen
-- verwijdert. Supabase rekent per MAU en anonieme gebruikers tellen mee.
--
-- Voorwaarde: #18 is gefixt (0-commit "Sync-lus van 20 seconden naar 5 minuten"). Zonder
-- die fix leverde elke auth-hik extra wees-accounts op, en zou dit die bug verhullen in
-- plaats van opruimen.
--
-- **Draai eerst de dry-run.** Onderaan dit bestand staat hoe.

-- Streng in de voorwaarden: een anoniem account mét een profiel is een échte gebruiker die
-- alleen nog niet geregistreerd heeft. Die mag je nooit wissen. Het profiel is het
-- belangrijkste signaal, maar niet het enige — data zonder profiel kan bestaan als iemand
-- de onboarding half afmaakte, dus die tabellen kijken we óók na.
--
-- 90 dagen in plaats van de 30 uit het voorstel: iemand die de app een seizoen laat liggen
-- en terugkomt, mag z'n data niet kwijt zijn.
--
-- security definer met lege search_path, net als delete_account(): auth.users wissen mag
-- alleen de eigenaar. De on-delete-cascade ruimt alle public.* rijen mee op.
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

-- Dry-run, vóór je dit voor het eerst laat draaien:
--
--   select count(*) from public.stale_anonymous_users();
--   select count(*) from auth.users where is_anonymous;
--
-- De verhouding hoort plausibel te zijn: veel meer anonieme accounts dan actieve
-- gebruikers, en de opruiming raakt alleen de accounts zonder enig spoor. Klopt het beeld
-- niet, draai 'm dan niet en zoek eerst uit waar de accounts vandaan komen.
--
-- Controleren dat een anoniem account mét data nooit geraakt wordt:
--
--   select u.id
--   from auth.users u
--   join public.profiles p on p.user_id = u.id
--   where u.is_anonymous
--   intersect
--   select id from public.stale_anonymous_users('0 days'::interval);
--   -- hoort leeg te zijn, ook met een termijn van nul
