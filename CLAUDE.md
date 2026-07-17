# Built

## Supabase

Bij een databasewijziging: **altijd een nieuwe migration toevoegen**, nooit `supabase/schema.sql` herschrijven.

- Nieuwe migration: `supabase/migrations/NNNN_beschrijving.sql` (oplopend genummerd), met alleen de wijziging (`alter table … add column if not exists …`, nieuwe tabel, etc.) — idempotent.
- Werk de `sync_push`-functie bij in dezelfde migration als kolommen erin verwerkt moeten worden (`create or replace function`).
- `schema.sql` blijft de volledige, herdraaibare weergave van de eindstaat; werk 'm bij zodat een verse setup klopt, maar de migration is wat de gebruiker draait.
