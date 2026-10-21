-- Torna indietro dall'aggiornamento 13: la manutenzione non si spegne più da sola
-- (com'era con l'aggiornamento 12). Non tocca nessun dato.

create or replace function public.in_manutenzione() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select attiva from public.manutenzione where id = 1), false)
$$;
revoke all on function public.in_manutenzione() from public;
grant execute on function public.in_manutenzione() to anon, authenticated, service_role;
