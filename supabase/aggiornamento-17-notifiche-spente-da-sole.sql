-- Aggiornamento 17 (10 novembre): il titolare vede a chi il telefono ha spento le notifiche da solo.
-- Ogni tanto il telefono (soprattutto l'iPhone) cancella il collegamento per le notifiche senza dirlo:
-- il permesso resta, ma non arriva più niente. L'app, quando si apre, lo dice al database
-- (segna_notifiche_perse); i titolari leggono l'elenco con notifiche_perse_persone().
-- Non cambia nessun dato già salvato. Per tornare indietro: aggiornamento-17-torna-indietro.sql

alter table public.profili add column if not exists notifiche_perse timestamptz;

create or replace function public.segna_notifiche_perse(perse boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.ha_profilo() then
    raise exception 'Devi prima entrare';
  end if;
  update public.profili
     set notifiche_perse = case when perse then coalesce(notifiche_perse, now()) else null end
   where id = auth.uid();
end $$;
revoke all on function public.segna_notifiche_perse(boolean) from public, anon;
grant execute on function public.segna_notifiche_perse(boolean) to authenticated;

create or replace function public.notifiche_perse_persone()
returns table(utente uuid, dal timestamptz) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può vedere le notifiche delle persone';
  end if;
  return query select p.id, p.notifiche_perse from public.profili p where p.notifiche_perse is not null;
end $$;
revoke all on function public.notifiche_perse_persone() from public, anon;
grant execute on function public.notifiche_perse_persone() to authenticated;
