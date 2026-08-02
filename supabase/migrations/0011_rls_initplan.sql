-- auth.uid() als InitPlan in plaats van per rij.
--
-- `using (auth.uid() = user_id)` laat Postgres de functie voor élke rij evalueren die de
-- policy raakt. sync_push draait als security invoker, dus RLS geldt binnen de functie:
-- bij een push van ~14.000 rijen zijn dat ~14.000 aanroepen die er één hadden moeten zijn.
-- `(select auth.uid())` maakt er een InitPlan van — één keer uitrekenen, daarna alleen nog
-- vergelijken. Dit is wat Supabase's performance-advisor markeert als `auth_rls_initplan`.
--
-- Idempotent: de policy wordt eerst gedropt en daarna opnieuw aangemaakt.

do $$
declare t text;
begin
  foreach t in array array['profiles','weight_entries','protein_entries','set_entries',
                           'day_habits','routines','meals','scales','custom_habits',
                           'habit_logs','food_products','exercises']
  loop
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format(
      'create policy "own rows" on public.%I for all '
      || 'using ((select auth.uid()) = user_id) '
      || 'with check ((select auth.uid()) = user_id)', t);
  end loop;
end $$;
