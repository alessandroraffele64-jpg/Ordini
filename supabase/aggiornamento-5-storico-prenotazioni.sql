-- =====================================================================
--  Ordini · Profumo di Pane — aggiornamento 5: storico delle prenotazioni
--  Ogni volta che una prenotazione viene scritta, cambiata, messa da parte,
--  disdetta o cancellata, il database ne salva da solo una copia qui.
--  In questa tabella si può solo aggiungere: dall'app nessuno la legge,
--  la cambia o la cancella. Serve a recuperare una prenotazione persa.
--  Non tocca nessun dato già salvato. Si può rilanciare.
-- =====================================================================

create table if not exists public.storico_prenotazioni (
  id          bigserial primary key,
  quando      timestamptz not null default now(),
  tabella     text not null,          -- 'richieste' (la prenotazione) o 'stati' (messa da parte, disdetta…)
  operazione  text not null,          -- INSERT, UPDATE, DELETE
  rid         text not null,          -- id della prenotazione
  chi         uuid,                   -- chi ha fatto la modifica
  prima       jsonb,                  -- la riga com'era prima
  dopo        jsonb                   -- la riga com'è dopo
);
create index if not exists storico_prenotazioni_rid_idx on public.storico_prenotazioni (rid, quando);

alter table public.storico_prenotazioni enable row level security;
revoke all on public.storico_prenotazioni from anon, authenticated, public;
revoke all on sequence public.storico_prenotazioni_id_seq from anon, authenticated, public;

-- prenotazioni (tabella richieste con dati.tipo = 'prenotazione')
create or replace function public.storico_da_richieste()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(case when tg_op <> 'INSERT' then old.dati->>'tipo' end, case when tg_op <> 'DELETE' then new.dati->>'tipo' end) = 'prenotazione' then
    insert into public.storico_prenotazioni (tabella, operazione, rid, chi, prima, dopo)
    values ('richieste', tg_op,
      case when tg_op = 'DELETE' then old.id else new.id end,
      auth.uid(),
      case when tg_op <> 'INSERT' then to_jsonb(old) end,
      case when tg_op <> 'DELETE' then to_jsonb(new) end);
  end if;
  return null;
end $$;

-- stati delle prenotazioni (messa da parte, disdetta, ripristinata): id = "autore~rid"
create or replace function public.storico_da_stati()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  k text := case when tg_op = 'DELETE' then old.id else new.id end;
  r text := split_part(k, '~', 2);
begin
  if exists (select 1 from public.richieste where id = r and dati->>'tipo' = 'prenotazione') then
    insert into public.storico_prenotazioni (tabella, operazione, rid, chi, prima, dopo)
    values ('stati', tg_op, r, auth.uid(),
      case when tg_op <> 'INSERT' then to_jsonb(old) end,
      case when tg_op <> 'DELETE' then to_jsonb(new) end);
  end if;
  return null;
end $$;

drop trigger if exists storico_prenotazioni_richieste on public.richieste;
create trigger storico_prenotazioni_richieste
  after insert or update or delete on public.richieste
  for each row execute function public.storico_da_richieste();

drop trigger if exists storico_prenotazioni_stati on public.stati;
create trigger storico_prenotazioni_stati
  after insert or update or delete on public.stati
  for each row execute function public.storico_da_stati();

revoke all on function public.storico_da_richieste() from public, anon, authenticated;
revoke all on function public.storico_da_stati() from public, anon, authenticated;

-- le prenotazioni che ci sono già: una prima copia di partenza
insert into public.storico_prenotazioni (tabella, operazione, rid, prima, dopo)
select 'richieste', 'PARTENZA', r.id, null, to_jsonb(r)
from public.richieste r
where r.dati->>'tipo' = 'prenotazione'
  and not exists (select 1 from public.storico_prenotazioni s where s.rid = r.id and s.operazione = 'PARTENZA');

-- Fatto. Deve comparire "Success. No rows returned".
