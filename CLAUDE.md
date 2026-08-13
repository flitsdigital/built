# Built

Lees `STATUS.md` voordat je aan de sync, het datamodel of de accounts werkt. Daar staat
waarom dingen zijn zoals ze zijn, en welke landmijnen er liggen.

## Sync

De sync voegt uitsluitend samen. **Voeg nooit een modus toe waarin één kant "de waarheid"
is** — geen "server wint", geen "dit toestel wint", geen "wis en haal opnieuw op". Dat heeft
een keer vijf dagen trainingen gekost (#41/#42), en alles wat nodig is om het zonder te doen
zit er al: stabiele `syncID` per rij, `updated_at` per rij, upsert op `(id, user_id)`.

Rijen die de app zelf zaait (de standaardcatalogus met oefeningen) krijgen een van de naam
afgeleid id via `UUID.stable(from:)`, niet `UUID()`. Anders staat dezelfde rij op een tweede
toestel twee keer, want de pull vervangt niet maar voegt samen.

## Supabase

Bij een databasewijziging: **altijd een nieuwe migration toevoegen**, nooit `supabase/schema.sql` herschrijven.

- Nieuwe migration: `supabase/migrations/NNNN_beschrijving.sql` (oplopend genummerd), met alleen de wijziging (`alter table … add column if not exists …`, nieuwe tabel, etc.) — idempotent.
- Werk de `sync_push`-functie bij in dezelfde migration als kolommen erin verwerkt moeten worden (`create or replace function`).
- `schema.sql` blijft de volledige, herdraaibare weergave van de eindstaat; werk 'm bij zodat een verse setup klopt, maar de migration is wat de gebruiker draait.

## Agent skills

### Issue tracker

Issues leven als GitHub issues in `flitsdigital/built`, via de `gh` CLI. Zie `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: één `CONTEXT.md` en `docs/adr/` in de root — beide bestaan nog niet en worden pas aangemaakt als er echt iets vast te leggen valt. Zie `docs/agents/domain.md`.
