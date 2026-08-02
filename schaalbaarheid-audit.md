# Schaalbaarheid Built

**Korte versie:** de app is *functioneel* prima ontworpen voor schaal — RLS staat goed, alles is
per gebruiker geïndexeerd, er is geen enkele query die over andermans data loopt. Maar het
**sync-protocol** verstuurt bij elke wijziging de volledige database van de gebruiker opnieuw, elke
20 seconden. Dat is ~84.000× meer werk dan nodig, en de kosten groeien lineair met hoe lang iemand
de app al gebruikt.

Concreet: **1.000 gebruikers gaat knellen, 10.000 is het plafond, 1.000.000 is met dit protocol
onmogelijk.** Niet vanwege de hoeveelheid data — die is prima — maar vanwege het schrijfpatroon.

Het goede nieuws: het datamodel hoeft niet op de schop. Met delta-sync is 1.000.000 gebruikers
een gewone, saaie Postgres-werklast.

---

## De kern: full-replace sync

`sync_push` (`supabase/schema.sql:215` e.v.) doet per tabel:

```sql
delete from public.weight_entries where user_id = uid;
insert into public.weight_entries (...) select ... from jsonb_array_elements(...);
```

Twaalf keer, in één transactie. Er bestaat geen "stuur alleen wat er veranderd is" — en dat kán ook
niet, want het schema heeft er niets voor:

- Primary keys zijn `gen_random_uuid()` **server-side** (`schema.sql:28,50,64,72,81,93,113,121,132`).
  De client kent die id's niet en kan dus niet gericht een rij updaten.
- Er is geen `updated_at` en geen `deleted_at`. Een verwijderde set is op de server niet te
  onderscheiden van een set die nooit bestond.

Full-replace is hier dus geen luie keuze, het is de enige mogelijkheid die dit schema toelaat.

### Hoe vaak dit gebeurt

| Stap | Plek |
|---|---|
| Set afvinken → `context.insert(e)` | `Built/TrainingView.swift:1414` |
| SwiftData saved → `ModelContext.didSave` → `markDirty()` | `Built/SyncService.swift:538` |
| Lus wordt elke 20 s wakker en pusht als `dirty` | `Built/SyncService.swift:543` |

Tijdens een training vink je continu sets af, dus `dirty` staat permanent aan. Een training van
60 minuten = **180 volledige database-pushes**.

### Wat dat kost, per push

Gemeten aan de synthetische dataset uit `performance-audit.md` (één jaar serieus trainen:
4.000 sets, 1.500 eiwit-entries, 365 wegingen, 365 dagen habits, 250 producten):

| Tabel | bytes/rij | rijen | totaal |
|---|---:|---:|---:|
| `set_entries` | 183 | 4.000 | 715 KB |
| `protein_entries` | 196 | 1.500 | 287 KB |
| `day_habits` | 424 | 365 | 151 KB |
| `food_products` | 460 | 250 | 112 KB |
| `weight_entries` | 109 | 365 | 39 KB |
| overig | ~200 | ~500 | 98 KB |
| **Totaal** | | **6.980** | **1,37 MB** |

Per push, ongecomprimeerd:

- **1,37 MB upload** — supabase-swift zet geen `Content-Encoding: gzip` op de request body. Deze
  JSON comprimeert ~10×.
- **13.960 tuple-operaties** (6.980 deletes + 6.980 inserts), met WAL, index-onderhoud op twee
  indexen per tabel, en 6.980 dode tuples die autovacuum weer moet opruimen.

### Per training

| | |
|---|---|
| Upload | **246 MB** |
| Tuple-operaties | **2.512.800** |
| Om vast te leggen | ~30 nieuwe sets |
| Write-amplificatie | **~84.000×** |

246 MB per training over 4G. Dat is los van elke schaalvraag al een probleem — dat merkt de eerste
gebruiker met een databundel.

### En het groeit door

Dit is het venijnige deel: de kosten per push zijn evenredig met de **volledige historie** van de
gebruiker. Iemand die drie jaar traint kost per 20 seconden drie keer zoveel als iemand die één
jaar traint. Bij gelijkblijvend gebruikersaantal blijft de serverbelasting dus stijgen, voor altijd.

---

## De rekensom

Aanname: 30% van de gebruikers traint op een gegeven dag, geconcentreerd in een avondpiek van
4 uur, sessies van ~60 minuten. Gebruikers hebben gemiddeld een jaar historie.

### 1.000 gebruikers

| | |
|---|---|
| Sessies/dag | 300 |
| Gelijktijdig in de piek | ~75 |
| Pushes/seconde | 3,75 |
| **Tuple-ops/seconde** | **~52.000** |
| **Ingress** | **5,1 MB/s** (~18 GB/uur in de piek) |

Een Supabase Small (2 vCPU) doet met RLS-evaluatie en index-onderhoud realistisch 10–20k
tuple-ops/s. **52.000/s zit daar overheen.** Je moet dus omhoog in instance-grootte voor werk dat
voor 99,99% overbodig is.

Nuance: je eerste 1.000 gebruikers hebben nog nauwelijks historie en die draaien prima. Het
probleem verschijnt pas als diezelfde 1.000 mensen een jaar later nog steeds trainen.

### 1.000.000 gebruikers

Dezelfde aannames, ×1000:

| | |
|---|---|
| **Tuple-ops/seconde** | **~52.000.000** |
| **Ingress** | **5,1 GB/s** |
| Rijen in de database (1 jaar) | ~7 miljard |
| Diskgebruik | ~1,4 TB + bloat |

Dit is niet "een grotere instance nemen". Dit is drie ordes van grootte mis. Geen enkele
Postgres-opstelling doet dit.

### 1.000.000 gebruikers *met* delta-sync

Alleen de ~50 rijen versturen die daadwerkelijk veranderd zijn:

| | |
|---|---|
| Rijen/sessie | ~50 in plaats van 6.980 × 180 |
| Inserts/dag | ~15 miljoen |
| **Gemiddeld** | **~175/s** |
| **Piek** | **~1.000/s** |
| Upload per training | ~10 KB in plaats van 246 MB |

**Dat is een volstrekt normale werklast voor één Postgres.** De 7 miljard rijen blijven staan en
vragen partitionering, maar dat is een oplosbaar, bekend probleem. Het schrijfpatroon is de
blokkade, niet de omvang.

---

## Verdere bevindingen

### 1. Elke koude start pusht de volledige database — `SyncService.swift:510, 557`

`lastPushedHash` is een gewone static var: leeg bij elke app-start. `dirty` begint op `true`. Dus:

```
start → bootstrap zet pushAllowed = true → binnen 20 s: h != nil → volledige push
```

Ook als de gebruiker helemaal niets gewijzigd heeft. Bij 1.000.000 gebruikers × 3 keer de app
openen per dag = **~4 TB per dag aan volstrekt zinloze upload**.

Let op bij de fix: `hash()` (`SyncService.swift:528`) gebruikt Swift's `Hasher`, en die is per
proces willekeurig geseed. Die waarde bewaren in `UserDefaults` werkt dus níet — je hebt een
stabiele hash nodig (SHA-256 over de JSON).

### 2. Een hik in de auth-server maakt stilletjes een nieuw account — `SyncService.swift:154`

```swift
if let session = try? await client.auth.session { return session.user.id }
return try await client.auth.signInAnonymously().user.id
```

`client.auth.session` gooit zowel bij "geen sessie" als bij "token-refresh mislukt" (500, timeout,
rotatie-race). `try?` maakt daar hetzelfde van. Bij een tijdelijke storing krijgt de gebruiker dus
een **vers anoniem account**, en wordt zijn volledige dataset daaronder weggeschreven. De oude data
blijft als wees achter onder het oude `user_id` — nog steeds opgeslagen, nog steeds betaald.

Op kleine schaal zie je dit nooit. Op grote schaal zijn auth-hikjes dagelijkse kost, en dit levert
zowel dataverlies-meldingen als een opgeblazen gebruikersaantal op.

Fix: onderscheid "geen opgeslagen sessie" van "refresh mislukt", en meld anoniem alleen aan in het
eerste geval.

### 3. RLS roept `auth.uid()` per rij aan — `schema.sql:160`

```sql
create policy "own rows" on public.%I for all using (auth.uid() = user_id) with check (...)
```

Zonder subquery wordt `auth.uid()` per rij geëvalueerd in plaats van één keer als InitPlan. Bij
13.960 rijen per push zijn dat 13.960 functie-aanroepen die er één hadden moeten zijn. Dit is
precies wat Supabase's eigen performance-advisor als `auth_rls_initplan` markeert.

Fix is één regel: `using ((select auth.uid()) = user_id)`, idem voor `with check`.

### 4. 24% van de payload is dood gewicht

Elke rij in de payload draagt een `user_id` mee (`SyncService.swift:63-113`) — 334 KB van de
1,37 MB. `sync_push` gebruikt die velden niet: het pakt `uid` uit `auth.uid()` en negeert wat er in
de JSON staat. Weglaten is gratis winst en verandert niets aan het gedrag.

### 5. `collect()` draait op de MainActor — `SyncService.swift:162`

Twaalf volledige SwiftData-fetches plus een JSON-encode van de complete database, elke 20 seconden
zolang `dirty` aanstaat — dus onafgebroken tijdens een training. `performance-audit.md` punt 9
noemt dit opgelost via de `dirty`-vlag, maar `dirty` wordt gezet door élke save, en tijdens een
training is dat elke set.

De kosten groeien lineair met de historie. Dit is een schaalprobleem *per gebruiker*: het bijt bij
tien gebruikers net zo hard als bij een miljoen, alleen pas na een jaar of twee gebruik.

### 6. OpenFoodFacts wordt rechtstreeks vanaf elke client bevraagd — `FoodView.swift:71-73`

```swift
group.addTask { await sal(query) }
group.addTask { await cgi("https://nl.openfoodfacts.org/cgi/search.pl", query) }
group.addTask { await cgi("https://world.openfoodfacts.org/cgi/search.pl", query) }
```

Drie gelijktijdige requests per zoekopdracht, naar een non-profit die op donaties draait. Er zit een
debounce van 400 ms op (`FoodView.swift:747`) en een schijfcache per apparaat (`FoodView.swift:44`),
dus bij 1.000 gebruikers is dit netjes.

Bij 1.000.000 gebruikers ben je een van hun grootste verkeersbronnen en word je geblokkeerd — en
terecht. Bovendien haalt iedereen dezelfde producten opnieuw op: één gedeelde servercache is
goedkoper, sneller én een betere buur.

### 7. Bloat en autovacuum

100% rij-verloop elke 20 seconden. `set_entries` van een actieve gebruiker wordt per training ~180×
volledig herschreven. Dode tuples ontstaan sneller dan autovacuum ze bij standaardinstellingen
opruimt, en index-bloat komt daar bovenop. Diskgebruik loopt op, de cache hit ratio zakt, alles
wordt trager.

Dit verdwijnt volledig met delta-sync. Tot die tijd: agressievere per-tabel autovacuum-instellingen.

### 8. Geen partitionering

Bij 1.000.000 gebruikers zit `set_entries` alleen al op ~4 miljard rijen in één tabel. Hash-
partitionering op `user_id` houdt indexen en vacuum hanteerbaar. Pas relevant ver voorbij de
huidige situatie, maar het is de reden dat `user_id` in elke tabel als eerste kolom van de index
moet blijven staan.

### 9. Auth-kosten en anonieme gebruikers

`userID()` meldt iedereen bij eerste gebruik anoniem aan. Elke installatie — ook iemand die de app
één keer opent en meteen verwijdert — is daarmee een permanente `auth.users`-rij. Supabase rekent
per MAU en anonieme gebruikers tellen mee. Er is geen opruimtaak.

Bij grote aantallen loont een periodieke job die anonieme accounts zonder profiel na X dagen wist.
(Controleer de actuele Supabase-prijzen; de tariefstructuur wijzigt regelmatig.)

---

## Wat wél goed staat

- **RLS klopt en dekt alle twaalf tabellen** (`schema.sql:153-163`), inclusief `with check`. Geen
  enkele query kan bij andermans data.
- **Elke tabel heeft een index op `user_id`**, en alle queries zijn per gebruiker. Het toegangs-
  patroon is dus perfect gepartitioneerd — dat is precies wat je nodig hebt om ooit te sharden.
- **De push is atomair** via één RPC-transactie. Netwerkuitval laat nooit een half-gewiste server
  achter. Dat is een bewuste, goede keuze.
- **`delete_account()`** is correct `security definer` met `set search_path = ''` en de rechten zijn
  ingetrokken voor `anon` (`schema.sql:297-314`).
- **Voortgangsfoto's staan lokaal** (`PhotosView.swift:26`), niet in Storage. Scheelt de duurste
  kostenpost die dit soort apps kent. (Wel een productafweging: foto's zijn weg bij een nieuw
  toestel.)
- **Geen realtime-abonnementen, geen edge functions.** Niets dat per gebruiker een open verbinding
  vasthoudt — dat is precies de goede keuze voor deze app.
- **De client-side performance is al opgelost** (`performance-audit.md`). De dag-indexen daar zijn
  het verschil tussen een app die vastloopt bij een jaar historie en een die dat niet doet.

---

## Wat ik zou doen, in deze volgorde

### Fase 0 — geen schemawijziging, dagen werk

Samen ongeveer **50–100× minder verkeer en serverbelasting**. Genoeg tot ~10.000 gebruikers.

1. **Niet pushen tijdens een training.** De grootste winst voor de minste moeite. SwiftData is al
   duurzaam; de sync is een back-up, geen live-opslag. Push bij einde training, bij achtergrond
   (`BuiltApp.swift:79` doet dit al) en verder hooguit elke 5 minuten. Alleen dit haalt de 180
   pushes per training terug naar 2 à 3.
2. **`(select auth.uid())` in de RLS-policies** — één regel in een nieuwe migration.
3. **Stabiele hash bewaren** (SHA-256, in `UserDefaults`) zodat een koude start zonder wijzigingen
   niets pusht.
4. **`user_id` uit de payload-rijen halen** — 24% kleiner, nul gedragsverandering.
5. **Gzip op de request body.**
6. **`collect()` en het hashen van de MainActor af.**

### Fase 1 — delta-sync, de echte oplossing

Dit is wat 1.000.000 gebruikers mogelijk maakt. Het is een schemawijziging, dus een migration met
zorg (zie `CLAUDE.md`: nieuwe genummerde migration, `schema.sql` bijwerken, `sync_push` in dezelfde
migration).

1. **Client-gegenereerde UUID's als primary key.** De SwiftData-modellen krijgen een `id: UUID` die
   ook de PK op de server is. Zonder dit kan niets anders van deze fase.
2. **`updated_at timestamptz` en `deleted_at timestamptz`** (tombstones) op elke tabel.
3. **`sync_push` wordt een upsert** van alleen de meegestuurde rijen, plus tombstone-verwerking —
   geen `delete from ... where user_id` meer.
4. **`sync_pull(since timestamptz)`** die alleen rijen met `updated_at > since` teruggeeft.
5. **Per-tabel dirty-tracking in de client** in plaats van één globale vlag.

Migratiepad: beide protocollen kunnen naast elkaar draaien. Nieuwe kolommen krijgen een default,
oude clients blijven full-replace doen (dat blijft correct), nieuwe clients doen delta. Zodra
genoeg gebruikers over zijn, kan het oude pad eruit.

### Fase 2 — pas bij echte schaal

7. Hash-partitionering op `user_id` voor `set_entries`, `protein_entries`, `day_habits`.
8. OpenFoodFacts proxyen via een eigen gecachete productcatalogus (edge function + tabel).
9. Opruimjob voor anonieme accounts zonder profiel.
10. Read replica's zodra er analytics of coach-functionaliteit bijkomt.

---

## Samenvatting

| Schaal | Met huidig protocol | Na fase 0 | Na fase 1 |
|---|---|---|---|
| 1.000 | knelt in de avondpiek, dure instance | ruim voldoende | ruim voldoende |
| 10.000 | nee | plafond, met moeite | ruim voldoende |
| 100.000 | nee | nee | voldoende |
| 1.000.000 | nee, drie ordes van grootte | nee | ja, met partitionering |

De architectuur is goed. Het protocol is het probleem, en dat is te repareren zonder het datamodel
om te gooien.
