# Status

Waar dit project staat, en wat je moet weten vóór je iets aanraakt. Bewust kort: de
details staan in de git-historie en de issues, en die zijn de waarheid. Dit bestand is
alleen de kaart erboven.

Laatst bijgewerkt: 4 augustus 2026.

## Waar het nu staat

**De sync is uitsluitend samenvoegend.** Sinds [#43](https://github.com/flitsdigital/built/pull/43)
bestaat er geen enkele modus meer waarin één kant "de waarheid" is:

- `sync_push_v2` upsert alleen wat de payload noemt; een rij die er niet in staat blijft
  op de server staan. De conflictregel `t.updated_at <= excluded.updated_at` zorgt dat een
  oudere versie een nieuwere nooit overschrijft.
- Een pull voegt lokaal samen op `syncID`. Ook een volledige pull — die wist het toestel
  vroeger, en dat is precies wat vijf dagen trainingen kostte.
- Een "volledige push" is een volledige *delta*: alle rijen mee, zonder tombstones voor wat
  er niet in zit.

Er zijn geen sync-knoppen meer. De sync heeft geen keuze meer voor te leggen — "wie wint"
bestaat niet — dus valt er niets te kiezen. Wat overblijft is een statusregel onder
Profiel → Account (met een waarschuwingsstipje op de hub-rij zelf), plus een banner op het
dashboard die verschijnt zodra er meer dan een dag werk alleen op dit toestel staat. Die
banner is de enige handmatige trigger die er nog is.

**De oefeningcatalogus wordt op naam samengevoegd.** Twee rijen met dezelfde naam zijn
altijd dezelfde oefening — sets en routines koppelen op naam, dus verder kan de app ze niet
uit elkaar houden. `Exercise.dedupe` voegt ze samen bij elke start en na elke pull die
oefeningen meebrengt, mét tombstone voor de verliezer. Dat is het opruimwerk voor de
catalogus die vóór [#43](https://github.com/flitsdigital/built/pull/43) met `UUID()` werd
gezaaid: het afgeleide id voorkomt nieuwe dubbelen, maar de rijen die er toen al dubbel in
stonden bleven staan.

**Een account is verplicht en heeft altijd een e-mailadres.** Anoniem inloggen bestaat niet
meer; de onboarding laat je er niet langs zonder account. De zeven anonieme accounts uit
juli komen uit oudere builds.

## Regels die je niet moet omzeilen

1. **Voeg nooit een vernietigende sync-modus toe.** Niet "server wint", niet "dit toestel
   wint", niet "wis en haal opnieuw op". Divergentie los je op door samen te voegen. Alles
   wat nodig is om dat te doen zit er al: stabiele `syncID` per rij, `updated_at` per rij,
   en een upsert op `(id, user_id)`.
2. **Uitloggen is de enige plek waar de app nog lokaal wist.** Die knop staat er alleen als
   er een e-mailadres is om mee terug te komen. Laat dat zo.
3. **Rijen die de app zelf zaait krijgen een afgeleid id** (`UUID.stable(from:)`). Elk
   toestel zaait de standaardcatalogus zelf; met een willekeurig id staat elke oefening er
   op een tweede toestel twee keer, want de pull vervangt niet meer maar voegt samen. Dat
   geldt ook voor de namen die `Exercise.bootstrap` uit de historie en de routines inhaalt.
4. **`Exercise.dedupe` kiest de blijver alleen op id.** Het afgeleide id wint, anders het
   laagste. Maak daar nooit "de oudste" of "degene die er al stond" van: kiest toestel A
   een andere blijver dan toestel B, dan wist ieder de rij van de ander en houd je er nul
   over.
5. **Databasewijziging = nieuwe migration.** Zie `CLAUDE.md`.

## Landmijnen

**De primary key staat op `id` alleen.** `(id, user_id)` is er in 0013 als los unique index
bijgekomen, als conflictdoel. Gevolg: dezelfde rij-id onder een ander `user_id` botst op de
primary key, en een toestel kan dus niet van account wisselen zonder dat elke eerder
gepushte rij stukloopt op `sync afgewezen: de payload bevat een id dat niet van deze
gebruiker is`. Omhangen in SQL is nu de enige uitweg. Zie
[#44](https://github.com/flitsdigital/built/issues/44).

**De database kan achterlopen op de migrations.** Op 4 augustus bleken zes kolommen uit
0008 en 0018 nooit op productie te zijn gedraaid. Omdat een push één transactie is met het
profiel erin, liep élke volledige push stuk op `column "tracks_food" does not exist` — terwijl
delta-pushes zonder profielwijziging er wél doorheen kwamen. Het vangnet dat divergentie
moest opruimen was daardoor maanden kapot, zonder dat iemand het zag. Draai bij twijfel:

```sql
select unnest(array['tracks_food','food_counts_for_score']) except
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'profiles';
```

**Een JWT overleeft een database-restore.** PostgREST controleert alleen handtekening en
vervaltijd, niet of de gebruiker nog bestaat. Zet je de database terug, dan blijft de app
tot een uur lang pushen namens een gebruiker die weg is, en krijg je
`violates foreign key constraint "profiles_user_id_fkey"`. Log opnieuw in, wacht niet af.

**`supabase/schema.sql` repareert geen bestaande database.** Het gebruikt
`create table if not exists`, en dat slaat een bestaande tabel over — een ontbrekende kolom
wordt er dus niet mee toegevoegd. Daarvoor zijn de migrations, met `add column if not exists`.

## Wat er openstaat

Zie de issues. [#44](https://github.com/flitsdigital/built/issues/44) is het restwerk aan de
sync; [#11](https://github.com/flitsdigital/built/issues/11) is de schaalbaarheids-epic.
