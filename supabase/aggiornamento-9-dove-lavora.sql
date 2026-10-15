-- =====================================================================
--  Aggiornamento 9 · «Dove lavora» per tutti, anche con il Giro consegne
--  Incollare in Supabase → SQL Editor → Run. Si può rilanciare.
--  Non cambia e non cancella i dati già salvati: cambia solo due funzioni che controllano i permessi.
--  Va lanciato dopo l'aggiornamento 8.
--
--  - Chi fa il giro può lavorare anche in un negozio o al Panificio (per esempio zio Michele:
--    giro e Panificio), e chi è di un negozio o del Panificio anche al giro.
--    Nelle impostazioni condivise: 'permessi' → persone → "<id>" → luoghi: ["panificio", "consegne", …].
--  - Prima il giro a un negozio si dava con «Vedere il giro consegne» (consegne: true): vale ancora
--    come il posto «Giro consegne».
--  - Come prima: chi lavora in più posti ha un permesso se ce l'ha in almeno uno dei suoi posti.
--  Se si cambia una regola nell'app (sorgente/app.html: luoghiPer, POSTI_LAVORO), cambiarla anche qui.
-- =====================================================================

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
  -- i posti in più (negozi, Panificio, Giro consegne), per tutti i ruoli
  if jsonb_typeof(e->'luoghi') = 'array' then
    for p in select jsonb_array_elements_text(e->'luoghi') loop
      if p in ('corso', 'piazza-nenni', 'panificio', 'consegne') and public.permesso_nel_posto(k, public.tipo_posto(p), e) then return true; end if;
    end loop;
  end if;
  -- il giro dato prima con «Vedere il giro consegne»
  if r <> 'consegne' and e->'consegne' = 'true'::jsonb and public.permesso_nel_posto(k, 'consegne', e) then return true; end if;
  return false;
end $$;
revoke all on function public.ha_permesso(text) from public, anon;
grant execute on function public.ha_permesso(text) to authenticated;

-- i nomi dei posti dove lavora chi scrive ('Corso', 'Piazza Nenni', 'Panificio'; il giro no)
create or replace function public.miei_posti() returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  r text;
  e jsonb;
  out text[] := '{}';
  p text;
begin
  select ruolo into r from public.profili where id = auth.uid() and attivo and not sospeso;
  if r is null or r not in ('corso', 'piazza-nenni', 'panificio', 'consegne') then return out; end if;
  select dati->'persone'->(auth.uid()::text)->'luoghi' into e from public.impostazioni where chiave = 'permessi';
  for p in select r union select x from jsonb_array_elements_text(case when jsonb_typeof(e) = 'array' then e else '[]'::jsonb end) x loop
    out := out || case p when 'corso' then 'Corso' when 'piazza-nenni' then 'Piazza Nenni' when 'panificio' then 'Panificio' end;
  end loop;
  return array_remove(out, null);
end $$;
revoke all on function public.miei_posti() from public, anon;
grant execute on function public.miei_posti() to authenticated;

-- Fatto. Deve comparire "Success. No rows returned".
