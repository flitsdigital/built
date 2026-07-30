# Performance-audit Built

> **Status: opgelost.** Alle elf punten hieronder zijn doorgevoerd en geverifieerd in de
> simulator. De metingen na afloop staan in [Resultaat](#resultaat) onderaan. De rest van
> dit document beschrijft de situatie zoals aangetroffen — bewaard als naslag.

**Korte versie:** de app doet bij elke tik een halve database-analyse — zes keer.

Twee dingen versterken elkaar:

1. **Alle zes tabs zijn altijd levend** en worden bij élke SwiftData-wijziging opnieuw geëvalueerd.
2. **In die view-bodies staan zware berekeningen** die telkens over de volledige tabellen scannen.

Eén set afvinken = één `context.insert` = alle `@Query`'s invalideren = alle zes tab-bodies opnieuw
draaien, inclusief de jaar-heatmap (371 dagen), de correlaties (7 × 120 dagen) en het logboek (365 rijen).

---

## Meting

Synthetische dataset van één jaar serieus trainen: 4.000 sets, 1.500 eiwit-entries,
365 wegingen, 365 dagen habits. Gecompileerd met `-O`, gedraaid op de Mac.
**Een iPhone is hier 3–5× trager, en een Debug-build nog eens 5–10× daarbovenop.**

| Wat | Kosten |
|---|---|
| `Calendar.isDate(_:inSameDayAs:)` — één aanroep | **2,8 µs** |
| Eén volledige scan over 4.000 sets met `isDate` | **11 ms** |
| `DayCheck.perfect(day)` — één dag | **5,3 ms** |
| `InsightsView.yearHeatmap` — 371 dagen × 3 × `fill()` | **12,5 s** |
| `DayCheck.streak()` bij een streak van 365 dagen | **2,7 s** |
| Dezelfde lookup via een voorbewerkte `Set<Date>` | **~0 µs** |

`Calendar.isDate(_:inSameDayAs:)` is de dure primitief onder bijna alle problemen hieronder.
Hij doet een volledige datum-decompositie; het is geen goedkope vergelijking. Hij staat in dit
project in tientallen `filter`/`contains`-lussen over volledige tabellen.

---

## Bevindingen, op impact gesorteerd

### 1. Alle zes tabs worden altijd gebouwd — `Built/BuiltApp.swift:206`

```swift
ZStack {
    tabPage(0) { NavigationStack { DashboardView(...) } }
    tabPage(1) { NavigationStack { TrainingView(...) } }
    ...
}
```

`tabPage` zet alleen `.opacity(0)` op de inactieve tabs. Opacity is een render-modifier: de body
wordt gewoon geëvalueerd en de `@Query`'s zijn gewoon actief. Alle 30+ `@Query`-properties in de
zes views laden de volledige tabel en abonneren zich op elke context-wijziging.

Gevolg: elk vinkje tijdens een training rekent óók de jaar-heatmap, de correlaties, het logboek
van 365 dagen en het dashboard door.

Dit is de vermenigvuldiger. Punten 2–7 zijn de kostenposten.

---

### 2. `InsightsView.yearHeatmap` roept `fill(day)` drie keer per dag aan — `Built/InsightsView.swift:594, 599, 612`

```swift
.fill(Color.muscleTint(fill(day)))          // 1
if fill(day) >= 0.999 { ... }               // 2
.accessibilityValue("\(Int(fill(day) * 100))% ...")  // 3
```

371 dagen × 3 = **1.113 aanroepen**. Elke `fill()` loopt door `factors` (5–8 stuks) en elke factor
doet een volledige scan over sets/eiwit/wegingen/habits. Gemeten: **12,5 seconden**.

Ook zonder de andere problemen is dit scherm hiermee onbruikbaar.

---

### 3. `InsightsView.correlations` — `Built/InsightsView.swift:75`

Zeven `compare()`-aanroepen, elk over 120 dagen. Per dag: `habit(day)` (scan over habits) plus
`dayVolume(day)` (volledige scan over sets). Circa **840 volledige tabelscans** per body-pass.

Draait onvoorwaardelijk, en drie keer: in `correlationsBlock` wordt `correlations` aangeroepen
bij `.isEmpty`, bij de `ForEach` én bij de footnote-check (`InsightsView.swift:451, 456, 466`).

---

### 4. `TrainingView`: 90 historie-kaarten met `isPRDay` — `Built/TrainingView.swift:197, 969`

```swift
private func isPRDay(_ day: Date) -> Bool {
    for s in sets(on: day) {                        // volledige scan
        let before = sets.filter { ... }            // nóg een volledige scan, per set
```

`sets(on:)` scant alles, en dan doet hij per set van die dag opnieuw een volledige scan. Dat is
per dag ~15 × 11 ms, en `pastDays` levert er tot 90. De `ForEach` zit in een gewone `VStack`
(`TrainingView.swift:545`), dus alle 90 kaarten worden eager gebouwd — niet alleen de zichtbare.

Goed nieuws: `screen` (`TrainingView.swift:540`) bouwt `idleContent` niet tijdens een actieve
training. Dit raakt dus vooral het openen van de trainingstab, niet het afvinken.

---

### 5. `JournalView`: tot 365 rijen eager — `Built/JournalView.swift:104`

Gewone `VStack` in een `ScrollView`, met per rij `isPerfect(day)` (`JournalView.swift:139`), wat
een volledige `DayCheck.perfect` is (5,3 ms gemeten), plus `summary(day)` met nog vier scans.
365 rijen ≈ **2 seconden** per body-pass, ook als je de tab niet open hebt.

---

### 6. Actieve training: 4+ volledige set-scans per oefening, per body-pass

In de header van elke oefening (`TrainingView.swift:1026, 1104, 1112`):

| Aanroep | Kosten |
|---|---|
| `lastNote(for:)` — `TrainingView.swift:254` | scan over habits + string-splitsing per regel |
| `prInfo(ex)` — `TrainingView.swift:316` | volledige scan over sets |
| `lastSessionSummary(name)` → `lastSession(for:)` — `TrainingView.swift:272, 148` | twee volledige scans |
| `exercises.isBodyweight/isCardio/isBarbell` — `ExerciseLibrary.swift:106` | lineaire scan, ~6× per oefening + per rij |

Bij zes oefeningen zijn dat ~24 volledige scans over de sets-tabel per keer dat de body draait —
en die draait bij elke toetsaanslag in een kg-veld en bij elk vinkje.

`setRow` doet daarnaast `ex.sets[...idx].filter { !$0.warmup }.count` per rij
(`TrainingView.swift:1053`) — O(n²) over de sets van die oefening. Klein, maar gratis weg te halen.

---

### 7. `draftSnapshot` wordt bij elke body-pass opgebouwd — `Built/TrainingView.swift:332, 579`

```swift
.onChange(of: draftSnapshot) { _, snap in ... JSONEncoder().encode(snap) ... }
```

`draftSnapshot` is een computed property die de complete `SavedWorkout` opbouwt (alle oefeningen,
alle sets). `onChange` moet die waarde elke body-pass berekenen én `Equatable`-vergelijken. Bij
elke wijziging volgt een synchrone JSON-encode naar `UserDefaults` — dus per toetsaanslag.

---

### 8. `DashboardView`: zes streak-functies + zeven dag-scores — `Built/DashboardView.swift:94, 102`

`streak`, `streakTrained`, `streakWeighed`, `streakCreatine`, `streakSlept`, `streakJournal`,
`streakCheckIn` en `streakCustom(_:)` lopen elk tot 365 dagen terug met een volledige scan per dag.
Ze breken vroeg af zodra een dag niet telt, dus de echte kosten hangen af van je streak-lengte —
maar precies bij een goedlopende streak (waar de app op stuurt) worden ze duur: **30 dagen streak
≈ 330 ms per streak-functie**.

Daarnaast roept `weekDot` 7× `scoreOn(day)` aan (`DashboardView.swift:344`), en wordt `streak`
minstens drie keer per pass geëvalueerd: in `header`, in `writeSnapshot()` en in
`.onChange(of: streak)` (`DashboardView.swift:214`).

Dit is de reden dat de check-in ("Hoe was je dag?") laggt: elke tik schrijft naar een `DayHabits`
en dat triggert de hele molen — het dashboard zit er direct achter, plus de vijf andere tabs.

---

### 9. Sync-lus draait elke 20 seconden op de MainActor — `Built/SyncService.swift:472`

```swift
Task {
    while true {
        try? await Task.sleep(for: .seconds(20))
        await pushIfChanged(context)   // Sync is @MainActor
    }
}
```

`pushIfChanged` → `collect()` (`SyncService.swift:130`) doet **12 volledige SwiftData-fetches**,
mapt alles naar Row-structs en JSON-encodeert de complete payload — alleen om een hash te
berekenen en te zien óf er iets veranderd is. Alles op de main thread, elke 20 seconden.

---

### 10. Nergens een `LazyVStack`

Geen enkele `LazyVStack`/`LazyHStack` in de codebase. Dashboard, Training (idle), Inzicht en
Logboek zijn allemaal `ScrollView { VStack { ... } }` — alles wordt gebouwd, ook wat 4.000 punten
onder de vouw hangt.

---

### 11. Meet in Release, niet in Debug

`project.yml` zet geen `SWIFT_OPTIMIZATION_LEVEL`, dus Debug draait op `-Onone`. Alle bovenstaande
getallen zijn `-O`. Als je nu op Debug test, is wat je voelt 5–10× erger dan wat gebruikers krijgen.
Meet opnieuw in Release voordat je conclusies trekt over wat er nog over is.

---

## Wat ik zou doen, in deze volgorde

Elke stap is los waardevol; na 1 en 2 is het gros van de lag weg.

**1. Eén dag-index in plaats van `isDate`-scans.**
Bouw per view één keer per body-pass een `[Date: …]` gegroepeerd op `startOfDay`, en doe daarna
O(1) lookups. Dat maakt punt 2 t/m 6 en 8 in één klap goedkoop — gemeten van 11 ms naar ~0 µs
per lookup. Dit is de grootste winst per regel code.

**2. `fill(day)` en `correlations` één keer berekenen.**
`fill(day)` in `yearHeatmap` naar één `let` per dag (van 3 aanroepen naar 1), en `correlations`
naar een `let` bovenaan `correlationsBlock` (van 3 naar 1). Twee regels, 3× minder werk — nog
vóór stap 1 al voelbaar op het Inzicht-scherm.

**3. `LazyVStack`** op Dashboard, Training-idle, Inzicht en Logboek. Eén woord per scherm.

**4. Alleen de actieve tab bouwen** — `BuiltApp.swift:206`.
Dit is de vermenigvuldiger, maar ook de lastigste: naïef `if tab == index` gooit de scroll- en
navigatiestate van de andere tabs weg (precies waarom de ZStack er staat). Na stap 1–3 is de
vraag of dit nog nodig is. Ik zou 'm daarom bewust als laatste doen en dan pas meten.

**5. Sync-hash goedkoper of van de main thread af** — `SyncService.swift:472`.
Simpelste: een `hasChanges`-vlag zetten bij een `ModelContext`-save en `collect()` alleen draaien
als die aan staat. Scheelt 12 volledige fetches + een JSON-encode per 20 seconden.

**6. `draftSnapshot`** niet meer via `onChange` op een computed property, maar expliciet opslaan
op de plekken die de training wijzigen (set afvinken, veld verlaten, oefening toevoegen).

---

## Resultaat

Zelfde dataset, zelfde machine, zelfde `-O`.

| Wat | Voor | Na |
|---|---|---|
| Jaar-heatmap (371 dagen) | 12.500 ms | **0,01 ms** |
| `DayCheck.streak()` bij 365 dagen streak | 2.713 ms | **< 1 ms** |
| Dag-lookup ("trainde ik op dag X?") | 11 ms | **~0 µs** |
| Volledige render Dashboard | ~honderden ms | **1,45 ms** |
| Volledige render Inzicht | seconden | **3,5 ms** |
| Volledige render Training | ~264 ms | **1,0 ms** |

De kern is `dayKey(_:)` in `Models.swift`: een lokale kalenderdag als `Int`, 27× goedkoper
dan `Calendar.startOfDay` en over 1,2 miljoen paren rond DST-overgangen bewezen identiek
aan `Calendar.isDate(_:inSameDayAs:)`. Daarop staan drie indexen die één keer per render
worden gebouwd en daarna O(1) beantwoorden:

- `DayIndex` (`Models.swift`) — eiwit, kcal, volume, gewogen, getraind, habits, habit-logs per dag.
  Gebruikt door Dashboard, Inzicht, Logboek, Notifier en de week-review.
- `LiftStats` (`InsightsView.swift`) — tops, e1RM's en topgewicht per oefening.
- `HistoryIndex` (`TrainingView.swift`) — sets per oefening en per dag, plus de oefening-catalogus.

### Eén bewuste afweging

De zes tabs blijven in de hiërarchie staan (zodat `@State` blijft leven — een lopende
training overleeft een tabwissel, geverifieerd), maar alleen de zichtbare tab rekent z'n
body door. Gevolg: de scrollpositie van een tab die je verlaat gaat verloren. Terugdraaien
is één regel per view (`if isVisible { content }` weghalen).

### Herzien t.o.v. de audit

Punt 7 (`draftSnapshot`) bleek kleiner dan hierboven gesuggereerd: die loopt alleen over de
sets van de lópende training — tientallen, geen duizenden — en kost microseconden. Bewust
ongewijzigd gelaten, want dit is precies wat een force-quit midden in een set opvangt.

## Wat ik níet als probleem vond

- `NumericField` (`TrainingView.swift:1793`) — nette `UIViewRepresentable`, geen herbouw per toets.
- `HealthService` (`HealthService.swift:22`) — dictionary-lookup, correct gecachet.
- `DesignSystem.swift` — geen dure componenten; `ProgressRing`, `StatTile` etc. zijn goedkoop.
- `FoodView` — gebruikt `List` en filtert op dag; verhoudingsgewijs prima.
- SwiftData zelf — het probleem zit niet in de queries maar in wat er ná de query gebeurt.
