-- =====================================================================
--  Aggiornamento 8 · Persone e permessi più precisi
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati: aggiunge una colonna (sospeso, spenta per tutti)
--  e controlla solo le modifiche nuove. Va lanciato dopo l'aggiornamento 7.
--
--  - Sospendere una persona (per esempio in ferie): non può entrare finché il titolare non la
--    riattiva, e non deve registrarsi di nuovo. Solo il titolare; non sé stesso, non i titolari.
--  - Cambiare il ruolo di una persona (Corso, Piazza Nenni, Panificio, Giro) senza azzerarla.
--    Solo il titolare; non sé stesso, non i titolari, non si fa diventare titolare nessuno.
--  - Il titolare vede chi ha le notifiche accese e quali (notifiche_persone).
--  - Azioni che il titolare dà o toglie a una persona (impostazioni condivise, chiave 'permessi',
--    stessa riga delle sezioni): 'disdire', 'arrivato', 'segnaManca', 'togliNonCe'.
--    Di partenza: disdire = tutti con le Prenotazioni tranne il giro; «È arrivato» e
--    «+ Segna cosa manca» = chi ha «Non in magazzino»; togliere un «non c'è» = solo i titolari.
--    Un'azione vale solo se la persona ha anche la sua sezione.
--  Se si cambia una regola nell'app (sorgente/app.html: azioneDelRuolo, azionePer), cambiarla anche qui.
-- =====================================================================

alter table public.profili add column if not exists sospeso boolean not null default false;

-- chi è sospeso non vede e non scrive niente (come chi non è registrato)
create or replace function public.ha_profilo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid() and attivo and not sospeso);
$$;

create or replace function public.e_titolare() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profili where id = auth.uid() and attivo and not sospeso and ruolo = 'titolare');
$$;

create or replace function public.mio_ruolo() returns text
language sql stable security definer set search_path = public as $$
  select ruolo from public.profili where id = auth.uid() and attivo and not sospeso;
$$;

-- uguale all'aggiornamento 7, ma chi è sospeso non ha nessuna sezione
create or replace function public.ha_sezione(sez text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo and not sospeso;
  if r is null then return false; end if;
  if r = 'titolare' then return true; end if;
  if r = 'consegne' and sez = 'consegne' then return true; end if;
  if not (r = 'consegne' and sez = 'biscotti') then
    select dati->'persone'->(auth.uid()::text)->sez into e from public.impostazioni where chiave = 'permessi';
    if e is not null and jsonb_typeof(e) = 'boolean' then return e = 'true'::jsonb; end if;
  end if;
  if r = 'consegne' then return sez in ('consegne', 'mancanti'); end if;
  return sez in ('prenotazioni', 'biscotti');
end $$;

-- la persona che scrive può fare questa azione? ('disdire', 'arrivato', 'segnaManca', 'togliNonCe')
create or replace function public.ha_azione(az text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo and not sospeso;
  if r is null then return false; end if;
  if r = 'titolare' then return true; end if;
  -- serve anche la sezione
  if az = 'disdire' and not public.ha_sezione('prenotazioni') then return false; end if;
  if az in ('arrivato', 'segnaManca') and not public.ha_sezione('mancanti') then return false; end if;
  if az = 'togliNonCe' and r = 'consegne' then return false; end if;
  select dati->'persone'->(auth.uid()::text)->az into e from public.impostazioni where chiave = 'permessi';
  if e is not null and jsonb_typeof(e) = 'boolean' then return e = 'true'::jsonb; end if;
  if az = 'disdire' then return r <> 'consegne'; end if;
  if az in ('arrivato', 'segnaManca') then return true; end if;
  return false;
end $$;
revoke all on function public.ha_azione(text) from public, anon;
grant execute on function public.ha_azione(text) to authenticated;

-- stati: «È arrivato» (e togliere il «non c'è») con l'azione 'arrivato'; il resto come l'aggiornamento 7
create or replace function public.regole_stati() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
  dopo  jsonb := coalesce(new.dati, '{}'::jsonb);
  pren  boolean;
begin
  if auth.uid() is null then return new; end if;
  if not public.ha_azione('arrivato') then
    if coalesce(prima->>'prep', '') = 'manca' and coalesce(dopo->>'prep', '') <> 'manca' then
      raise exception 'Non hai il permesso di segnare che è arrivato' using errcode = '42501';
    end if;
    if coalesce(dopo->>'arrivatoAlle', '0') not in ('', '0')
       and coalesce(dopo->>'arrivatoAlle', '') is distinct from coalesce(prima->>'arrivatoAlle', '') then
      raise exception 'Non hai il permesso di segnare che è arrivato' using errcode = '42501';
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

-- disdire: con l'azione 'disdire' (di partenza tutti tranne il giro)
create or replace function public.regole_stati_disdetta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
begin
  if auth.uid() is null then return new; end if;
  if coalesce(new.dati->>'disdetta', '') = 'true' and coalesce(prima->>'disdetta', '') <> 'true'
     and not public.ha_azione('disdire') then
    raise exception 'Non hai il permesso di disdire le prenotazioni' using errcode = '42501';
  end if;
  return new;
end $$;

-- richieste: «+ Segna cosa manca» con 'segnaManca', togliere un «non c'è» con 'togliNonCe'
create or replace function public.regole_richieste() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' and coalesce(new.dati->>'tipo', '') = 'magazzino' and not public.ha_azione('segnaManca') then
    raise exception 'Non hai il permesso di segnare cosa manca in magazzino' using errcode = '42501';
  end if;
  if (coalesce(new.dati->>'tipo', '') = 'prenotazione' or (tg_op = 'UPDATE' and coalesce(old.dati->>'tipo', '') = 'prenotazione'))
     and not public.ha_sezione('prenotazioni') then
    raise exception 'Solo chi ha le Prenotazioni può scriverle' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and coalesce(new.dati->>'annullato', '') = 'true' and coalesce(old.dati->>'annullato', '') <> 'true'
     and not public.ha_azione('togliNonCe')
     and exists (select 1 from public.stati s where s.id = old.autore::text || '~' || old.id and s.dati->>'prep' = 'manca') then
    raise exception 'Una cosa segnata «non c''è» la può togliere solo il titolare' using errcode = '42501';
  end if;
  return new;
end $$;

-- Solo il titolare: sospende o riattiva una persona
create or replace function public.sospendi_persona(persona uuid, sospendi boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può sospendere una persona';
  end if;
  if persona = auth.uid() then
    raise exception 'Non puoi sospendere te stesso';
  end if;
  update public.profili set sospeso = coalesce(sospendi, false)
   where id = persona and attivo and ruolo <> 'titolare';
  if not found then
    raise exception 'Persona non trovata (i titolari non si sospendono)';
  end if;
end $$;
revoke all on function public.sospendi_persona(uuid, boolean) from public, anon;
grant execute on function public.sospendi_persona(uuid, boolean) to authenticated;

-- Solo il titolare: cambia il ruolo di una persona (non dei titolari, e nessuno diventa titolare)
create or replace function public.cambia_ruolo(persona uuid, ruolo text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può cambiare il ruolo';
  end if;
  if persona = auth.uid() then
    raise exception 'Non puoi cambiare il tuo ruolo';
  end if;
  if ruolo not in ('corso', 'piazza-nenni', 'panificio', 'consegne') then
    raise exception 'Ruolo non valido';
  end if;
  update public.profili p set ruolo = cambia_ruolo.ruolo
   where p.id = persona and p.attivo and p.ruolo <> 'titolare';
  if not found then
    raise exception 'Persona non trovata (il ruolo dei titolari non si cambia)';
  end if;
end $$;
revoke all on function public.cambia_ruolo(uuid, text) from public, anon;
grant execute on function public.cambia_ruolo(uuid, text) to authenticated;

-- Solo il titolare: chi ha le notifiche accese, su quanti telefoni e quali
create or replace function public.notifiche_persone()
returns table (utente uuid, telefoni integer, preferenze jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può vedere le notifiche delle persone';
  end if;
  return query select i.utente, count(*)::integer, jsonb_agg(i.preferenze)
                 from public.iscrizioni i group by i.utente;
end $$;
revoke all on function public.notifiche_persone() from public, anon;
grant execute on function public.notifiche_persone() to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
