-- =====================================================================
--  Ordini · Profumo di Pane — preparazione del database
--  Incollare tutto in Supabase → SQL Editor → Run.
--  Si può rilanciare senza problemi: non cancella i dati già salvati.
--  Prima di lanciarlo sostituire i __CODICE_…__ con codici inventati:
--  chi ha un codice può registrarsi. Non salvare qui i codici veri.
-- =====================================================================

-- ---------- Tabelle ----------

create table if not exists public.profili (
  id      uuid primary key references auth.users(id) on delete cascade,
  nome    text not null unique,
  ruolo   text not null check (ruolo in ('corso','piazza-nenni','panificio','consegne','titolare')),
  creato  timestamptz not null default now()
);

create table if not exists public.codici (
  ruolo   text primary key check (ruolo in ('corso','piazza-nenni','panificio','consegne','titolare')),
  codice  text not null unique
);

-- Una riga per ogni cosa richiesta. "dati" contiene la richiesta così come la scrive l'app.
create table if not exists public.richieste (
  id          text primary key,
  autore      uuid not null default auth.uid() references public.profili(id) on delete cascade,
  dati        jsonb not null default '{}'::jsonb,
  creato      timestamptz not null default now(),
  aggiornato  timestamptz not null default now()
);

-- Stato di carico / consegna / preparazione: lo può cambiare chiunque lavori.
create table if not exists public.stati (
  id          text primary key,
  dati        jsonb not null default '{}'::jsonb,
  aggiornato  timestamptz not null default now()
);

create table if not exists public.biscotti (
  id          text primary key,
  dati        jsonb not null default '{}'::jsonb,
  aggiornato  timestamptz not null default now()
);

-- Impostazioni comuni: reparti corretti a mano, cose frequenti, biscotti aggiunti.
create table if not exists public.impostazioni (
  chiave      text primary key,
  dati        jsonb not null default '{}'::jsonb,
  aggiornato  timestamptz not null default now()
);

create index if not exists richieste_creato_idx on public.richieste (creato desc);
create index if not exists stati_aggiornato_idx on public.stati (aggiornato desc);

-- ---------- Codici per registrarsi ----------

insert into public.codici (ruolo, codice) values
  ('corso',        '__CODICE_CORSO__'),
  ('piazza-nenni', '__CODICE_NENNI__'),
  ('panificio',    '__CODICE_PANIFICIO__'),
  ('consegne',     '__CODICE_GIRO__'),
  ('titolare',     '__CODICE_TITOLARE__')
on conflict (ruolo) do update set codice = excluded.codice;

-- ---------- Funzioni di controllo ----------

create or replace function public.ha_profilo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid());
$$;

create or replace function public.e_titolare() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid() and ruolo = 'titolare');
$$;

-- Aggiorna da solo l'ora di modifica.
create or replace function public.tocca_aggiornato() returns trigger
language plpgsql as $$
begin
  new.aggiornato := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['richieste','stati','biscotti','impostazioni'] loop
    execute format('drop trigger if exists %I_aggiornato on public.%I', t, t);
    execute format('create trigger %I_aggiornato before update on public.%I
                    for each row execute function public.tocca_aggiornato()', t, t);
  end loop;
end $$;

-- L'autore di una richiesta non si può cambiare.
create or replace function public.blocca_autore() returns trigger
language plpgsql as $$
begin
  new.autore := old.autore;
  new.creato := old.creato;
  return new;
end $$;
drop trigger if exists richieste_blocca_autore on public.richieste;
create trigger richieste_blocca_autore before update on public.richieste
  for each row execute function public.blocca_autore();

-- Registrazione: dopo aver creato l'account, la persona dà il codice del negozio e il suo nome.
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
  select ruolo into r from public.profili where id = auth.uid();
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

-- Solo il titolare vede i codici, per darli ai nuovi dipendenti.
create or replace function public.codici_negozio()
returns table (ruolo text, codice text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può vedere i codici';
  end if;
  return query select c.ruolo, c.codice from public.codici c order by c.ruolo;
end $$;

-- ---------- Regole di accesso (RLS) ----------

alter table public.profili      enable row level security;
alter table public.codici       enable row level security;
alter table public.richieste    enable row level security;
alter table public.stati        enable row level security;
alter table public.biscotti     enable row level security;
alter table public.impostazioni enable row level security;

-- Chi non è entrato non vede niente.
revoke all on public.profili, public.codici, public.richieste, public.stati,
              public.biscotti, public.impostazioni from anon, public;
-- I codici non si leggono mai direttamente (solo con codici_negozio()).
revoke all on public.codici from authenticated;
grant select on public.profili to authenticated;
grant select, insert, update, delete on public.richieste, public.stati,
      public.biscotti, public.impostazioni to authenticated;

revoke all on function public.registrati(text, text) from public, anon;
revoke all on function public.codici_negozio() from public, anon;
grant execute on function public.registrati(text, text) to authenticated;
grant execute on function public.codici_negozio() to authenticated;
grant execute on function public.ha_profilo() to authenticated;
grant execute on function public.e_titolare() to authenticated;

-- profili: tutti i registrati vedono i nomi dei colleghi.
drop policy if exists profili_leggi on public.profili;
create policy profili_leggi on public.profili for select to authenticated
  using (public.ha_profilo() or id = auth.uid());

-- richieste: tutti leggono; ognuno scrive solo le sue; il titolare può cambiare tutto.
drop policy if exists richieste_leggi on public.richieste;
create policy richieste_leggi on public.richieste for select to authenticated
  using (public.ha_profilo());
drop policy if exists richieste_nuove on public.richieste;
create policy richieste_nuove on public.richieste for insert to authenticated
  with check (public.ha_profilo() and autore = auth.uid());
drop policy if exists richieste_cambia on public.richieste;
create policy richieste_cambia on public.richieste for update to authenticated
  using (autore = auth.uid() or public.e_titolare())
  with check (autore = auth.uid() or public.e_titolare());
drop policy if exists richieste_cancella on public.richieste;
create policy richieste_cancella on public.richieste for delete to authenticated
  using (public.e_titolare());

-- stati, biscotti, impostazioni: chiunque sia registrato legge e scrive; cancella solo il titolare.
do $$
declare t text;
begin
  foreach t in array array['stati','biscotti','impostazioni'] loop
    execute format('drop policy if exists %I_leggi on public.%I', t, t);
    execute format('create policy %I_leggi on public.%I for select to authenticated using (public.ha_profilo())', t, t);
    execute format('drop policy if exists %I_nuovi on public.%I', t, t);
    execute format('create policy %I_nuovi on public.%I for insert to authenticated with check (public.ha_profilo())', t, t);
    execute format('drop policy if exists %I_cambia on public.%I', t, t);
    execute format('create policy %I_cambia on public.%I for update to authenticated using (public.ha_profilo()) with check (public.ha_profilo())', t, t);
    execute format('drop policy if exists %I_cancella on public.%I', t, t);
    execute format('create policy %I_cancella on public.%I for delete to authenticated using (public.e_titolare())', t, t);
  end loop;
end $$;

-- ---------- Aggiornamenti in tempo reale ----------

do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['richieste','stati','biscotti','impostazioni','profili'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Fatto. Deve comparire "Success. No rows returned".

-- Dopo questo script lanciare anche, in ordine, gli aggiornamenti: aggiornamento-1-persone.sql
-- e poi: aggiornamento-2-notifiche.sql, aggiornamento-3-permessi-funzione.sql
