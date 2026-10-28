-- Aggiornamento 16 (28 ottobre): il titolare vede chi ha bloccato le notifiche dalle impostazioni del telefono.
-- L'app, quando si apre, dice al database se su quel telefono le notifiche sono bloccate (segna_notifiche_bloccate);
-- i titolari leggono l'elenco con notifiche_bloccate_persone(). Non cambia nessun dato già salvato.
-- Per tornare indietro: aggiornamento-16-torna-indietro.sql

alter table public.profili add column if not exists notifiche_bloccate timestamptz;

create or replace function public.segna_notifiche_bloccate(bloccate boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.ha_profilo() then
    raise exception 'Devi prima entrare';
  end if;
  update public.profili
     set notifiche_bloccate = case when bloccate then coalesce(notifiche_bloccate, now()) else null end
   where id = auth.uid();
end $$;
revoke all on function public.segna_notifiche_bloccate(boolean) from public, anon;
grant execute on function public.segna_notifiche_bloccate(boolean) to authenticated;

create or replace function public.notifiche_bloccate_persone()
returns table(utente uuid, dal timestamptz) language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può vedere le notifiche delle persone';
  end if;
  return query select p.id, p.notifiche_bloccate from public.profili p where p.notifiche_bloccate is not null;
end $$;
revoke all on function public.notifiche_bloccate_persone() from public, anon;
grant execute on function public.notifiche_bloccate_persone() to authenticated;
