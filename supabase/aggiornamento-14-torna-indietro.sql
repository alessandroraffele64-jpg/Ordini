-- Torna a com'era prima dell'aggiornamento 14 (Guasti): le funzioni dell'aggiornamento 8, uguali a quelle
-- che c'erano nel database il 24 ottobre 2026. I guasti già segnalati restano salvati (richieste con tipo 'guasto').

create or replace function public.gruppo_permesso(k text) returns text
language sql immutable as $$
  select case
    when k in ('giroCaricato', 'giroConsegnato', 'giroParte', 'giroNonCe', 'giroSposta', 'giroAggiungi') then 'consegne'
    when k in ('prenTutte', 'prenNuove', 'prenParte', 'disdire', 'prenRipristina', 'prenTelefono') then 'prenotazioni'
    when k in ('biscComanda', 'biscNuovo', 'biscTogli', 'biscFatto') then 'biscotti'
    when k in ('arrivato', 'segnaManca') then 'mancanti'
    else null end;
$$;

create or replace function public.permesso_centra(k text, tp text) returns boolean
language sql immutable as $$
  select case
    when k in ('richMandare', 'richUrgente', 'richTogliMie', 'richTogliAltri', 'togliNonCe', 'richRecupera',
               'prenTutte', 'biscComanda', 'biscNuovo', 'biscTogli') then tp = 'negozio'
    when k in ('panPrep', 'panNonCe', 'panSposta', 'biscFatto') then tp = 'panificio'
    when k = 'biscotti' then tp in ('negozio', 'panificio')
    when k in ('consegne', 'giroCaricato', 'giroConsegnato', 'giroParte', 'giroNonCe', 'giroSposta', 'giroAggiungi',
               'prenotazioni', 'prenNuove', 'prenParte', 'disdire', 'prenRipristina', 'prenTelefono',
               'mancanti', 'arrivato', 'segnaManca', 'vedeChi') then tp in ('negozio', 'panificio', 'consegne')
    else false end;
$$;

create or replace function public.permesso_di_solito(k text, tp text) returns boolean
language sql immutable as $$
  select public.permesso_centra(k, tp) and case
    when k in ('consegne', 'mancanti') then tp = 'consegne'
    when k in ('prenotazioni', 'disdire') then tp <> 'consegne'
    when k in ('richTogliAltri', 'togliNonCe', 'prenTutte') then false
    else true end;
$$;

create or replace function public.regole_stati() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
  dopo  jsonb := coalesce(new.dati, '{}'::jsonb);
  rd    jsonb;
  ps    text := coalesce(prima->>'stato', '');
  ds    text := coalesce(dopo->>'stato', '');
  pp    text := coalesce(prima->>'prep', '');
  dp    text := coalesce(dopo->>'prep', '');
begin
  if auth.uid() is null or public.e_titolare() then return new; end if;
  select q.dati into rd from public.richieste q
   where q.id = split_part(new.id, '~', 2) and q.autore::text = split_part(new.id, '~', 1);
  rd := coalesce(rd, '{}'::jsonb);

  -- prenotazioni
  if rd->>'tipo' = 'prenotazione' then
    if dopo is distinct from prima and not public.ha_permesso('prenotazioni') then
      raise exception 'Non hai il permesso di vedere le prenotazioni' using errcode = '42501';
    end if;
    if ds is distinct from ps and not public.ha_permesso('prenParte') then
      raise exception 'Non hai il permesso di segnare «Messo da parte»' using errcode = '42501';
    end if;
    if coalesce(prima->>'disdetta', '') = 'true' and coalesce(dopo->>'disdetta', '') <> 'true'
       and not public.ha_permesso('prenRipristina') then
      raise exception 'Non hai il permesso di ripristinare una prenotazione disdetta' using errcode = '42501';
    end if;
    return new;
  end if;

  -- «È arrivato»
  if not public.ha_permesso('arrivato') then
    if pp = 'manca' and dp <> 'manca' then
      raise exception 'Non hai il permesso di segnare che è arrivato' using errcode = '42501';
    end if;
    if coalesce(dopo->>'arrivatoAlle', '0') not in ('', '0')
       and coalesce(dopo->>'arrivatoAlle', '') is distinct from coalesce(prima->>'arrivatoAlle', '') then
      raise exception 'Non hai il permesso di segnare che è arrivato' using errcode = '42501';
    end if;
  end if;

  -- «Non c'è in magazzino» e «In preparazione / Pronto / Finito»
  if dp is distinct from pp then
    if dp = 'manca' then
      if not (public.ha_permesso('panNonCe') or public.ha_permesso('giroNonCe')
              -- chiesta una cosa che già mancava: la segna chi l'ha chiesta
              or (coalesce(dopo->>'giaMancava', '') = 'true' and split_part(new.id, '~', 1) = auth.uid()::text)
              -- il resto di «Solo una parte»
              or (coalesce(rd->>'restoDi', '') <> '' and public.ha_permesso('giroParte'))) then
        raise exception 'Non hai il permesso di segnare «Non c''è in magazzino»' using errcode = '42501';
      end if;
    elsif pp <> 'manca' and not public.ha_permesso('panPrep') then
      raise exception 'Non hai il permesso di segnare a che punto è' using errcode = '42501';
    end if;
  end if;

  -- caricato / consegnato (i promemoria: chi ha il giro)
  if ds is distinct from ps then
    if rd->>'per' = 'Promemoria' then
      if not public.ha_permesso('consegne') then
        raise exception 'Solo chi ha il Giro consegne può segnare i promemoria' using errcode = '42501';
      end if;
    elsif ds = 'consegnato' or ps = 'consegnato' then
      if not public.ha_permesso('giroConsegnato') then
        raise exception 'Non hai il permesso di segnare «Consegnato»' using errcode = '42501';
      end if;
    elsif not public.ha_permesso('giroCaricato') then
      raise exception 'Non hai il permesso di segnare «Caricato»' using errcode = '42501';
    end if;
  end if;

  -- «Solo una parte»
  if coalesce(dopo->>'parteManca', '') <> '' and coalesce(dopo->>'parteManca', '') is distinct from coalesce(prima->>'parteManca', '')
     and not public.ha_permesso('giroParte') then
    raise exception 'Non hai il permesso di segnare «Solo una parte»' using errcode = '42501';
  end if;

  -- spostare di reparto
  if coalesce(dopo->>'reparto', '') is distinct from coalesce(prima->>'reparto', '')
     and not (public.ha_permesso('panSposta') or public.ha_permesso('giroSposta')) then
    raise exception 'Non hai il permesso di spostare una cosa di reparto' using errcode = '42501';
  end if;
  return new;
end $$;

create or replace function public.regole_richieste() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  tipo  text := coalesce(new.dati->>'tipo', '');
  giro  boolean := coalesce(new.dati->>'daGiro', '') = 'true' or coalesce(new.dati->>'per', '') = 'Promemoria';
  mia   boolean;
  prima boolean;
  dopo  boolean;
begin
  if auth.uid() is null or public.e_titolare() then return new; end if;
  if tg_op = 'INSERT' then
    if tipo = 'magazzino' then
      if not public.ha_permesso('segnaManca') then
        raise exception 'Non hai il permesso di segnare cosa manca in magazzino' using errcode = '42501';
      end if;
    elsif tipo = 'prenotazione' then
      if not public.ha_permesso('prenNuove') then
        raise exception 'Non hai il permesso di scrivere prenotazioni' using errcode = '42501';
      end if;
    elsif giro then
      if not public.ha_permesso('giroAggiungi') then
        raise exception 'Non hai il permesso di aggiungere cose al giro' using errcode = '42501';
      end if;
    elsif coalesce(new.dati->>'restoDi', '') <> '' then
      if not public.ha_permesso('giroParte') then
        raise exception 'Non hai il permesso di segnare «Solo una parte»' using errcode = '42501';
      end if;
    else
      if not public.ha_permesso('richMandare') then
        raise exception 'Non hai il permesso di mandare richieste' using errcode = '42501';
      end if;
      if coalesce(new.dati->>'urgente', '') = 'true' and not public.ha_permesso('richUrgente') then
        raise exception 'Non hai il permesso di segnare una richiesta «Urgente»' using errcode = '42501';
      end if;
    end if;
    return new;
  end if;

  -- UPDATE
  mia := old.autore = auth.uid();
  -- chi cambia una richiesta di un collega (permesso «Togliere le richieste dei colleghi») può cambiare solo «tolta / rimessa»
  if not mia and (new.id is distinct from old.id or new.autore is distinct from old.autore
      or (coalesce(new.dati, '{}'::jsonb) - 'annullato' - 'annullatoAlle' - 'ripristinatoAlle')
         is distinct from (coalesce(old.dati, '{}'::jsonb) - 'annullato' - 'annullatoAlle' - 'ripristinatoAlle')) then
    raise exception 'Di una richiesta di un collega puoi solo togliere o recuperare' using errcode = '42501';
  end if;
  if tipo = 'prenotazione' or coalesce(old.dati->>'tipo', '') = 'prenotazione' then
    if not public.ha_permesso('prenotazioni') then
      raise exception 'Solo chi ha le Prenotazioni può cambiarle' using errcode = '42501';
    end if;
    return new;
  end if;
  if tipo = 'magazzino' then return new; end if;
  prima := coalesce(old.dati->>'annullato', '') = 'true';
  dopo := coalesce(new.dati->>'annullato', '') = 'true';
  giro := coalesce(old.dati->>'daGiro', '') = 'true' or coalesce(old.dati->>'per', '') = 'Promemoria';
  if dopo and not prima then
    if not public.ha_permesso('togliNonCe')
       and exists (select 1 from public.stati s where s.id = old.autore::text || '~' || old.id and s.dati->>'prep' = 'manca') then
      raise exception 'Una cosa segnata «non c''è» la può togliere solo il titolare' using errcode = '42501';
    end if;
    if not ((mia and (giro or public.ha_permesso('richTogliMie'))) or (not mia and public.ha_permesso('richTogliAltri'))) then
      raise exception 'Non hai il permesso di togliere questa richiesta' using errcode = '42501';
    end if;
  elsif prima and not dopo then
    if not ((mia and (giro or public.ha_permesso('richRecupera')))
            or (not mia and public.ha_permesso('richRecupera') and public.ha_permesso('richTogliAltri'))) then
      raise exception 'Non hai il permesso di recuperare questa richiesta' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
