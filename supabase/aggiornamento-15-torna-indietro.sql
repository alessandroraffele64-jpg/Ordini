-- =====================================================================
--  Torna indietro dall'aggiornamento 15 (partenza vera, 28 ottobre 2026)
--  Da usare SOLO se serve: rimette i contatori dei biscotti com'erano alle 19:56
--  del 28 ottobre (presi con la manutenzione accesa) e la persona di prova «Prova Claude».
--  Incollare in Supabase → SQL Editor → Run.
-- =====================================================================

update public.biscotti set dati = dati || jsonb_build_object('volte', 2, 'volteFiniti', 2) where id = 'corso~anicini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'corso~fantasie-alle-mandorle';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'corso~giamberletti';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'corso~mattutini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 0) where id = 'corso~nzulli';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 0) where id = 'corso~sfogliatine-frutti-di-bosco';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 2) where id = 'piazza-nenni~anicini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 4, 'volteFiniti', 3) where id = 'piazza-nenni~biscotti-multicereali';
update public.biscotti set dati = dati || jsonb_build_object('volte', 2, 'volteFiniti', 1) where id = 'piazza-nenni~biscotti-prima-colazione';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 3) where id = 'piazza-nenni~cantuccini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 3) where id = 'piazza-nenni~chicchi-caffe';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 0) where id = 'piazza-nenni~crostini-di-grano';
update public.biscotti set dati = dati || jsonb_build_object('volte', 4, 'volteFiniti', 1) where id = 'piazza-nenni~cuor-di-nocciola';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~delizie-di-cioccolato';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 0) where id = 'piazza-nenni~dolcetti-alla-nocciola';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~fantasie-alle-mandorle';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~friselle-integrali';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~giamberletti';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~gocce-di-cioccolato';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 1) where id = 'piazza-nenni~limoncelli';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 2) where id = 'piazza-nenni~mattutini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 1) where id = 'piazza-nenni~nzulli';
update public.biscotti set dati = dati || jsonb_build_object('volte', 3, 'volteFiniti', 2) where id = 'piazza-nenni~nzullini';
update public.biscotti set dati = dati || jsonb_build_object('volte', 2, 'volteFiniti', 2) where id = 'piazza-nenni~pastetti-integrali';
update public.biscotti set dati = dati || jsonb_build_object('volte', 1, 'volteFiniti', 0) where id = 'piazza-nenni~trancini-alle-mandorle';

insert into public.profili (id, nome, ruolo, creato, attivo, sospeso)
values ('1d720083-53c6-4cbf-87b4-0361ebba1e67', 'Prova Claude', 'corso', '2026-10-20T08:57:04.236021+00:00', false, false)
on conflict (id) do nothing;

-- Fatto. Deve comparire "Success. No rows returned".
