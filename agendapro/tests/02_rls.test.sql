-- ===========================================================================
-- AgendaPro — testes de isolamento (RLS)
--
-- Estes são os testes que impedem manchete. Cada caso aqui simula alguém
-- logado chamando a API REST do Supabase DIRETO, sem passar pela nossa tela —
-- que é o que qualquer pessoa com o navegador aberto consegue fazer.
--
-- O truque: `set role authenticated` + `request.jwt.claim.sub` reproduz
-- exatamente o que o Supabase faz quando recebe um JWT. Sem trocar o papel,
-- o teste rodaria como superusuário e passaria por cima do RLS — verde
-- mentiroso, o pior tipo.
-- ===========================================================================

\set ON_ERROR_STOP on

-- ── Cenário: dois salões, duas clientes, uma dona, uma profissional ────────
-- Montado como superusuário, então o RLS não atrapalha a preparação.

insert into auth.users (id) values
  ('a0000000-0000-0000-0000-00000000000a'),  -- Ana   — dona do salão A
  ('b0000000-0000-0000-0000-00000000000b'),  -- Bia   — profissional no A
  ('c0000000-0000-0000-0000-00000000000c'),  -- Maria — cliente do A e do B
  ('d0000000-0000-0000-0000-00000000000d'),  -- Joana — cliente só do A
  ('e0000000-0000-0000-0000-00000000000e');  -- Zé    — dono do salão B

insert into public.saloes (id, slug, nome) values
  ('5a100000-0000-0000-0000-00000000000a', 'salao-a', 'Salão A'),
  ('5a100000-0000-0000-0000-00000000000b', 'salao-b', 'Barbearia B');

insert into public.perfis (id, nome, telefone) values
  ('a0000000-0000-0000-0000-00000000000a', 'Ana',   '+5511900000001'),
  ('b0000000-0000-0000-0000-00000000000b', 'Bia',   '+5511900000002'),
  ('c0000000-0000-0000-0000-00000000000c', 'Maria', '+5511900000003'),
  ('d0000000-0000-0000-0000-00000000000d', 'Joana', '+5511900000004'),
  ('e0000000-0000-0000-0000-00000000000e', 'Zé',    '+5511900000005');

insert into public.vinculos (perfil_id, salao_id, papel) values
  ('a0000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-00000000000a', 'dono'),
  ('b0000000-0000-0000-0000-00000000000b', '5a100000-0000-0000-0000-00000000000a', 'profissional'),
  ('c0000000-0000-0000-0000-00000000000c', '5a100000-0000-0000-0000-00000000000a', 'cliente'),
  ('c0000000-0000-0000-0000-00000000000c', '5a100000-0000-0000-0000-00000000000b', 'cliente'),
  ('d0000000-0000-0000-0000-00000000000d', '5a100000-0000-0000-0000-00000000000a', 'cliente'),
  ('e0000000-0000-0000-0000-00000000000e', '5a100000-0000-0000-0000-00000000000b', 'dono');

insert into public.profissionais (id, salao_id, perfil_id, nome) values
  ('9b000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-00000000000a',
   'a0000000-0000-0000-0000-00000000000a', 'Ana'),
  ('9b000000-0000-0000-0000-00000000000b', '5a100000-0000-0000-0000-00000000000a',
   'b0000000-0000-0000-0000-00000000000b', 'Bia'),
  ('9b000000-0000-0000-0000-00000000000e', '5a100000-0000-0000-0000-00000000000b',
   'e0000000-0000-0000-0000-00000000000e', 'Zé');

insert into public.clientes (id, salao_id, perfil_id, nome, telefone) values
  ('c1100000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-00000000000a',
   'c0000000-0000-0000-0000-00000000000c', 'Maria', '+5511900000003'),
  ('c1100000-0000-0000-0000-00000000000b', '5a100000-0000-0000-0000-00000000000b',
   'c0000000-0000-0000-0000-00000000000c', 'Maria', '+5511900000003'),
  ('c1100000-0000-0000-0000-00000000000d', '5a100000-0000-0000-0000-00000000000a',
   'd0000000-0000-0000-0000-00000000000d', 'Joana', '+5511900000004');

-- Maria tem 1 no salão A e 1 no B. Joana tem 1 no A, com a Bia.
insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim) values
  ('5a100000-0000-0000-0000-00000000000a', 'c1100000-0000-0000-0000-00000000000a',
   '9b000000-0000-0000-0000-00000000000a', '2026-09-01 09:00-03', '2026-09-01 10:00-03'),
  ('5a100000-0000-0000-0000-00000000000b', 'c1100000-0000-0000-0000-00000000000b',
   '9b000000-0000-0000-0000-00000000000e', '2026-09-01 14:00-03', '2026-09-01 15:00-03'),
  ('5a100000-0000-0000-0000-00000000000a', 'c1100000-0000-0000-0000-00000000000d',
   '9b000000-0000-0000-0000-00000000000b', '2026-09-01 11:00-03', '2026-09-01 12:00-03');

grant usage on schema auth to anon, authenticated;


\echo ''
\echo 'A cliente logada (Maria) chamando a API direto'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-00000000000c';

  -- O caso que motiva tudo: ela pede TODOS os agendamentos, sem filtro.
  do $$ begin perform t_igual(
    'pedindo a agenda inteira, só enxerga os 2 dela (1 em cada salão)',
    (select count(*) from public.agendamentos), 2); end $$;

  do $$ begin perform t_igual(
    'o agendamento da Joana não aparece para ela',
    (select count(*) from public.agendamentos
      where cliente_id = 'c1100000-0000-0000-0000-00000000000d'), 0); end $$;

  -- A tentativa mais óbvia de vazamento: baixar a lista de clientes.
  do $$ begin perform t_igual(
    'pedindo a lista de clientes, só volta a ficha dela',
    (select count(*) from public.clientes), 2); end $$;

  do $$ begin perform t_igual(
    'não alcança o telefone da Joana',
    (select count(*) from public.clientes where nome = 'Joana'), 0); end $$;

  -- Perfil é identidade global: nem o próprio salão lê o dos outros.
  do $$ begin perform t_igual(
    'só enxerga o próprio perfil',
    (select count(*) from public.perfis), 1); end $$;

  -- Ela precisa ver o cardápio dos dois salões onde é cliente.
  do $$ begin perform t_igual(
    'vê os profissionais dos salões em que é cliente',
    (select count(*) from public.profissionais), 3); end $$;

  -- Mas não a agenda de férias de ninguém.
  do $$ begin perform t_igual(
    'não lê os bloqueios (motivo é assunto interno)',
    (select count(*) from public.bloqueios), 0); end $$;

  -- E não pode se promover.
  do $$
  begin
    if recusado($q$update public.perfis set super_admin = true
                    where id = 'c0000000-0000-0000-0000-00000000000c'$q$)
    then perform t_ok('não consegue se tornar dona da plataforma');
    else
      if (select super_admin from public.perfis
           where id = 'c0000000-0000-0000-0000-00000000000c') then
        perform t_falha('VIROU super_admin editando o próprio perfil');
      else
        perform t_ok('não consegue se tornar dona da plataforma');
      end if;
    end if;
  end $$;

  do $$
  begin
    if recusado($q$insert into public.vinculos (perfil_id, salao_id, papel)
                   values ('c0000000-0000-0000-0000-00000000000c',
                           '5a100000-0000-0000-0000-00000000000a', 'dono')$q$)
    then perform t_ok('não consegue se dar o papel de dona do salão');
    else perform t_falha('SE PROMOVEU a dona do salão');
    end if;
  end $$;
rollback;


\echo ''
\echo 'A dona (Ana) — vê o salão dela, e só ele'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';

  do $$ begin perform t_igual(
    'vê os 2 agendamentos do salão dela',
    (select count(*) from public.agendamentos), 2); end $$;

  do $$ begin perform t_igual(
    'não vê nada do salão do Zé',
    (select count(*) from public.agendamentos
      where salao_id = '5a100000-0000-0000-0000-00000000000b'), 0); end $$;

  do $$ begin perform t_igual(
    'vê as 2 fichas de cliente do salão dela',
    (select count(*) from public.clientes), 2); end $$;

  do $$ begin perform t_igual(
    'enxerga só o próprio salão na tabela de salões',
    (select count(*) from public.saloes), 1); end $$;
rollback;


\echo ''
\echo 'A profissional (Bia) — vê a própria agenda'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'b0000000-0000-0000-0000-00000000000b';

  do $$ begin perform t_igual(
    'vê o agendamento dela, não o da Ana',
    (select count(*) from public.agendamentos), 1); end $$;

  do $$ begin perform t_igual(
    'o que ela vê é mesmo o dela',
    (select count(*) from public.agendamentos
      where profissional_id = '9b000000-0000-0000-0000-00000000000b'), 1); end $$;
rollback;


\echo ''
\echo 'O dono do outro salão (Zé) — a fronteira entre clientes da plataforma'

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'e0000000-0000-0000-0000-00000000000e';

  do $$ begin perform t_igual(
    'não alcança um único agendamento do salão A',
    (select count(*) from public.agendamentos
      where salao_id = '5a100000-0000-0000-0000-00000000000a'), 0); end $$;

  do $$ begin perform t_igual(
    'não alcança a carteira de clientes do salão A',
    (select count(*) from public.clientes
      where salao_id = '5a100000-0000-0000-0000-00000000000a'), 0); end $$;

  -- Maria é cliente dos dois. O Zé vê a ficha dela NO SALÃO DELE, e só.
  do $$ begin perform t_igual(
    'vê a Maria como cliente dele, sem enxergar o histórico dela no salão A',
    (select count(*) from public.clientes where nome = 'Maria'), 1); end $$;
rollback;


\echo ''
\echo 'Quem não fez login (anon)'

begin;
  set local role anon;

  do $$
  begin
    if recusado($q$select count(*) from public.agendamentos$q$)
    then perform t_ok('a tabela de agendamentos é inalcançável sem login');
    else perform t_igual('sem login, nenhum agendamento aparece',
                         (select count(*) from public.agendamentos), 0);
    end if;
  end $$;

  do $$
  begin
    if recusado($q$select count(*) from public.clientes$q$)
    then perform t_ok('a tabela de clientes é inalcançável sem login');
    else perform t_igual('sem login, nenhum cliente aparece',
                         (select count(*) from public.clientes), 0);
    end if;
  end $$;

  -- Mas a vitrine tem que abrir: é dela que sai a página de agendamento.
  do $$ begin perform t_igual(
    'a vitrine pública mostra os 2 salões ativos',
    (select count(*) from public.saloes_publicos), 2); end $$;
rollback;


\echo ''
\echo 'Comissão — um profissional não lê o que a colega ganhou'

insert into public.comandas (id, salao_id, cliente_id) values
  ('cc000000-0000-0000-0000-00000000000b', '5a100000-0000-0000-0000-00000000000a',
   'c1100000-0000-0000-0000-00000000000a');

insert into public.comanda_itens
  (comanda_id, tipo, descricao, qtd, preco_unit, profissional_id, comissao_pct) values
  ('cc000000-0000-0000-0000-00000000000b', 'servico', 'Corte da Ana', 1, 200,
   '9b000000-0000-0000-0000-00000000000a', 50),
  ('cc000000-0000-0000-0000-00000000000b', 'servico', 'Escova da Bia', 1, 80,
   '9b000000-0000-0000-0000-00000000000b', 30);

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'b0000000-0000-0000-0000-00000000000b';  -- Bia

  do $$ begin perform t_igual(
    'a profissional lê só o próprio item da comanda',
    (select count(*) from public.comanda_itens), 1); end $$;

  do $$ begin perform t_igual(
    'o valor que a colega ganhou fica invisível',
    (select count(*) from public.comanda_itens where descricao = 'Corte da Ana'), 0); end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';  -- Ana, dona

  do $$ begin perform t_igual(
    'a dona lê os itens todos, que é o fechamento do mês',
    (select count(*) from public.comanda_itens
      where comanda_id = 'cc000000-0000-0000-0000-00000000000b'), 2); end $$;

  -- A recepção precisa continuar conseguindo lançar item na comanda.
  do $$
  begin
    if recusado($q$insert into public.comanda_itens
                     (comanda_id, tipo, descricao, qtd, preco_unit)
                   values ('cc000000-0000-0000-0000-00000000000b','servico','Hidratação',1,60)$q$)
    then perform t_falha('a dona NÃO conseguiu lançar item na comanda');
    else perform t_ok('a dona continua lançando item na comanda');
    end if;
  end $$;
rollback;


\echo ''
\echo 'A vista de faturamento (o furo silencioso do Supabase)'

-- Uma vista SEM security_invoker roda com os poderes de quem a criou e passa
-- por cima do RLS das tabelas de baixo. Este caso existe para o dia em que
-- alguém criar uma vista nova e esquecer da cláusula.
insert into public.comandas (id, salao_id, cliente_id) values
  ('cc000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-00000000000a',
   'c1100000-0000-0000-0000-00000000000d');
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit)
  values ('cc000000-0000-0000-0000-00000000000a', 'servico', 'Corte', 1, 100);

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'e0000000-0000-0000-0000-00000000000e';  -- Zé, salão B

  do $$ begin perform t_igual(
    'o dono do salão B não lê o faturamento do salão A pela vista',
    (select count(*) from public.comandas_totais), 0); end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-00000000000c';  -- Maria

  -- A Maria tem uma comanda (a da seção de comissão) e a Joana tem outra.
  -- O que se prova aqui é que ela alcança a dela e não alcança a da Joana.
  do $$ begin perform t_igual(
    'a cliente lê a própria conta pela vista',
    (select count(*) from public.comandas_totais), 1); end $$;

  do $$ begin perform t_igual(
    'a conta da outra cliente não aparece na vista',
    (select count(*) from public.comandas_totais
      where id = 'cc000000-0000-0000-0000-00000000000a'), 0); end $$;
rollback;

\echo ''
\echo '── Isolamento verificado ──'
