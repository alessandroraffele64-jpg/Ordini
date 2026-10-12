-- =====================================================================
--  Aggiornamento 8 · Persone e permessi precisi, uno per uno
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati: aggiunge una colonna (sospeso, spenta per tutti)
--  e controlla solo le modifiche nuove. Va lanciato dopo l'aggiornamento 7.
--
--  - Sospendere una persona (per esempio in ferie): non può entrare finché il titolare non la
--    riattiva, e non deve registrarsi di nuovo. Solo il titolare; non sé stesso, non i titolari.
--  - Cambiare il ruolo di una persona (Corso, Piazza Nenni, Panificio, Giro) senza azzerarla.
--    Solo il titolare; non sé stesso, non i titolari, non si fa diventare titolare nessuno.
--  - Il titolare vede chi ha le notifiche accese e quali (notifiche_persone).
--  - Permessi uno per uno (impostazioni condivise, chiave 'permessi' → persone → "<id>"):
--    ognuno ha quelli «di solito» del suo posto (permesso_di_solito), più o meno quelli che il
--    titolare gli ha cambiato. Chi lavora in più posti ha un permesso se ce l'ha in almeno uno.
--    Il database controlla le cose che si fanno (mandare, segnare, togliere, disdire…);
--    quelle che si vedono soltanto (chi ha chiesto, il telefono del cliente, le prenotazioni
--    di tutti i posti) le nasconde l'app.
--  Se si cambia una regola nell'app (sorgente/app.html: GRUPPI_PERMESSI), cambiarla anche qui.
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

-- tipo di posto: 'negozio' (corso, piazza-nenni), 'panificio', 'consegne' (giro)
create or replace function public.tipo_posto(r text) returns text
language sql immutable as $$
  select case when r in ('corso', 'piazza-nenni', 'nenni') then 'negozio' else r end;
$$;

-- il gruppo di un permesso: per avere il permesso serve anche «Vedere» il gruppo
create or replace function public.gruppo_permesso(k text) returns text
language sql immutable as $$
  select case
    when k in ('giroCaricato', 'giroConsegnato', 'giroParte', 'giroNonCe', 'giroSposta', 'giroAggiungi') then 'consegne'
    when k in ('prenTutte', 'prenNuove', 'prenParte', 'disdire', 'prenRipristina', 'prenTelefono') then 'prenotazioni'
    when k in ('biscComanda', 'biscNuovo', 'biscTogli', 'biscFatto') then 'biscotti'
    when k in ('arrivato', 'segnaManca') then 'mancanti'
    else null end;
$$;

-- il permesso c'entra con quel tipo di posto? (altrove vale No)
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

-- com'è di solito in quel tipo di posto (uguale a GRUPPI_PERMESSI nell'app)
create or replace function public.permesso_di_solito(k text, tp text) returns boolean
language sql immutable as $$
  select public.permesso_centra(k, tp) and case
    when k in ('consegne', 'mancanti') then tp = 'consegne'
    when k in ('prenotazioni', 'disdire') then tp <> 'consegne'
    when k in ('richTogliAltri', 'togliNonCe', 'prenTutte') then false
    else true end;
$$;

-- il permesso di una persona in un posto (e = le sue scelte fatte dal titolare)
create or replace function public.permesso_nel_posto(k text, tp text, e jsonb) returns boolean
language plpgsql immutable as $$
declare
  g text := public.gruppo_permesso(k);
  v jsonb;
begin
  if not public.permesso_centra(k, tp) then return false; end if;
  -- il giro consegne per chi fa il giro c'è sempre
  if k = 'consegne' and tp = 'consegne' then return true; end if;
  if g is not null and not public.permesso_nel_posto(g, tp, e) then return false; end if;
  if k = 'richUrgente' and not public.permesso_nel_posto('richMandare', tp, e) then return false; end if;
  if k = 'biscNuovo' and not public.permesso_nel_posto('biscComanda', tp, e) then return false; end if;
  v := e -> k;
  if v is not null and jsonb_typeof(v) = 'boolean' then return v = 'true'::jsonb; end if;
  return public.permesso_di_solito(k, tp);
end $$;

-- la persona che scrive ha questo permesso? (titolari sempre; chi lavora in più posti: in almeno uno)
create or replace function public.ha_permesso(k text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
  p text;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo and not sospeso;
  if r is null then return false; end if;
  if r = 'titolare' then return true; end if;
  select dati->'persone'->(auth.uid()::text) into e from public.impostazioni where chiave = 'permessi';
  if e is null or jsonb_typeof(e) <> 'object' then e := '{}'::jsonb; end if;
  if public.permesso_nel_posto(k, public.tipo_posto(r), e) then return true; end if;
  if r in ('corso', 'piazza-nenni', 'panificio') and jsonb_typeof(e->'luoghi') = 'array' then
    for p in select jsonb_array_elements_text(e->'luoghi') loop
      if p in ('corso', 'piazza-nenni', 'panificio') and public.permesso_nel_posto(k, public.tipo_posto(p), e) then return true; end if;
    end loop;
  end if;
  return false;
end $$;
revoke all on function public.ha_permesso(text) from public, anon;
grant execute on function public.ha_permesso(text) to authenticated;

-- i nomi dei posti dove lavora chi scrive ('Corso', 'Piazza Nenni', 'Panificio')
create or replace function public.miei_posti() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
  out text[] := '{}';
  p text;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo and not sospeso;
  if r is null or r not in ('corso', 'piazza-nenni', 'panificio') then return out; end if;
  select dati->'persone'->(auth.uid()::text)->'luoghi' into e from public.impostazioni where chiave = 'permessi';
  for p in select r union select x from jsonb_array_elements_text(case when jsonb_typeof(e) = 'array' then e else '[]'::jsonb end) x loop
    out := out || case p when 'corso' then 'Corso' when 'piazza-nenni' then 'Piazza Nenni' when 'panificio' then 'Panificio' end;
  end loop;
  return array_remove(out, null);
end $$;
revoke all on function public.miei_posti() from public, anon;
grant execute on function public.miei_posti() to authenticated;

-- le funzioni di prima (aggiornamenti 7 e 8): adesso chiedono a ha_permesso
create or replace function public.ha_sezione(sez text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.ha_permesso(sez);
$$;
create or replace function public.ha_azione(az text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.ha_permesso(az);
$$;
revoke all on function public.ha_azione(text) from public, anon;
grant execute on function public.ha_azione(text) to authenticated;

-- stati delle richieste e delle prenotazioni
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

-- disdire: con il permesso 'disdire' (di solito tutti tranne il giro)
create or replace function public.regole_stati_disdetta() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
begin
  if auth.uid() is null then return new; end if;
  if coalesce(new.dati->>'disdetta', '') = 'true' and coalesce(prima->>'disdetta', '') <> 'true'
     and not public.ha_permesso('disdire') then
    raise exception 'Non hai il permesso di disdire le prenotazioni' using errcode = '42501';
  end if;
  return new;
end $$;

-- richieste: mandare, «Urgente», togliere e recuperare, aggiungere dal giro, prenotazioni, «+ Segna cosa manca»
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

-- togliere le richieste dei colleghi: solo con il permesso e solo dei posti dove si lavora
-- (la regola qui sopra lascia cambiare solo «tolta / rimessa»)
drop policy if exists richieste_cambia_colleghi on public.richieste;
create policy richieste_cambia_colleghi on public.richieste for update to authenticated
  using (public.ha_permesso('richTogliAltri') and coalesce(dati->>'tipo', '') not in ('prenotazione', 'magazzino')
         and (dati->>'per') = any (public.miei_posti()))
  with check (public.ha_permesso('richTogliAltri') and coalesce(dati->>'tipo', '') not in ('prenotazione', 'magazzino')
         and (dati->>'per') = any (public.miei_posti()));

-- biscotti: comanda, togliere / recuperare, «Fatto» / rimetti da fare
create or replace function public.regole_biscotti() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  prima jsonb;
  dopo  jsonb;
  ps    text;
  ds    text;
begin
  if auth.uid() is null or public.e_titolare() then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if not public.ha_permesso('biscotti') then
    raise exception 'Solo chi ha i Biscotti può cambiarli' using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  prima := case when tg_op = 'UPDATE' then coalesce(old.dati, '{}'::jsonb) else '{}'::jsonb end;
  dopo := coalesce(new.dati, '{}'::jsonb);
  ps := coalesce(prima->>'stato', '');
  ds := coalesce(dopo->>'stato', '');
  if coalesce(dopo->>'segnatoAlle', '') is distinct from coalesce(prima->>'segnatoAlle', '') then
    if not public.ha_permesso('biscComanda') then
      raise exception 'Non hai il permesso di mandare comande di biscotti' using errcode = '42501';
    end if;
  elsif ds is distinct from ps then
    if (ds = 'tolto' or ps = 'tolto') and not public.ha_permesso('biscTogli') then
      raise exception 'Non hai il permesso di togliere o recuperare i biscotti' using errcode = '42501';
    end if;
    if (ds = 'fatto' or ps = 'fatto') and not public.ha_permesso('biscFatto') then
      raise exception 'Non hai il permesso di segnare i biscotti «Fatto»' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

-- impostazioni: numeri e permessi solo il titolare; biscotti nuovi e reparti con il loro permesso
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
  if tg_op <> 'DELETE' and not public.e_titolare() then
    if new.chiave = 'biscotti' and (new.dati->'aggiunte') is distinct from
       (case when tg_op = 'UPDATE' then old.dati->'aggiunte' else null end)
       and not public.ha_permesso('biscNuovo') then
      raise exception 'Non hai il permesso di aggiungere biscotti all''elenco' using errcode = '42501';
    end if;
    if new.chiave = 'reparti' and new.dati is distinct from (case when tg_op = 'UPDATE' then old.dati else null end)
       and not (public.ha_permesso('panSposta') or public.ha_permesso('giroSposta')) then
      raise exception 'Non hai il permesso di spostare le cose di reparto' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
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
