-- Aggiornamento 12: manutenzione (punto 45 della lista, 21 ottobre).
-- Durante un aggiornamento Claude accende la manutenzione: chi apre l'app vede
-- «Manutenzione in corso, riprova tra poco» (nemmeno i titolari entrano) e il
-- database non accetta niente di nuovo da nessuno dell'app.
-- Nell'app non c'è un tasto: si accende e si spegne solo da qui.
--
--   Accendere:  update public.manutenzione set attiva = true,  dal = now() where id = 1;
--   Spegnere:   update public.manutenzione set attiva = false, dal = null  where id = 1;
--
-- Non cambia e non cancella nessun dato già salvato. Si può incollare più volte.

create table if not exists public.manutenzione (
  id     int primary key default 1 check (id = 1),
  attiva boolean not null default false,
  dal    timestamptz
);
insert into public.manutenzione (id, attiva) values (1, false) on conflict (id) do nothing;

alter table public.manutenzione enable row level security;
-- tutti (anche chi non è ancora entrato) la leggono; nessuno dell'app la cambia
revoke all on public.manutenzione from anon, authenticated, public;
grant select on public.manutenzione to anon, authenticated;
grant select, insert, update, delete on public.manutenzione to service_role;
drop policy if exists manutenzione_leggi on public.manutenzione;
create policy manutenzione_leggi on public.manutenzione for select to anon, authenticated using (true);

-- l'app se ne accorge subito (tempo reale)
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'manutenzione') then
    alter publication supabase_realtime add table public.manutenzione;
  end if;
end $$;

create or replace function public.in_manutenzione() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select attiva from public.manutenzione where id = 1), false)
$$;
revoke all on function public.in_manutenzione() from public;
grant execute on function public.in_manutenzione() to anon, authenticated, service_role;

-- il blocco: vale per chi arriva dall'app (anon e authenticated), anche dentro le funzioni
-- come usa_codice; non vale per il SQL Editor, le copie di sicurezza e la funzione notifiche.
create or replace function public.blocca_in_manutenzione() returns trigger
language plpgsql security definer set search_path = public as $$
declare chi text;
begin
  chi := coalesce(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role', '');
  if chi in ('anon', 'authenticated') and public.in_manutenzione() then
    raise exception 'Manutenzione in corso, riprova tra poco' using errcode = 'P0001';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.blocca_in_manutenzione() from public;

do $$
declare t text;
begin
  foreach t in array array['richieste','stati','biscotti','impostazioni','profili','iscrizioni',
                           'codici','codici_persona','codici_tentativi','registro','registro_persone'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_manutenzione', t);
      execute format('create trigger %I before insert or update or delete on public.%I for each row execute function public.blocca_in_manutenzione()', t || '_manutenzione', t);
    end if;
  end loop;
end $$;
