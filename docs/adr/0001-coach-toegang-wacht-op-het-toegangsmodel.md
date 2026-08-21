# ADR-0001 — Coach-toegang wacht op het toegangsmodel

- **Status**: voorgesteld, en geblokkeerd op [#60](https://github.com/flitsdigital/built/issues/60)
- **Datum**: 21 augustus 2026
- **Betreft**: [#76](https://github.com/flitsdigital/built/issues/76) (coach kijkt mee en reageert),
  [#60](https://github.com/flitsdigital/built/issues/60) (vrienden volgen),
  [#44](https://github.com/flitsdigital/built/issues/44) (primary key op `id` alleen)

## Context

Alles in Built is nu van één account. Dat zit niet op één plek, maar op vier, en pas met
alle vier tegelijk klopt het beeld:

1. **RLS.** Elke tabel krijgt in `supabase/schema.sql` dezelfde policy uit één lus:
   `"own rows" … using ((select auth.uid()) = user_id)`. Er bestaat geen tweede policy,
   en geen tabel die iets anders doet.
2. **De pull filtert zelf ook.** `sync_pull` is `security invoker`, maar zet in élke
   subquery nog een keer `where x.user_id = (select auth.uid())`. Een bredere policy alleen
   levert een coach dus nog steeds niets op: hij zou een tweede leespad nodig hebben.
3. **De push controleert het spiegelbeeld.** `sync_push_v2` upsert op `(id, user_id)` met
   `uid` uit de sessie. Een rij van iemand anders valt buiten dat conflictdoel, botst op de
   primary key (die op `id` alleen staat, #44) en komt terug als
   `sync afgewezen: de payload bevat een id dat niet van deze gebruiker is`.
4. **De lokale opslag kent geen eigenaar.** Geen enkel SwiftData-model heeft een veld dat
   zegt van wie een rij is. Elke `@Query` in de app betekent daarmee "van mij".

Punt 4 is de scherpste. Zou een coach de trainingen van zijn sporter in dezelfde store
pullen, dan staan die rijen in zijn logboek, in zijn records en in zijn volume — en duwt de
eerstvolgende push ze onder zíjn `user_id` terug omhoog. Dat is precies het scenario dat
punt 3 afwijst, en het breekt daarmee de sync van beide accounts, niet alleen het scherm van
één. Meekijken is dus geen scherm dat je erbij bouwt; het is een tweede eigenaar in een
datamodel dat er één kent.

## Beslissing

**We bouwen nu geen coach-toegang.** Geen tabel, geen policy, geen kolom, geen uitnodiging,
en ook geen alvast aangelegde uitnodigingstabel "voor straks". Wat een coach mag zien is
geen implementatiedetail dat je gaandeweg invult: het is het antwoord dat #60 nog moet
geven, en #76 stelt diezelfde vraag zwaarder — een coach ziet meer dan een vriend, dus hier
moet exact vastliggen wat "meer" is.

Een lege uitnodigingstabel zou dat antwoord niet afwachten maar vooruitlopen: hij legt vast
dat toegang per persoon gaat en niet per training, per periode of per gedeelde samenvatting,
terwijl juist dat de open vraag is.

## Wat eerst beantwoord moet worden

1. **Wat ziet een coach precies, rij voor rij?** "Trainingen" is geen grens die de database
   kent. `set_entries` is de training, maar `day_habits` draagt de notities en óók
   `journal`, `mood`, `stress` en `soreness`; `weight_entries`, `protein_entries` en de
   foto's staan er los naast. Per tabel moet er een ja of een nee liggen, en voor
   `day_habits` per veld.
2. **Wordt het een bredere policy of een tweede leespad?** Zolang `sync_pull` `auth.uid()`
   hardcodeert, doet een bredere `using`-clausule niets. Beide kanten moeten samen worden
   bedacht, anders staat er een tabel open die niemand leest — of leest iemand meer dan de
   policy bedoelde.
3. **Waar landt wat de coach schrijft?** Een reactie heeft een eigen rij-id, een
   `updated_at` en een eigenaar nodig. Onder de sporter schrijven kan niet (`with check`);
   onder de coach schrijven betekent dat de sporter het moet kunnen lézen — dus opnieuw
   vraag 2, maar dan andersom.
4. **Wat betekent "intrekken" als de sync uitsluitend samenvoegt?** Een pull wist niets meer.
   Wat al op het toestel van de coach staat, staat er. Intrekken kan dus "vanaf nu niets
   nieuws" betekenen, of het moet ergens anders worden afgedwongen — maar niet met een
   vernietigende sync-modus, want die bestaat hier bewust niet meer (#42/#43).
5. **Waar staat de data van de sporter op het toestel van de coach?** Niet in dezelfde
   store, om de reden hierboven. Een aparte, alleen-lezen kopie is een ontwerp op zich.

## Gevolgen

- Wie met een coach traint blijft voorlopig screenshots sturen. Dat is de prijs, en die is
  lager dan een verkeerd gekozen grens die later niet meer terug te draaien is: data die te
  ruim gedeeld stond, staat al gedeeld.
- Wie dit oppakt, begint bij #60 en niet bij #76. De grens die daar wordt getrokken —
  samenvatting versus rijen — is het fundament waar coach-toegang bovenop komt.
- Valt het antwoord anders uit dan hierboven verondersteld, werk dan deze ADR bij in plaats
  van hem stil te overrulen.
