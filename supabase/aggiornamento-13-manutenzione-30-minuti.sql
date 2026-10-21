-- Aggiornamento 13: la manutenzione si spegne da sola dopo 30 minuti (21 ottobre, deciso dal proprietario).
-- Se Claude si dimentica di spegnerla, dopo 30 minuti da «dal» l'app riapre per tutti e il database
-- riaccetta le scritture. Un aggiornamento dura di solito 10-15 minuti; se serve più tempo, prima che
-- scada si allunga rimettendo l'ora di adesso:
--
--   Accendere / allungare:  update public.manutenzione set attiva = true,  dal = now() where id = 1;
--   Spegnere:               update public.manutenzione set attiva = false, dal = null  where id = 1;
--
-- Accesa senza «dal» non vale (così non resta accesa per sempre per sbaglio).
-- Non cambia e non cancella nessun dato già salvato. Si può incollare più volte.
-- Per tornare indietro: aggiornamento-13-torna-indietro.sql

create or replace function public.in_manutenzione() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select attiva and dal is not null and dal > now() - interval '30 minutes'
                   from public.manutenzione where id = 1), false)
$$;
revoke all on function public.in_manutenzione() from public;
grant execute on function public.in_manutenzione() to anon, authenticated, service_role;
