# ADR-0001 — De grens van gedeelde data

**Status: voorgesteld. Nog niet besloten.** Dit stuk bevat geen beslissing, maar de vraag
plus wat de code er al over zegt. [#60](https://github.com/flitsdigital/built/issues/60)
wacht hierop, [#76](https://github.com/flitsdigital/built/issues/76) (coach) en
[#77](https://github.com/flitsdigital/built/issues/77) (challenge) staan erachter.

## Waar we staan

Alles in de app is van jou alleen. Twaalf tabellen dragen dezelfde policy — één permissive
`for all` met `using ((select auth.uid()) = user_id)` — en `sync_pull` filtert daarbovenop
nog eens zelf op `auth.uid()`. Er bestaat geen pad waarop twee accounts elkaar zien, en ook
geen manier om een ander account áán te wijzen: `profiles` heeft alleen `user_id` als
sleutel, geen handle, geen e-mailadres, en `auth.users` staat niet open.

Dat is een veilige plek. Het is ook precies wat #60 wil verlaten, en de eerste keer dat de
database iets anders doet dan "alleen jouw rijen".

## Wat er beslist moet worden

1. **Waar ligt de grens — samenvatting of rijen?** Ziet een vriend een handvol getallen die
   jij publiceert, of mag hij (een deel van) je `set_entries` lezen?
2. **Wie schrijft die samenvatting?** Het toestel van de eigenaar, of de server?
3. **Hoe nodig je iemand uit** zonder accounts opzoekbaar te maken, en wat gebeurt er met
   wat de ander al gezien heeft zodra je de toegang intrekt?

## Wat de code hierover al zegt

Vier dingen die bij het lezen boven kwamen, en die de keuze sturen.

**De streak is geen trainingscijfer.** `Score.factors` in `Built/Models.swift` telt eiwit,
training, gewicht, creatine, slaap, dagdetails en je eigen habits bij elkaar op;
`Score.streak` is het aantal dagen op rij dat álle factoren binnen waren. Je streak delen is
dus vertellen dat je je gewicht logt, je eiwit haalt en genoeg slaapt — precies wat #60
uitsluit ("geen gewicht, geen voeding, tenzij expliciet gedeeld"). Bovendien is hij
onvergelijkbaar tussen twee mensen: wie eten uitzet in het profiel, mist die factor en haalt
makkelijker een perfecte dag. Een gedeelde maatstaf moet bij iedereen hetzelfde meten —
trainingen deze week en volume in kg doen dat, de streak niet.

**Score en streak bestaan alleen in Swift.** Er staat geen regel scorelogica in SQL. Laat je
de server de samenvatting berekenen, dan komt die logica er in een tweede kopie bij, en die
twee lopen uit elkaar zodra er een factor verandert.

**Data van een ander mag nooit in de gesynchroniseerde modellen landen.** Een volledige push
haalt élke lokale rij op zonder filter (de reeks `FetchDescriptor`s in `SyncService.swift`)
en stuurt ze onder jouw `user_id` mee. Zou de data van een vriend in `SetEntry` terechtkomen,
dan botsen die id's op de primary key en wijst de server de hele push af met `sync afgewezen:
de payload bevat een id dat niet van deze gebruiker is`. Wat van een ander is, hoort dus in
een apart model of een cache buiten de sync — niet in de tabellen die de sync kent.

**Een tweede policy verruimt meer dan het pad dat je in gedachten hebt.** Policies in
Postgres zijn permissive en worden ge-OR'd. Zet je naast `own rows` een `for select`-policy
voor vrienden op `set_entries`, dan geldt die voor élke lezing van die tabel, ook een
rechtstreekse `from set_entries` via PostgREST — niet alleen voor het scherm dat je aan het
bouwen bent. En elke kolom die er later bij komt is vanaf dat moment automatisch mee gedeeld.
Let ook op de landmijn uit `STATUS.md`: de primary key staat op `id` alleen, dus een rij-id
is maar één keer te vergeven over alle accounts heen (#44).

## De twee vormen, met hun prijs

**A — alleen een samenvatting, door de eigenaar geschreven.** Een aparte tabel met per
gebruiker de getallen die hij publiceert (trainingen deze week, volume). Bestaande tabellen
blijven onaangeroerd; de nieuwe RLS-vorm raakt alleen een tabel die per definitie niets
bevat dat niet gedeeld hoort te worden. Prijs: de samenvatting is zo vers als de laatste push
van de ander, en bij ontvrienden moet de rij ook echt weg — anders houdt het toestel van de
ander een kopie waar niemand meer bij hoort te kunnen.

**B — rijen delen.** Minder code, veel groter gevolg: je deelt de tabel, niet de getallen,
inclusief alles wat er later bij komt. #76 wil uiteindelijk wél rijen (een coach reageert per
oefening), dus de vraag is niet óf B ooit nodig is, maar of #60 daar nu al op ontworpen moet
worden.

Wat hierboven staat wijst richting A: dat is de enige vorm die garandeert dat een kolom die
je volgend jaar toevoegt niet stilletjes meegedeeld wordt. Maar dit is een keuze over wie
welke data van iemand anders mag zien, en die hoort een mens te maken — niet de agent die
toevallig het issue oppakte.

## Wat er daarom niet gebouwd is

Geen tabel, geen policy, geen migration, geen scherm. Er is niets aan de database veranderd
en er staat geen rij open die dat eerst niet was.
