-- =====================================================================
--  Ordini · Profumo di Pane — aggiornamento 2: notifiche sul telefono
--  Ogni telefono che attiva le notifiche si "iscrive": qui si salva
--  l'indirizzo a cui mandarle e quali vuole ricevere.
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
-- =====================================================================

create table if not exists public.iscrizioni (
  endpoint    text primary key,
  utente      uuid not null default auth.uid(),
  p256dh      text not null,
  auth        text not null,
  preferenze  jsonb not null default '{}'::jsonb,
  creato      timestamptz not null default now(),
  aggiornato  timestamptz not null default now()
);
create index if not exists iscrizioni_utente_idx on public.iscrizioni (utente);

alter table public.iscrizioni enable row level security;
revoke all on public.iscrizioni from anon, public;
grant select on public.iscrizioni to authenticated;

-- ognuno vede solo le iscrizioni dei suoi telefoni
drop policy if exists iscrizioni_leggi on public.iscrizioni;
create policy iscrizioni_leggi on public.iscrizioni for select to authenticated
  using (utente = auth.uid());

-- iscrive questo telefono (se il telefono era di un altro, passa a chi è entrato ora)
create or replace function public.salva_iscrizione(endpoint_tel text, chiave_p256dh text, chiave_auth text, scelte jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.ha_profilo() then
    raise exception 'Devi prima entrare';
  end if;
  if coalesce(endpoint_tel, '') = '' or length(endpoint_tel) > 1000 then
    raise exception 'Iscrizione non valida';
  end if;
  insert into public.iscrizioni (endpoint, utente, p256dh, auth, preferenze, aggiornato)
  values (endpoint_tel, auth.uid(), chiave_p256dh, chiave_auth, coalesce(scelte, '{}'::jsonb), now())
  on conflict (endpoint) do update
    set utente = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth,
        preferenze = excluded.preferenze, aggiornato = now();
end $$;

create or replace function public.togli_iscrizione(endpoint_tel text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.iscrizioni where endpoint = endpoint_tel and utente = auth.uid();
end $$;

revoke all on function public.salva_iscrizione(text, text, text, jsonb) from public, anon;
revoke all on function public.togli_iscrizione(text) from public, anon;
grant execute on function public.salva_iscrizione(text, text, text, jsonb) to authenticated;
grant execute on function public.togli_iscrizione(text) to authenticated;

-- chi viene azzerato non riceve più notifiche
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
  delete from public.iscrizioni where utente = persona;
  delete from auth.users where id = persona;
end $$;

-- Fatto. Deve comparire "Success. No rows returned".
