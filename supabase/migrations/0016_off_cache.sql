-- Gedeelde cache voor OpenFoodFacts.
--
-- De app bevraagt OFF nu rechtstreeks vanaf elk toestel, met drie gelijktijdige requests
-- per zoekopdracht. Dat is als robuustheidsmaatregel goed bedacht — de snelste wint — maar
-- de cache zit *per toestel*. Honderdduizend gebruikers die "melk" zoeken doen dus
-- honderdduizend keer dezelfde drie requests.
--
-- OFF is een non-profit die op donaties draait. Bij die aantallen ben je een van hun
-- grootste verkeersbronnen en word je geblokkeerd, terecht. Met deze tabel ertussen gaat er
-- één request per uniek product naar OFF in plaats van één per gebruiker.
--
-- Dit is géén persoonlijke data: één rij per zoekterm/barcode, gedeeld door iedereen.
-- Vandaar een andere policy dan de rest van het schema — lezen mag iedereen die is
-- aangemeld, schrijven doet alleen de edge function (met de service role, die RLS omzeilt).
--
-- Attributie: de inhoud komt van OpenFoodFacts en valt onder de Open Database License.
-- De app toont de bron in de productdetails; bij hergebruik buiten de app moet die
-- attributie mee.

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
