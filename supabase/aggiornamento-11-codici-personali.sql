-- =====================================================================
--  Aggiornamento 11 · Si entra con un codice personale, senza PIN
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati (richieste, prenotazioni,
--  biscotti, stati, persone, permessi, notifiche).
--
--  Deciso dal proprietario il 19 ottobre (punto 37 della lista dei lavori):
--  - Niente più PIN e niente più codici fissi dei negozi.
--  - Il titolare crea un codice per UNA persona: per una persona nuova
--    («Aggiungi persona»: nome e posto li scrive il titolare) oppure per chi
--    si è scollegato (cambio di telefono, app cancellata, «Esci»).
--  - Il codice vale UNA volta sola. Se non si usa, dopo un certo numero di ore
--    non vale più (Impostazioni, «codice», di partenza 24 ore).
--  - Chi è già dentro resta dentro: il PIN smette di funzionare (la password
--    nascosta diventa a caso) ma il telefono resta collegato.
--  - Il codice per un titolare lo crea l'altro titolare. Se si scollegano tutti
--    e due, il codice si crea da qui:  select public.codice_di_emergenza('Alessandro');
--  I codici non si salvano in chiaro: solo la loro «impronta».
-- =====================================================================

create table if not exists public.codici_persona (
  id         uuid primary key default gen_random_uuid(),
  impronta   text not null unique,
  persona    uuid,                    -- vuoto = persona nuova, non ancora entrata
  nome       text not null,
  ruolo      text not null,
  email      text,                    -- solo per le persone nuove
  creato_da  uuid,
  creato     timestamptz not null default now(),
  scade      timestamptz not null,
  usato      timestamptz
);
alter table public.codici_persona enable row level security;
revoke all on public.codici_persona from public, anon, authenticated;

-- tentativi con un codice sbagliato: dopo 30 in 10 minuti si aspetta un po'
create table if not exists public.codici_tentativi (quando timestamptz not null default now());
alter table public.codici_tentativi enable row level security;
revoke all on public.codici_tentativi from public, anon, authenticated;

-- ---------- funzioni interne (non si chiamano dall'app) ----------

-- 6 lettere e numeri, senza quelli che si confondono (I, O, 0, 1)
create or replace function public.genera_codice() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  lettere constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(6);
  c text := '';
  i integer;
begin
  for i in 0..5 loop
    c := c || substr(lettere, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return c;
end $$;

create or replace function public.impronta_codice(c text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(upper(regexp_replace(coalesce(c, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex');
$$;

-- per quante ore vale un codice non usato (Impostazioni, «codice»)
create or replace function public.ore_codice() returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select case when (dati->>'codice') ~ '^[0-9]{1,2}$' then least(72, greatest(1, (dati->>'codice')::integer)) end
                     from public.impostazioni where chiave = 'numeri'), 24);
$$;

create or replace function public.crea_codice_interno(p_persona uuid, p_nome text, p_ruolo text, p_email text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c text;
  s timestamptz := now() + make_interval(hours => public.ore_codice());
begin
  -- un codice nuovo cancella quelli non ancora usati della stessa persona
  if p_persona is not null then
    delete from public.codici_persona where persona = p_persona and usato is null;
  else
    delete from public.codici_persona where persona is null and usato is null and lower(nome) = lower(p_nome);
  end if;
  delete from public.codici_persona where scade < now() - interval '90 days';
  loop
    c := public.genera_codice();
    begin
      insert into public.codici_persona (impronta, persona, nome, ruolo, email, creato_da, scade)
      values (public.impronta_codice(c), p_persona, p_nome, p_ruolo, p_email, auth.uid(), s);
      exit;
    exception when unique_violation then
      -- capita quasi mai: si prova un altro codice
      null;
    end;
  end loop;
  return jsonb_build_object('codice', c, 'scade', s, 'nome', p_nome, 'ruolo', p_ruolo);
end $$;

-- ---------- titolari: creare un codice ----------
-- per_persona = una persona già registrata (si è scollegata), oppure vuoto con nome e posto per una persona nuova
create or replace function public.nuovo_codice(per_persona uuid, nome_nuovo text, ruolo_nuovo text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  p record;
  n text;
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può creare i codici';
  end if;
  if per_persona is not null then
    if per_persona = auth.uid() then
      raise exception 'Il codice per te lo crea l''altro titolare';
    end if;
    select * into p from public.profili where id = per_persona and attivo;
    if not found then
      raise exception 'Persona non trovata';
    end if;
    return public.crea_codice_interno(p.id, p.nome, p.ruolo, null);
  end if;
  n := regexp_replace(btrim(coalesce(nome_nuovo, '')), '\s+', ' ', 'g');
  if length(n) < 2 or length(n) > 40 then
    raise exception 'Scrivi il nome (da 2 a 40 lettere)';
  end if;
  if coalesce(ruolo_nuovo, '') not in ('corso', 'piazza-nenni', 'panificio', 'consegne', 'titolare') then
    raise exception 'Scegli dove lavora';
  end if;
  if exists (select 1 from public.profili where attivo and lower(nome) = lower(n)) then
    raise exception 'Questo nome è già usato: aggiungi l''iniziale del cognome';
  end if;
  -- la persona nuova ha un indirizzo a caso (non si vede mai): così non si confonde con nessun altro
  return public.crea_codice_interno(null, n, ruolo_nuovo,
    'ordini.p' || encode(extensions.gen_random_bytes(8), 'hex') || '@profumodipane.it');
end $$;

-- titolari: i codici creati e non ancora usati (il codice non si rilegge: se serve se ne crea uno nuovo)
create or replace function public.codici_in_attesa()
returns table (id uuid, persona uuid, nome text, ruolo text, scade timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può vedere i codici';
  end if;
  return query select c.id, c.persona, c.nome, c.ruolo, c.scade from public.codici_persona c
                where c.usato is null and c.scade > now() order by c.creato;
end $$;

-- titolari: annullare un codice non ancora usato
create or replace function public.annulla_codice(codice_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.e_titolare() then
    raise exception 'Solo il titolare può annullare i codici';
  end if;
  delete from public.codici_persona where id = codice_id and usato is null;
end $$;

-- ---------- chi entra: usare il codice ----------
-- Si chiama prima di entrare. password = una lunga parola a caso fatta dal telefono, che nessuno
-- deve ricordare: il telefono resta collegato. Risponde { ok, email, crea, nuovo } oppure { ok: false, errore }.
create or replace function public.usa_codice(codice text, password text)
returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  x record;
  em text;
  uid uuid;
begin
  delete from public.codici_tentativi where quando < now() - interval '1 day';
  if (select count(*) from public.codici_tentativi where quando > now() - interval '10 minutes') >= 30 then
    return jsonb_build_object('ok', false, 'errore', 'troppi');
  end if;
  if length(coalesce(password, '')) < 20 then
    return jsonb_build_object('ok', false, 'errore', 'telefono');
  end if;
  select * into x from public.codici_persona where impronta = public.impronta_codice(codice) for update;
  if not found then
    insert into public.codici_tentativi default values;
    return jsonb_build_object('ok', false, 'errore', 'sbagliato');
  end if;
  if x.usato is not null or x.scade < now() then
    return jsonb_build_object('ok', false, 'errore', 'scaduto');
  end if;
  if x.persona is not null then
    -- chi si era scollegato: stessa persona, stessi permessi, stesse cose fatte
    if not exists (select 1 from public.profili where id = x.persona and attivo) then
      return jsonb_build_object('ok', false, 'errore', 'tolto');
    end if;
    update auth.users set encrypted_password = extensions.crypt(password, extensions.gen_salt('bf')), updated_at = now()
     where id = x.persona returning email into em;
    if em is null then
      return jsonb_build_object('ok', false, 'errore', 'tolto');
    end if;
    update public.codici_persona set usato = now() where id = x.id;
    return jsonb_build_object('ok', true, 'email', em, 'crea', false, 'nuovo', false);
  end if;
  -- persona nuova: l'account si crea dal telefono (o c'è già, se la prima volta non aveva finito)
  select id into uid from auth.users where email = x.email;
  if uid is not null then
    update auth.users set encrypted_password = extensions.crypt(password, extensions.gen_salt('bf')), updated_at = now() where id = uid;
  end if;
  return jsonb_build_object('ok', true, 'email', x.email, 'crea', uid is null, 'nuovo', true);
end $$;

-- persona nuova, ultimo passo: dopo essere entrata, il codice crea la sua scheda (nome e posto scelti dal titolare)
create or replace function public.completa_codice(codice text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  x record;
  r text;
begin
  if auth.uid() is null then
    raise exception 'Devi prima entrare';
  end if;
  select ruolo into r from public.profili where id = auth.uid() and attivo;
  if r is not null then
    return r;
  end if;
  select * into x from public.codici_persona where impronta = public.impronta_codice(codice) for update;
  if not found or x.usato is not null or x.scade < now() or x.persona is not null
     or (select email from auth.users where id = auth.uid()) is distinct from x.email then
    raise exception 'Codice non valido';
  end if;
  begin
    insert into public.profili (id, nome, ruolo) values (auth.uid(), x.nome, x.ruolo);
  exception when unique_violation then
    raise exception 'Questo nome è già usato';
  end;
  update public.codici_persona set usato = now(), persona = auth.uid() where id = x.id;
  return x.ruolo;
end $$;

-- se tutti e due i titolari si scollegano: si lancia da qui (SQL Editor), non dall'app
--   select public.codice_di_emergenza('Alessandro');
create or replace function public.codice_di_emergenza(nome_persona text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p record;
begin
  select * into p from public.profili where attivo and lower(nome) = lower(btrim(nome_persona));
  if not found then
    raise exception 'Persona non trovata';
  end if;
  return public.crea_codice_interno(p.id, p.nome, p.ruolo, null);
end $$;

-- ---------- i vecchi modi di entrare non valgono più ----------

-- il codice fisso del negozio non serve più
create or replace function public.registrati(codice_negozio text, nome_persona text)
returns text
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Per entrare serve un codice personale: chiedilo al titolare';
end $$;

create or replace function public.codici_negozio()
returns table (ruolo text, codice text)
language plpgsql stable security definer set search_path = public as $$
begin
  return;
end $$;

-- il PIN non funziona più: la password nascosta di tutti diventa a caso.
-- Chi è già dentro resta dentro (il collegamento del telefono non usa la password).
update auth.users
   set encrypted_password = extensions.crypt(encode(extensions.gen_random_bytes(24), 'base64'), extensions.gen_salt('bf'))
 where email like 'ordini.%@profumodipane.it';

-- ---------- chi può chiamare cosa ----------

revoke all on function public.genera_codice() from public, anon, authenticated;
revoke all on function public.impronta_codice(text) from public, anon, authenticated;
revoke all on function public.ore_codice() from public, anon, authenticated;
revoke all on function public.crea_codice_interno(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.codice_di_emergenza(text) from public, anon, authenticated;

revoke all on function public.nuovo_codice(uuid, text, text) from public, anon;
revoke all on function public.codici_in_attesa() from public, anon;
revoke all on function public.annulla_codice(uuid) from public, anon;
revoke all on function public.completa_codice(text) from public, anon;
revoke all on function public.usa_codice(text, text) from public;
grant execute on function public.nuovo_codice(uuid, text, text) to authenticated;
grant execute on function public.codici_in_attesa() to authenticated;
grant execute on function public.annulla_codice(uuid) to authenticated;
grant execute on function public.completa_codice(text) to authenticated;
grant execute on function public.usa_codice(text, text) to anon, authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
