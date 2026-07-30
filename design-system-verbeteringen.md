# Design-system-verbeteringen

Geordend op opbrengst ÷ moeite. Referenties komen uit Mobbin — hoe apps met dezelfde
opgave (dagelijkse habits + trainingsdata) het oplossen.

**Status:** A, B1–B2, B4, C en D1/D5 zijn doorgevoerd. Open: B3, D2, D3 — bewust, zie onderaan.

---

## A. Het design system bestaat, maar de app gebruikt het niet

Dit wás de kern: `DesignSystem.swift` definieerde kaart en ring, en beide werden nergens
aangeroepen — elk scherm had z'n eigen kopie. De kolom "Nu" beschrijft de staat vóór deze ronde.

| # | ✓ | Nu | Straks | Waarom |
|---|---|---|---|---|
| **A1** | ✅ | `BuiltCard` / `.builtCard()` in `DesignSystem.swift:22-33` — **0 call sites**. `DashboardView.swift:670` heeft een private `card {}` met exact dezelfde padding 16 / radius 20 / `secondarySystemGroupedBackground`. | Alle kaarten via `.builtCard()`. De private `card {}` weg. | Twee bronnen voor één beslissing. Wie straks de radius van 20 naar 24 wil, verandert er één en mist de andere — dan wijkt het dashboard af van de rest van de app. Nu al gratis op te lossen: de waarden zijn identiek, dus het is een pure vervanging zonder visueel verschil. |
| **A2** | ✅ | `ProgressRing` in `DesignSystem.swift:39` — **0 call sites**. De score-ring, weekdot-ring en eiwitring zijn drie keer handmatig `Circle().trim(...).stroke(...)`. | Alle drie via `ProgressRing`. | De handmatige versies missen de `max(0.0001, …)`-truc uit `ProgressRing`, waardoor een ring op 0% als een puntje flikkert bij de eerste animatie. De component lost dat al op — hij wordt alleen niet gebruikt. |
| **A3** | ✅ | `statTile` staat **drie keer** in de codebase: `TrainingView.swift:1321` en `:1514` (byte-identiek) en `InsightsView.swift:592` (`.title` i.p.v. `.title2.bold().monospacedDigit()`, plus extra padding). | Eén `StatTile` in `DesignSystem.swift`. | De statrij van een training en die van Inzicht renderen nu op **verschillende lettergroottes**, en die van Inzicht mist `monospacedDigit` — dus daar springt het cijfer tijdens het animeren. Dezelfde component hoort er hetzelfde uit te zien. |
| **A4** | ✅ | Geen. | Een `#Preview` per component in `DesignSystem.swift`. | Zonder previews is er geen plek waar je de componenten náást elkaar ziet, en dat is precies hoe A1–A3 konden ontstaan. Eén preview met alle varianten maakt drift zichtbaar vóór het in een scherm belandt. |

---

## B. Tokens die geen tokens zijn

Waarden stonden los in de schermen in plaats van in de schaal. Niet fout, maar het maakt
elke volgende keuze een gok.

| # | ✓ | Nu | Straks | Waarom |
|---|---|---|---|---|
| **B1** | ✅ | **11 verschillende radii**: 3, 4, 6, 8, 10, 12, 14, 16, 18, 20, 26. | Vier: `4` (micro), `8` (tegel/veld), `20` (kaart), `26` (zwevend). Plus `Capsule`. | Elf waarden betekent dat niemand meer weet welke de juiste is, dus wordt het er twaalf. Vergelijk [Fitbit](https://mobbin.com/screens/10d034c3-883a-4e3f-aa84-6821c56ff632): één kaartradius over de hele Today-tab, alleen de weekindicator wijkt af — en dat is een bewust ander element. |
| **B2** | ✅ | Tint-dekking is `0.12`, `0.15`, `0.16` én `0.18` voor dezelfde taak: een gekleurd vlak achter een icoon of badge. | Eén constante, `0.15`. | Vier waarden voor één beslissing, en het verschil tussen 0.15 en 0.16 ziet niemand. Wat je wél ziet is dat de streak-badge (0.15) en de superset-badge (0.18) naast elkaar nét niet matchen. |
| **B3** | — | Animatieduren staan als losse getallen: vijf `.snappy`-varianten, vijf `.smooth`-varianten. | `Animation.builtMicro` (0.2), `.builtStandard` (0.25), `.builtLarge` (0.3). | `.snappy(0.35)` en `.snappy(0.4)` komen elk twee keer voor zonder dat duidelijk is waarom ze afwijken. Benoemde curves dwingen de vraag af: is dit micro, standaard of groot? |
| **B4** | ✅ | Habit-kleuren staan als losse `.teal`/`.purple`/`.indigo` bij de call site in `DashboardView`. | `Color.habitCreatine` etc. in `DesignSystem.swift`. | De habit-kleur wordt op drie plekken gebruikt (dashboard, dagdetail, widget) en moet overal gelijk zijn. Nu staat de bron in een view-bestand, dus de widget kan er stilletjes van afwijken. |

---

## C. Toegankelijkheid — hier gaat het echt stuk

| # | ✓ | Nu | Straks | Waarom |
|---|---|---|---|---|
| **C1** | ✅ | Icoontegels, weekdots en check-in-tegels hebben **vaste frames**: `34×34`, `30×30`, `58×58`, `76×76`. | `@ScaledMetric` op elk van die maten. | Bij Dynamic Type XXL groeit de tekst wel en de tegel niet: het icoon zit klem en de rij loopt scheef. Dit is de enige verbetering in deze lijst die op een écht toestel met grote letters direct kapot gaat. |
| **C2** | ✅ | **18 `accessibilityLabel`s** in ~9.400 regels. De `⋯`-menu's, chevrons en de meeste icoonknoppen hebben er geen. | Label op elke knop zonder zichtbare tekst. | VoiceOver leest nu "knop" bij elk actiemenu. Dat is geen randgeval — het is elk oefeningsmenu tijdens een training. |
| **C3** | ✅ | Kleur draagt betekenis alleen: groen = gedaan, oranje = gemist. | Vorm mee laten spreken (dat gebeurt al met `checkmark.circle.fill` vs `circle.slash`) én dat consequent doortrekken naar de heatmap en weekdots. | De jaar-heatmap is puur groenintensiteit. Bij deuteranopie is "veel gedaan" niet te onderscheiden van "weinig gedaan". [Google Fit](https://mobbin.com/screens/77fed061-2bba-45c1-89a9-acc3564f684c) zet daarom een ✓ ín de bolletjes van behaalde dagen, bovenop de kleur. |
| **C4** | ✅ | Emoji in de check-in staan op `.system(size: 32)` — vaste maat. | `@ScaledMetric` of een text style. | Emoji schalen niet mee met Dynamic Type. Wie grote letters nodig heeft, krijgt juist hier kleine plaatjes. |

---

## D. Patronen die de app mist

| # | ✓ | Nu | Straks | Waarom |
|---|---|---|---|---|
| **D1** | ✅ | **2×** `ContentUnavailableView` (Records, Oefeningen). De andere **~10** lege staten zijn kale grijze `footnote`-tekst zonder actie. | Overal `ContentUnavailableView` met icoon, kop, uitleg én knop. | Vergelijk [Pocket](https://mobbin.com/screens/added40a-9357-41b0-a635-02191121c449), [Speechify](https://mobbin.com/screens/35eca664-ab15-4008-bbf0-0164e3e0d731) en [GetYourGuide](https://mobbin.com/screens/30e46887-4e15-4e26-9b13-4e3b4c14d3bf): elke lege staat is icoon + kop + één regel + knop. In Built leest "Nog geen routines. Begin met een template of maak er zelf een." als een mededeling, terwijl het de belangrijkste conversie van dat scherm is. |
| **D2** | — | De streak is een klein pilletje rechtsboven in de header. | Streak als eigen blok wanneer hij ≥ 3 dagen is. | [Strava](https://mobbin.com/screens/1c996718-ab94-4247-85b3-80885bab44c9) geeft de streak een hele kaart met vlam + weekdots, [pushr](https://mobbin.com/screens/2d9dedab-7961-4927-ada0-5d9338d95bf7) zet 'm naast de weekstrip. Beide behandelen de reeks als de reden om terug te komen. Bij Built is het het kleinste element op het scherm. |
| **D3** | — | Stat-waarden staan op `.title2`/`.title3`. | Grote stats naar `.largeTitle` of `.system(size: 34, weight: .bold, design: .rounded)`. | [pushr](https://mobbin.com/screens/2d9dedab-7961-4927-ada0-5d9338d95bf7) ("3 push-ups today") en [Fitbit](https://mobbin.com/screens/10d034c3-883a-4e3f-aa84-6821c56ff632) ("1 of 6") zetten het getal fors groter dan het label. Built zet ze bijna even groot, waardoor de statrij leest als een lijstje in plaats van als een resultaat. |
| **D4** | — | Geen uppercase micro-labels boven kaarten. | `.caption2` + tracking als context-kopje, zoals de check-in-drawer al doet met `STAP 3 VAN 5`. | [Tonal](https://mobbin.com/screens/4e2df17b-d095-46a1-8c41-c9394ab83f24) zet `CHALLENGE` boven de titel. Het patroon staat al in de app maar wordt maar op één plek gebruikt. |
| **D5** | ✅ | Donkere modus is nooit gecontroleerd. | Screenshot-check van elk hoofdscherm in dark mode. | De semantische kleuren zorgen dat het *waarschijnlijk* klopt, maar `.yellow.opacity(0.12)` achter een PR en `Color.muscleTint` op donkergrijs zijn niet getoetst. [Google Fit](https://mobbin.com/screens/77fed061-2bba-45c1-89a9-acc3564f684c) laat zien hoe hard datavisualisatie in dark mode verandert: daar worden de ringkleuren juist lichter en verzadigder. "Waarschijnlijk goed" is geen test. |

---

## Wat er nog openstaat

| # | Waarom nog niet |
|---|---|
| **B3** — benoemde animatiecurves | Boekhouding, geen probleem. Pas doen als iemand daadwerkelijk een verkeerde curve kiest. |
| **D2** — streak als eigen kaart | Smaak. Maakt de app niet beter, alleen meer zoals Strava. |
| **D3** — grotere stat-cijfers | Idem. `StatTile` heeft nu een `large`-variant, dus als je het wil is het één parameter. |

## Wat de uitvoering opleverde dat niet in de lijst stond

- **`DesignSystem.swift` zit nu in het widget-target.** Dat bleek nodig zodra de widget
  `.builtTint` ging gebruiken, en het is precies waar B4 om vroeg: de widget kan niet meer
  stilletjes van de app afwijken.
- **A2 klopte niet helemaal.** De claim was dat `ProgressRing` een flikker-op-0% oplost. In
  werkelijkheid doet `max(0.0001, …)` het omgekeerde: hij houdt bewust een minimale trim aan
  zodat de vulling ergens vandaan kan animeren, en dat is op 0% zichtbaar als een puntje. Voor de
  score- en eiwitring is dat goed. In de weekdot niet — daar betekent 0 "niets gedaan", en na de
  omzetting kregen lege dagen een groen stipje. Opgelost door bij score 0 alleen de track te
  tekenen; staat als commentaar bij de component zodat de volgende persoon er niet in trapt.
- **D5 is uitgevoerd, niet alleen gepland.** Dashboard en Inzicht zijn in donkere modus
  gecontroleerd: kaarten, ringtrack, getinte icoontegels en de jaar-heatmap kloppen allemaal.
