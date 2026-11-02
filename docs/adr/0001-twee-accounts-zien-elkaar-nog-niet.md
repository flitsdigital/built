# 0001 — De weekchallenge wacht op de grens die #60 moet trekken

Status: besloten, 21 augustus 2026. Raakt [#77](https://github.com/flitsdigital/built/issues/77)
(challenge van één week), [#76](https://github.com/flitsdigital/built/issues/76) (coach kijkt mee)
en [#60](https://github.com/flitsdigital/built/issues/60) (vrienden volgen).

## Waar we staan

Elke tabel heeft precies één policy, en die luidt overal hetzelfde:

```sql
create policy "own rows" on public.<tabel> for all
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
```

De enige uitzondering is `off_products`: een publieke productcache die alleen de service role
vult. Er is dus geen enkele weg waarop account A een rij van account B leest — niet via
PostgREST, niet via `sync_push_v2`, niet via de pull.

Een challenge van één week is per definitie het tegenovergestelde: jouw getal naast dat van
een ander. Zonder leespad tussen twee accounts is er niets om naast te zetten.

## Het besluit

**We voegen dat leespad hier niet toe.** Niet als tabel, niet als policy, en niet als
`security definer`-functie die er omheen kijkt. #77 is de UI-helft van een beslissing die in
#60 hoort te vallen, en die beslissing is er nog niet.

Dat is geen uitstel uit voorzichtigheid alleen. De eerste policy die verder reikt dan
`auth.uid() = user_id` legt voor jaren vast wat "gedeeld" in deze app betekent. Die vorm
verzin je niet als bijvangst van een scherm met twee getallen erop.

## Wat #60 eerst moet beslissen

1. **Wat de grens over gaat: een samenvatting of de rijen zelf.** Een afgeleide weekrij
   (aantal trainingen, volume, dagen op rij) laat `set_entries` en de rest ongemoeid achter
   `own rows` staan. Leesrecht op de onderliggende rijen betekent dat een vriend elke set,
   elk gewicht en elke datum ziet — inclusief alles wat daar later bijkomt.
2. **Hoe een vriendschap eruitziet en wie hem mag zien.** Wederzijds geaccepteerd of
   eenzijdig gevolgd, en wat er gebeurt als iemand hem intrekt: verdwijnt het gedeelde getal
   dan meteen, of blijft het tot zondag staan?
3. **Wie de gedeelde rij schrijft.** Schrijft de eigenaar hem zelf, dan moet de policy voor
   het eerst lezen en schrijven uit elkaar trekken: schrijven blijft `auth.uid() = user_id`,
   lezen wordt ruimer. Schrijft de server hem, dan is er een functie die buiten RLS om kijkt,
   en die moet je apart kunnen vertrouwen.
4. **Of die rij door de sync heen loopt.** De sync gaat er overal van uit dat elke rij die hij
   ziet van jou is: de push upsert op `(id, user_id)`, de pull voegt samen op `syncID`. Een
   rij die je wel mag lezen maar nooit mag schrijven breekt die aanname. Die moet dus buiten
   de pull blijven, of de pull moet hem herkennen en met rust laten — anders duwt het toestel
   andermans rij bij de volgende push terug onder jouw `user_id`.
5. **Onder welk id die rij staat.** De primary key staat nog op `id` alleen
   ([#44](https://github.com/flitsdigital/built/issues/44)), met `(id, user_id)` als los
   unique index ernaast. Twee mensen die dezelfde challenge-rij met hetzelfde id opslaan
   botsen dus op de primary key. Een gedeelde challenge heeft één rij per deelnemer nodig,
   of moet wachten tot die key verbreed is.

## Gevolgen

- #77 en #76 staan allebei stil tot #60 valt. Dat is de bedoeling: ze delen één beslissing,
  en die hoort één keer genomen te worden.
- Er is niets opengezet. Wie deze branch merget verandert geen policy, geen tabel en geen
  regel app-code.
- Zodra de grens vaststaat is de challenge zelf klein: één maatstaf, maandag tot en met
  zondag, twee getallen naast elkaar. De week uitrekenen kan de app al — `DayIndex` en
  `WeekQuota` in `Built/Models.swift` leveren trainingen, volume en dagen op rij per week.
  Dat deel is het werk niet.
