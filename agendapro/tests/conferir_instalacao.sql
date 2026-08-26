-- ===========================================================================
-- AgendaPro — conferência da instalação
--
-- COLE ESTE ARQUIVO INTEIRO NO SQL EDITOR DO SUPABASE e clique em Run,
-- depois de rodar o 01_schema.sql e o 02_rls.sql.
--
-- Ele não altera nada: só olha o banco e devolve uma tabela dizendo o que
-- está no lugar e o que não está. Sem comando de psql, então funciona no
-- editor do navegador (o `tests/rodar.sh` é o caminho pela linha de comando).
--
-- Qualquer linha ✗ significa que o app vai se comportar de um jeito que os
-- testes não previram. Resolva antes de seguir.
-- ===========================================================================

with

-- A função que acha a ficha do cliente. Sem ela, a versão antiga (que
-- procurava só pelo telefone) continua no ar, e agendar dá erro de chave
-- duplicada para quem digita um número diferente do que está na ficha.
ficha_uma(n) as (
  select count(*) from pg_proc p
    join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and p.proname = 'ficha_do_cliente'
),

/* As três chaves que a vitrine passou a entregar. Isto também é o teste mais
   sensível a UM acidente comum: colar o arquivo com as quebras de linha
   perdidas. Quando isso acontece, cada `--` engole o resto da linha, quase
   nada é executado — e o editor mesmo assim responde "Success. No rows
   returned", porque um arquivo todo comentado de fato não faz nada.

   Aqui não tem como enganar: ou a função nova está no banco, ou não está. */
vitrine_nova(n) as (
  select count(*) from (
    select 1 from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.proname = 'vitrine'
       and pg_get_functiondef(p.oid) like '%''letra''%'
    union all
    select 1 from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.proname = 'vitrine'
       and pg_get_functiondef(p.oid) like '%''slideDe''%'
    union all
    select 1 from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public' and p.proname = 'vitrine'
       and pg_get_functiondef(p.oid) like '%''galeria''%'
  ) x
),

-- 1) RLS ligado em toda tabela nossa. Tabela sem RLS no Supabase é tabela
--    aberta na internet: a chave anônima está no HTML, por definição.
esperadas(nome) as (
  values ('saloes'),('perfis'),('vinculos'),('profissionais'),('servicos'),
         ('servicos_profissionais'),('jornadas'),('bloqueios'),('clientes'),
         ('agendamentos'),('agendamento_servicos'),('produtos'),('comandas'),
         ('comanda_itens'),('pagamentos'),('contadores'),('lista_espera'),
         ('planos'),('assinaturas'),('documentos_cobranca')
),

faltando_tabela as (
  select e.nome from esperadas e
   where not exists (select 1 from pg_tables t
                      where t.schemaname = 'public' and t.tablename = e.nome)
),

sem_rls as (
  select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in (select nome from esperadas)
     and not c.relrowsecurity
),

-- 2) Tabela protegida mas sem nenhuma policy fica inacessível para todo
--    mundo. É o certo para `contadores` e problema em qualquer outra.
sem_policy as (
  select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in (select nome from esperadas)
     and c.relname <> 'contadores'
     and not exists (select 1 from pg_policies p
                      where p.schemaname = 'public' and p.tablename = c.relname)
),

-- 3) A armadilha do `for all`: numa tabela onde a leitura é restrita, uma
--    policy ALL de escrita reabre o SELECT, porque as permissivas somam com
--    OU. Foi assim que a profissional voltou a ver a agenda das colegas.
for_all_perigoso as (
  select tablename || '.' || policyname as onde
    from pg_policies
   where schemaname = 'public'
     and cmd = 'ALL'
     and tablename in ('agendamentos','agendamento_servicos','comanda_itens')
),

-- 4) A trava anti-choque. Sem ela, duas recepcionistas marcam o mesmo
--    horário e ninguém percebe até o cliente chegar.
trava as (
  select count(*) as n from pg_constraint
   where conname = 'agenda_sem_choque' and contype = 'x'
),

-- 5) Vista sem security_invoker roda com os poderes de quem criou e passa
--    por cima do RLS das tabelas de baixo.
vista_furada as (
  select c.relname from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v'
     and c.relname = 'comandas_totais'
     and coalesce(
           (select option_value from pg_options_to_table(c.reloptions)
             where option_name = 'security_invoker'), 'false') <> 'true'
),

-- 6) As funções que as policies chamam precisam ser security definer E ter
--    search_path fixo — senão dá para sequestrar o nome de uma tabela.
funcoes(nome) as (
  values ('is_super'),('papel_no_salao'),('tem_acesso'),('e_equipe'),
         ('e_gestor'),('ve_agenda_toda'),('meu_cliente_id'),
         ('meu_profissional_id'),('salao_da_comanda'),('cliente_da_comanda'),
         ('tenho_item_na_comanda')
),

funcao_frouxa as (
  select p.proname || case
           when not p.prosecdef then ' (não é security definer)'
           else ' (sem search_path fixo)' end as detalhe
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in (select nome from funcoes)
     and (not p.prosecdef
          or not exists (select 1 from unnest(coalesce(p.proconfig, '{}'))
                              as cfg where cfg like 'search_path=%'))
),

funcao_ausente as (
  select f.nome from funcoes f
   where not exists (select 1 from pg_proc p
                       join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = f.nome)
),

-- 7) A vitrine pública precisa abrir para quem não fez login; as tabelas,
--    não. Se `anon` alcançar uma tabela, a vitrine virou porta dos fundos.
anon_em_tabela as (
  select table_name from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public'
     and table_name in (select nome from esperadas)
     -- `planos` é exceção deliberada: é tabela de preço, e a página de
     -- cadastro precisa mostrá-la antes de a pessoa ter conta.
     and table_name <> 'planos'
),

-- 7b) O BANCO MEIO APLICADO
--
--     O 02_rls.sql começa com `revoke all on all tables`, e `all tables`
--     inclui vistas. Os arquivos seguintes devolvem o que deve ser devolvido —
--     o 03 dá `minha_assinatura` para quem fez login. Instalação completa,
--     ordem certa, tudo no lugar.
--
--     Mas quem reaplica só o 02 — o que é natural querendo reforçar a
--     segurança — zera sem ninguém devolver. O sintoma que chega é
--     "permission denied for view minha_assinatura" no painel do plano, uma
--     frase que parece defeito da tela e não fala em permissão perdida.
--
--     Daí este item: ele não pergunta se a segurança está apertada, pergunta
--     se ela ficou apertada DEMAIS por meia aplicação. A cura é colar o
--     00_tudo.sql inteiro.
concessoes(nome, papel) as (
  values ('minha_assinatura','authenticated'),
         ('comandas_totais', 'authenticated'),
         ('planos',          'anon')
),
concessao_faltando as (
  select c.nome from concessoes c
   where not exists (
     select 1 from information_schema.role_table_grants g
      where g.table_schema = 'public' and g.table_name = c.nome
        and g.grantee = c.papel and g.privilege_type = 'SELECT')
),

-- 8) O par de gatilhos que impede marcar em cima de um bloqueio (almoço,
--    médico, feriado). A trava EXCLUDE não alcança: são duas tabelas.
balde as (
  select count(*) as n from storage.buckets where id = 'salao' and public
),
pol_img as (
  select count(*) as n from pg_policies
   where schemaname = 'storage' and policyname like 'img_%'
),
gatilhos(nome, tabela) as (
  values ('tg_agend_vs_bloqueio','agendamentos'),
         ('tg_bloqueio_vs_agend','bloqueios'),
         ('tg_limite_agendamentos','agendamentos'),
         ('tg_cota_profissional','agendamentos'),
         ('tg_limite_prof','profissionais')
),

gatilho_faltando as (
  select g.nome from gatilhos g
   where not exists (
     select 1 from pg_trigger t
       join pg_class c on c.oid = t.tgrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = g.tabela
        and t.tgname = g.nome and not t.tgisinternal)
),

vitrine(nome) as (
  values ('saloes_publicos'),('servicos_publicos'),('profissionais_publicos')
),

-- O catálogo tem que estar FECHADO para quem não fez login. Já foi o
-- contrário: as três vistas abertas deixavam qualquer um listar todos os
-- salões da plataforma com nome, endereço e WhatsApp. Quem abre a página de
-- agendamento agora é a função vitrine(), que só responde a quem já sabe o
-- apelido do salão.
catalogo_aberto as (
  select v.nome from vitrine v
   where exists (select 1 from information_schema.role_table_grants g
                  where g.grantee = 'anon' and g.table_schema = 'public'
                    and g.table_name = v.nome and g.privilege_type = 'SELECT')
),

vitrine_sem_funcao as (
  select 1 where not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'vitrine'
       and has_function_privilege('anon', p.oid, 'execute'))
),

extensao as (
  select count(*) as n from pg_extension where extname = 'btree_gist'
),

-- A trava do telefone da ficha. Sem ela, o painel volta a gravar
-- "(11) 98888-7777" onde o caminho da cliente grava "11988887777", e a mesma
-- pessoa fica com duas fichas — histórico partido no meio.
trava_tel as (
  select count(*) as n from pg_constraint
   where conname = 'cli_tel_so_digitos'
     and conrelid = 'public.clientes'::regclass
),

-- O que sobrou fora do formato depois da migração.
--
-- Não é acidente: a migração deixa de propósito as fichas que colidem, porque
-- juntar duas fichas é mover agendamento e comanda de uma para a outra, e
-- isso some com dinheiro ou com atendimento sem ninguém ficar sabendo qual.
-- O que aparece aqui é a lista de quem precisa da decisão do salão.
tel_torto as (
  select c.nome || ' (' || c.telefone || ')' as quem
    from public.clientes c
   where c.telefone is not null
     and c.telefone <> coalesce(public.so_digitos(c.telefone), '')
   order by c.nome
   limit 20
)

-- ── O relatório ────────────────────────────────────────────────────────────
select * from (
  select 1 as ord,
         case when (select count(*) from faltando_tabela) = 0
              then '✓' else '✗' end as ok,
         'As 20 tabelas existem' as verificacao,
         coalesce((select string_agg(nome, ', ') from faltando_tabela),
                  'todas presentes') as detalhe

  union all select 2,
         case when (select count(*) from sem_rls) = 0 then '✓' else '✗' end,
         'RLS ligado em todas elas',
         coalesce((select string_agg(relname, ', ') from sem_rls) || ' SEM RLS',
                  'nenhuma exposta')

  union all select 3,
         case when (select count(*) from sem_policy) = 0 then '✓' else '✗' end,
         'Toda tabela tem policy (menos contadores, de propósito)',
         coalesce((select string_agg(relname, ', ') from sem_policy) || ' sem policy',
                  'ok')

  union all select 4,
         case when (select count(*) from for_all_perigoso) = 0 then '✓' else '✗' end,
         'Nenhuma policy ALL onde a leitura é restrita',
         coalesce((select string_agg(onde, ', ') from for_all_perigoso)
                  || ' — reabre o SELECT para a equipe inteira',
                  'ok')

  union all select 5,
         case when (select n from trava) = 1 then '✓' else '✗' end,
         'Trava anti-choque da agenda instalada',
         case when (select n from trava) = 1
              then 'agenda_sem_choque ativa'
              else 'FALTA a constraint agenda_sem_choque' end

  union all select 6,
         case when (select n from extensao) = 1 then '✓' else '✗' end,
         'Extensão btree_gist presente (a trava depende dela)',
         case when (select n from extensao) = 1 then 'ok'
              else 'rode: create extension btree_gist;' end

  union all select 7,
         case when (select count(*) from vista_furada) = 0 then '✓' else '✗' end,
         'comandas_totais com security_invoker',
         case when (select count(*) from vista_furada) = 0 then 'ok'
              else 'a vista passa por cima do RLS — qualquer um lê o faturamento alheio' end

  union all select 8,
         case when (select count(*) from funcao_ausente) = 0 then '✓' else '✗' end,
         'As 11 funções das policies existem',
         coalesce((select string_agg(nome, ', ') from funcao_ausente) || ' faltando',
                  'todas presentes')

  union all select 9,
         case when (select count(*) from funcao_frouxa) = 0 then '✓' else '✗' end,
         'Todas com security definer e search_path fixo',
         coalesce((select string_agg(detalhe, '; ') from funcao_frouxa), 'ok')

  union all select 10,
         case when (select count(*) from anon_em_tabela) = 0 then '✓' else '✗' end,
         'Quem não fez login não alcança nenhuma tabela',
         coalesce((select string_agg(table_name, ', ') from anon_em_tabela)
                  || ' liberada para anon', 'ok')

  union all select 11,
         case when (select count(*) from catalogo_aberto) = 0
                    and (select count(*) from vitrine_sem_funcao) = 0
              then '✓' else '✗' end,
         'A vitrine abre por apelido, e o catálogo não é folheável',
         case
           when (select count(*) from catalogo_aberto) > 0 then
             (select string_agg(nome, ', ') from catalogo_aberto)
             || ' aberta para anon — dá para listar todos os salões'
           when (select count(*) from vitrine_sem_funcao) > 0 then
             'a função vitrine() não existe ou anon não pode executá-la'
           else 'ok' end

  union all select 12,
         case when (select count(*) from gatilho_faltando) = 0 then '✓' else '✗' end,
         'As 5 travas de agenda e de plano estão instaladas',
         coalesce((select string_agg(nome, ', ') from gatilho_faltando)
                  || ' faltando', 'ok')

  union all select 13,
         case when (select n from balde) = 1 then '✓' else '✗' end,
         'O balde de imagens existe e é público para leitura',
         case when (select n from balde) = 1 then 'ok'
              else 'rode o 04_imagens.sql — sem ele a logo não sobe' end

  union all select 14,
         case when (select n from pol_img) = 4 then '✓' else '✗' end,
         'As 4 policies do balde estão no lugar',
         case when (select n from pol_img) = 4 then 'ok'
              else 'só ' || (select n from pol_img) || ' de 4 — um salão pode '
                   || 'trocar a imagem do outro' end

  union all select 16,
         case when (select n from ficha_uma) = 1 then '✓' else '✗' end,
         'A ficha do cliente é procurada pelo perfil, não só pelo telefone',
         case when (select n from ficha_uma) = 1 then 'ok'
              else 'falta ficha_do_cliente() — quem marca com um número '
                || 'diferente do que está na ficha leva "duplicate key value '
                || 'violates unique constraint ux_cli_perfil" e não consegue '
                || 'agendar. Cole o 00_tudo.sql inteiro de novo' end

  union all select 17,
         case when (select n from vitrine_nova) = 3 then '✓' else '✗' end,
         'A vitrine entrega letra, slide e galeria para a capa',
         case when (select n from vitrine_nova) = 3 then 'ok'
              else 'a vitrine() é de uma versão anterior: a letra do nome, a '
                || 'escolha do slide e a galeria de fotos e vídeos não chegam '
                || 'na página da cliente. Cole o 00_tudo.sql inteiro de novo' end

  union all select 18,
         case when (select n from trava_tel) = 1 then '✓' else '✗' end,
         'O telefone da ficha só entra em dígitos',
         case when (select n from trava_tel) = 1 then 'ok'
              else 'falta a trava cli_tel_so_digitos — o telefone com máscara '
                || 'volta a entrar, e a mesma pessoa vira duas fichas. Cole o '
                || 'supabase/99_remendo.sql' end

  union all select 19,
         case when (select count(*) from tel_torto) = 0 then '✓' else '⚠' end,
         'Nenhuma ficha antiga ficou com o telefone fora do formato',
         coalesce((select string_agg(quem, ', ') from tel_torto)
                  || ' — a migração não mexeu nelas porque limpar criaria dois '
                  || 'telefones iguais no mesmo salão: é a mesma pessoa em duas '
                  || 'fichas. Junte à mão, no painel, decidindo qual fica',
                  'ok')

  union all select 15,
         case when (select count(*) from concessao_faltando) = 0 then '✓' else '✗' end,
         'Quem fez login continua alcançando o que é dele',
         coalesce((select string_agg(nome, ', ') from concessao_faltando)
                  || ' sem select — o banco ficou meio aplicado; cole o '
                  || '00_tudo.sql inteiro de novo', 'ok')
) r order by ord;
