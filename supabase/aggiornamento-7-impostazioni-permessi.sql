-- =====================================================================
--  Aggiornamento 7 · Impostazioni e permessi per persona
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati: controlla solo le modifiche nuove.
--
--  - Le sezioni che ognuno vede: quelle del suo ruolo, più o meno le eccezioni che il
--    titolare dà a una persona («Persone registrate»). Le eccezioni stanno nelle impostazioni
--    condivise, chiave 'permessi': { persone: { "<id>": { mancanti: true, biscotti: false } } }.
--    Di partenza: negozi e panificio → Prenotazioni, Biscotti; giro → Consegne, Non in magazzino;
--    titolari → tutto.
--  - Non in magazzino («È arrivato», togliere il «non c'è», «+ Segna cosa manca»): chi ha quella sezione.
--  - Prenotazioni (nuove, cambiate, messe da parte, disdette): chi ha quella sezione.
--    Chi fa il giro non può disdire, anche se ha le Prenotazioni (come prima).
--  - Caricato / consegnato: chi ha il Giro consegne.
--  - Biscotti: chi ha quella sezione.
--  - Impostazioni ('numeri') e permessi ('permessi'): li cambia solo il titolare.
--  - Registro: quanti mesi tenerlo si sceglie nelle Impostazioni (di partenza 6).
--  Le modifiche fatte direttamente da Supabase (SQL Editor, copie, notifiche) non sono controllate.
--  Va lanciato dopo l'aggiornamento 6. Se si cambia una regola nell'app (sorgente/app.html,
--  sezioneDelRuolo e sezioniCambiabili), cambiarla anche qui.
-- =====================================================================

-- la persona che scrive ha questa sezione? ('consegne', 'prenotazioni', 'biscotti', 'mancanti')
create or replace function public.ha_sezione(sez text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo;
  if r is null then return false; end if;
  if r = 'titolare' then return true; end if;
  -- il giro è la pagina di chi fa il giro: non si toglie; i biscotti al giro non si danno
  if r = 'consegne' and sez = 'consegne' then return true; end if;
  if not (r = 'consegne' and sez = 'biscotti') then
    select dati->'persone'->(auth.uid()::text)->sez into e from public.impostazioni where chiave = 'permessi';
    if e is not null and jsonb_typeof(e) = 'boolean' then return e = 'true'::jsonb; end if;
  end if;
  if r = 'consegne' then return sez in ('consegne', 'mancanti'); end if;
  return sez in ('prenotazioni', 'biscotti');
end $$;
revoke all on function public.ha_sezione(text) from public, anon;
grant execute on function public.ha_sezione(text) to authenticated;

-- stati: non in magazzino, prenotazioni, caricato/consegnato
create or replace function public.regole_stati() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
  dopo  jsonb := coalesce(new.dati, '{}'::jsonb);
  pren  boolean;
begin
  if auth.uid() is null then return new; end if;
  if not public.ha_sezione('mancanti') then
    if coalesce(prima->>'prep', '') = 'manca' and coalesce(dopo->>'prep', '') <> 'manca' then
      raise exception 'Solo chi ha «Non in magazzino» può segnare che è arrivato' using errcode = '42501';
    end if;
    if coalesce(dopo->>'arrivatoAlle', '0') not in ('', '0')
       and coalesce(dopo->>'arrivatoAlle', '') is distinct from coalesce(prima->>'arrivatoAlle', '') then
      raise exception 'Solo chi ha «Non in magazzino» può segnare che è arrivato' using errcode = '42501';
    end if;
  end if;
  select exists (select 1 from public.richieste q
                 where q.id = split_part(new.id, '~', 2) and q.autore::text = split_part(new.id, '~', 1)
                   and q.dati->>'tipo' = 'prenotazione') into pren;
  if pren then
    if dopo is distinct from prima and not public.ha_sezione('prenotazioni') then
      raise exception 'Solo chi ha le Prenotazioni può cambiarle' using errcode = '42501';
    end if;
  elsif coalesce(dopo->>'stato', '') is distinct from coalesce(prima->>'stato', '')
        and not public.ha_sezione('consegne') then
    raise exception 'Solo chi ha il Giro consegne può segnare caricato o consegnato' using errcode = '42501';
  end if;
  return new;
end $$;

-- richieste: «+ Segna cosa manca» e prenotazioni
create or replace function public.regole_richieste() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r text;
begin
  if auth.uid() is null then return new; end if;
  r := public.mio_ruolo();
  if tg_op = 'INSERT' and coalesce(new.dati->>'tipo', '') = 'magazzino' and not public.ha_sezione('mancanti') then
    raise exception 'Solo chi ha «Non in magazzino» può segnare cosa manca in magazzino' using errcode = '42501';
  end if;
  if (coalesce(new.dati->>'tipo', '') = 'prenotazione' or (tg_op = 'UPDATE' and coalesce(old.dati->>'tipo', '') = 'prenotazione'))
     and not public.ha_sezione('prenotazioni') then
    raise exception 'Solo chi ha le Prenotazioni può scriverle' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and coalesce(new.dati->>'annullato', '') = 'true' and coalesce(old.dati->>'annullato', '') <> 'true'
     and r is distinct from 'titolare'
     and exists (select 1 from public.stati s where s.id = old.autore::text || '~' || old.id and s.dati->>'prep' = 'manca') then
    raise exception 'Una cosa segnata «non c''è» la può togliere solo il titolare' using errcode = '42501';
  end if;
  return new;
end $$;

-- biscotti: chi ha quella sezione
create or replace function public.regole_biscotti() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if not public.ha_sezione('biscotti') then
    raise exception 'Solo chi ha i Biscotti può cambiarli' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists biscotti_regole on public.biscotti;
create trigger biscotti_regole before insert or update or delete on public.biscotti
  for each row execute function public.regole_biscotti();

-- impostazioni: i numeri e i permessi li cambia solo il titolare
create or replace function public.regole_impostazioni() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if (tg_op <> 'DELETE' and new.chiave in ('numeri', 'permessi'))
     or (tg_op <> 'INSERT' and old.chiave in ('numeri', 'permessi')) then
    if not public.e_titolare() then
      raise exception 'Solo il titolare può cambiare le impostazioni e i permessi' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists impostazioni_regole on public.impostazioni;
create trigger impostazioni_regole before insert or update or delete on public.impostazioni
  for each row execute function public.regole_impostazioni();

-- registro: uguale all'aggiornamento 4, ma quanti mesi tenerlo si sceglie nelle Impostazioni
create or replace function public.registra(eventi jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  n integer;
  r text;
  e jsonb;
  mesi integer;
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
  -- dopo i mesi scelti (di partenza 6) si cancella da solo
  select case when (dati->>'registroMesi') ~ '^[0-9]{1,2}$' then least(24, greatest(1, (dati->>'registroMesi')::integer)) end
    into mesi from public.impostazioni where chiave = 'numeri';
  delete from public.registro where creato < now() - make_interval(months => coalesce(mesi, 6));
end $$;
revoke all on function public.registra(jsonb) from public, anon;
grant execute on function public.registra(jsonb) to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
