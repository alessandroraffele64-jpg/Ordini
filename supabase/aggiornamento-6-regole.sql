-- =====================================================================
--  Aggiornamento 6 · le regole decise valgono anche nel database
--  (non solo perché nell'app il tasto è nascosto).
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati: controlla solo le modifiche nuove.
--
--  - «Non c'è in magazzino» si toglie solo con «È arrivato»: titolari e chi fa il giro.
--  - «È arrivato» (arrivatoAlle) lo segnano solo titolari e chi fa il giro.
--  - «Disdici» una prenotazione: tutti tranne chi fa il giro («Ripristina» resta per tutti).
--  - «+ Segna cosa manca» (richieste di tipo magazzino): solo titolari e chi fa il giro.
--  - Una richiesta segnata «non c'è» la toglie solo il titolare.
--  Le modifiche fatte direttamente da Supabase (SQL Editor, copie, notifiche) non sono controllate.
-- =====================================================================

create or replace function public.mio_ruolo() returns text
language sql stable security definer set search_path = public as $$
  select ruolo from public.profili where id = auth.uid();
$$;
revoke all on function public.mio_ruolo() from public, anon;
grant execute on function public.mio_ruolo() to authenticated;

create or replace function public.regole_stati() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r text;
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
  dopo  jsonb := coalesce(new.dati, '{}'::jsonb);
begin
  if auth.uid() is null then return new; end if;
  r := public.mio_ruolo();
  if r in ('titolare', 'consegne') then return new; end if;
  if coalesce(prima->>'prep', '') = 'manca' and coalesce(dopo->>'prep', '') <> 'manca' then
    raise exception 'Solo i titolari e chi fa il giro possono segnare che è arrivato' using errcode = '42501';
  end if;
  if coalesce(dopo->>'arrivatoAlle', '0') not in ('', '0')
     and coalesce(dopo->>'arrivatoAlle', '') is distinct from coalesce(prima->>'arrivatoAlle', '') then
    raise exception 'Solo i titolari e chi fa il giro possono segnare che è arrivato' using errcode = '42501';
  end if;
  return new;
end $$;

-- chi fa il giro non può disdire (gli altri sì)
create or replace function public.regole_stati_disdetta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
begin
  if auth.uid() is null then return new; end if;
  if coalesce(new.dati->>'disdetta', '') = 'true' and coalesce(prima->>'disdetta', '') <> 'true'
     and public.mio_ruolo() = 'consegne' then
    raise exception 'Chi fa il giro non può disdire le prenotazioni' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists stati_regole on public.stati;
create trigger stati_regole before insert or update on public.stati
  for each row execute function public.regole_stati();
drop trigger if exists stati_regole_disdetta on public.stati;
create trigger stati_regole_disdetta before insert or update on public.stati
  for each row execute function public.regole_stati_disdetta();

create or replace function public.regole_richieste() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r text;
begin
  if auth.uid() is null then return new; end if;
  r := public.mio_ruolo();
  if tg_op = 'INSERT' and coalesce(new.dati->>'tipo', '') = 'magazzino' and r not in ('titolare', 'consegne') then
    raise exception 'Solo i titolari e chi fa il giro possono segnare cosa manca in magazzino' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and coalesce(new.dati->>'annullato', '') = 'true' and coalesce(old.dati->>'annullato', '') <> 'true'
     and r is distinct from 'titolare'
     and exists (select 1 from public.stati s where s.id = old.autore::text || '~' || old.id and s.dati->>'prep' = 'manca') then
    raise exception 'Una cosa segnata «non c''è» la può togliere solo il titolare' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists richieste_regole on public.richieste;
create trigger richieste_regole before insert or update on public.richieste
  for each row execute function public.regole_richieste();

-- Fatto. Deve comparire "Success. No rows returned".
