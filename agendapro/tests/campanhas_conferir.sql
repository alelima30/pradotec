-- ===========================================================================
-- O que o 98_campanhas.sql tinha que ter deixado no banco.
-- Carregado por tests/rodar.sh depois de colar o arquivo.
-- ===========================================================================

\set ON_ERROR_STOP on

select t_verdade('a tabela campanhas existe',
  to_regclass('public.campanhas') is not null);
select t_verdade('a tabela campanha_destinatarios existe',
  to_regclass('public.campanha_destinatarios') is not null);

select t_verdade('a ficha do cliente ganhou o aceita_marketing',
  exists (select 1 from information_schema.columns
           where table_name = 'clientes' and column_name = 'aceita_marketing'));

select t_igual('as 7 funções do módulo estão lá',
  (select count(distinct proname) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('publico_da_campanha','montar_fila','iniciar_campanha',
                        'cancelar_campanha','placar_campanha','fila_proxima',
                        'fila_resultado')), 7);

select t_verdade('as duas tabelas estão com RLS ligado',
  (select bool_and(relrowsecurity) from pg_class
    where relname in ('campanhas','campanha_destinatarios')));

-- ⚠ A correção que veio junto, e o motivo de ela vir junto.
--
-- As funções do módulo conferem permissão com `if not e_gestor(x) then raise`.
-- Com o auxiliar devolvendo NULL, `not NULL` é NULL, o `if` não dispara e a
-- função segue como se a permissão existisse — foi assim que placar_campanha()
-- devolveu o placar da campanha de outro salão. Instalar o módulo sem estes
-- auxiliares corrigidos é instalar o buraco junto.
select t_verdade('e_equipe() de um salão inexistente devolve false, não NULL',
  public.e_equipe('00000000-0000-0000-0000-000000000000') = false);
select t_verdade('e_gestor() de um salão inexistente devolve false, não NULL',
  public.e_gestor('00000000-0000-0000-0000-000000000000') = false);
select t_verdade('tem_acesso() de um salão inexistente devolve false, não NULL',
  public.tem_acesso('00000000-0000-0000-0000-000000000000') = false);

-- A fila é do worker. Se `authenticated` alcançasse, qualquer dono de salão
-- varreria telefone da plataforma inteira.
select t_falso('anon não executa a fila do worker',
  has_function_privilege('anon', 'public.fila_proxima(int)', 'execute'));
select t_falso('nem quem só fez login',
  has_function_privilege('authenticated', 'public.fila_proxima(int)', 'execute'));
select t_falso('anon não alcança a tabela de campanhas',
  has_table_privilege('anon', 'public.campanhas', 'select'));
select t_falso('nem a de destinatários, que é onde estão os telefones',
  has_table_privilege('anon', 'public.campanha_destinatarios', 'select'));

-- ── O convite de equipe, que vem no mesmo arquivo ──────────────────────────
select t_verdade('a tabela convites_equipe existe',
  to_regclass('public.convites_equipe') is not null);
select t_verdade('com RLS ligado',
  (select relrowsecurity from pg_class where relname = 'convites_equipe'));

select t_igual('as 6 funções do convite estão lá',
  (select count(distinct proname) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('criar_convite','ver_convite','aceitar_convite',
                        'equipe_com_acesso','remover_acesso','revogar_convite')), 6);

-- `ver_convite` é a única que `anon` alcança, e é por desenho: a página do
-- convite precisa dizer de que salão se trata antes de a pessoa ter conta.
select t_verdade('anon executa ver_convite',
  has_function_privilege('anon', 'public.ver_convite(uuid)', 'execute'));
select t_falso('mas NÃO cria convite',
  has_function_privilege('anon', 'public.criar_convite(uuid, text, text, uuid)', 'execute'));
select t_falso('nem aceita convite sem estar logado',
  has_function_privilege('anon', 'public.aceitar_convite(uuid)', 'execute'));
select t_falso('e não alcança a tabela onde moram os segredos dos links',
  has_table_privilege('anon', 'public.convites_equipe', 'select'));
