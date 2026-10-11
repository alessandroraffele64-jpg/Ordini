-- =====================================================================
--  Ordini · Profumo di Pane — aggiornamento 4: registro di come si usa l'app
--  Serve a Claude per migliorare l'app quando il proprietario lo chiede.
--  Nell'app non si vede. Le persone non hanno il nome: "Persona 1", "Persona 2"…
--  con il ruolo (corso, piazza-nenni, panificio, giro, titolare).
--  Tutti scrivono (solo attraverso la funzione "registra"), nessuno legge dall'app.
--  Le righe più vecchie di 6 mesi si cancellano da sole.
--  Non tocca nessun dato già salvato. Si può rilanciare.
--  ATTENZIONE: l'app scrive qui solo quando REGISTRO_ATTIVO = true in sorgente/app.html
--  (si accende alla partenza vera, dopo il parere del consulente del lavoro).
-- =====================================================================

create table if not exists public.registro (
  id        bigserial primary key,
  creato    timestamptz not null default now(),
  quando    timestamptz,
  persona   text not null,
  ruolo     text not null,
  evento    text not null,
  schermata text,
  dati      jsonb not null default '{}'::jsonb
);
create index if not exists registro_creato_idx on public.registro (creato);

-- chi è "Persona 1", "Persona 2"…: la lega all'account, ma dall'app non si legge
create table if not exists public.registro_persone (
  utente  uuid primary key,
  numero  serial unique
);

alter table public.registro enable row level security;
alter table public.registro_persone enable row level security;
revoke all on public.registro, public.registro_persone from anon, authenticated, public;
revoke all on sequence public.registro_id_seq, public.registro_persone_numero_seq from anon, authenticated, public;

-- l'app manda gli eventi a gruppi (al massimo 200 per volta)
create or replace function public.registra(eventi jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  r text;
  e jsonb;
begin
  if not public.ha_profilo() then return; end if;
  if jsonb_typeof(eventi) <> 'array' then return; end if;
  insert into public.registro_persone (utente) values (auth.uid()) on conflict (utente) do nothing;
  select numero into n from public.registro_persone where utente = auth.uid();
  select case ruolo when 'consegne' then 'giro' else ruolo end into r from public.profili where id = auth.uid();
  for e in select * from jsonb_array_elements(eventi) limit 200 loop
    insert into public.registro (quando, persona, ruolo, evento, schermata, dati)
    values (
      case when (e->>'t') ~ '^[0-9]{10,14}$' then to_timestamp((e->>'t')::bigint / 1000.0) else now() end,
      'Persona ' || n, coalesce(r, '?'),
      left(coalesce(e->>'e', '?'), 40),
      left(e->>'s', 40),
      case when jsonb_typeof(e->'d') = 'object' and length((e->'d')::text) <= 2000 then e->'d' else '{}'::jsonb end
    );
  end loop;
  -- dopo 6 mesi si cancella da solo
  delete from public.registro where creato < now() - interval '6 months';
end $$;

revoke all on function public.registra(jsonb) from public, anon;
grant execute on function public.registra(jsonb) to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
