-- =====================================================================
--  Ordini · Profumo di Pane — aggiornamento 3: permessi per la funzione "notifiche"
--  La funzione lavora con la chiave segreta del progetto (ruolo service_role).
--  Se il progetto è stato creato senza "esporre automaticamente le tabelle",
--  quel ruolo non ha i permessi sulle nostre tabelle: qui si danno.
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
-- =====================================================================
grant usage on schema public to service_role;
grant select, insert, update, delete on public.profili, public.richieste, public.stati,
      public.biscotti, public.impostazioni, public.iscrizioni to service_role;
-- Fatto. Deve comparire "Success. No rows returned".
