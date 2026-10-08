-- =====================================================================
--  Ordini · Profumo di Pane — aggiornamento 1: sezione "Persone"
--  Il titolare può azzerare una persona (PIN dimenticato o non lavora più):
--  il suo accesso viene cancellato, le sue richieste restano, e può
--  registrarsi di nuovo con lo stesso nome e il codice del negozio.
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
-- =====================================================================

alter table public.profili add column if not exists attivo boolean not null default true;

-- le richieste e il nome restano anche quando l'accesso viene cancellato
alter table public.profili   drop constraint if exists profili_id_fkey;
alter table public.richieste drop constraint if exists richieste_autore_fkey;

-- il nome deve essere unico solo tra chi è ancora attivo
alter table public.profili drop constraint if exists profili_nome_key;
create unique index if not exists profili_nome_attivi on public.profili (nome) where attivo;

create or replace function public.ha_profilo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid() and attivo);
$$;

create or replace function public.e_titolare() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid() and attivo and ruolo = 'titolare');
$$;

create or replace function public.registrati(codice_negozio text, nome_persona text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  r text;
  n text := btrim(coalesce(nome_persona, ''));
begin
  if auth.uid() is null then
    raise exception 'Devi prima entrare';
  end if;
  select ruolo into r from public.profili where id = auth.uid() and attivo;
  if r is not null then
    return r;
  end if;
  if length(n) < 2 then
    raise exception 'Scrivi il tuo nome';
  end if;
  select ruolo into r from public.codici where upper(codice) = upper(btrim(coalesce(codice_negozio, '')));
  if r is null then
    raise exception 'Codice sbagliato';
  end if;
  begin
    insert into public.profili (id, nome, ruolo) values (auth.uid(), n, r);
  exception when unique_violation then
    raise exception 'Questo nome è già usato';
  end;
  return r;
end $$;

-- Solo il titolare: toglie l'accesso a una persona (non a se stesso).
create or replace function public.azzera_persona(persona uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può azzerare una persona';
  end if;
  if persona = auth.uid() then
    raise exception 'Non puoi azzerare te stesso';
  end if;
  update public.profili set attivo = false where id = persona and attivo;
  if not found then
    raise exception 'Persona non trovata';
  end if;
  delete from auth.users where id = persona;
end $$;

revoke all on function public.azzera_persona(uuid) from public, anon;
grant execute on function public.azzera_persona(uuid) to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
