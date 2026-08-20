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

insert into public.assinaturas (salao_id, plano, status) values
  ('5a100000-0000-0000-0000-00000000000a', 'time', 'ativa'),
  ('5a100000-0000-0000-0000-00000000000b', 'time', 'ativa');

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


\echo ''
\echo 'Lista de espera — a fila não é pública'

insert into public.lista_espera (id, salao_id, cliente_id, de, ate) values
  ('ee000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-00000000000a',
   'c1100000-0000-0000-0000-00000000000a', '2026-09-10', '2026-09-20'),  -- Maria
  ('ee000000-0000-0000-0000-00000000000d', '5a100000-0000-0000-0000-00000000000a',
   'c1100000-0000-0000-0000-00000000000d', '2026-09-10', '2026-09-20');  -- Joana

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'c0000000-0000-0000-0000-00000000000c';  -- Maria

  do $$ begin perform t_igual(
    'a cliente vê só o próprio lugar na fila',
    (select count(*) from public.lista_espera), 1); end $$;

  do $$ begin perform t_igual(
    'não descobre quem mais está esperando',
    (select count(*) from public.lista_espera
      where cliente_id = 'c1100000-0000-0000-0000-00000000000d'), 0); end $$;

  -- Desistir é dela; tirar a concorrente da fila, não.
  --
  -- Repare COMO isto é medido. O RLS não levanta erro num DELETE que não
  -- casa: ele simplesmente não apaga nada. Então a prova é o número de
  -- linhas afetadas, não a ausência de exceção.
  --
  -- A primeira versão deste caso conferia com `exists(...)` depois do
  -- delete — e acusou falso positivo, porque o `exists` também roda sob o
  -- RLS da Maria: ela nunca enxerga a linha da Joana, apagada ou não.
  -- "Não vejo" tinha sido lido como "apaguei".
  do $$
  declare n int;
  begin
    delete from public.lista_espera where id = 'ee000000-0000-0000-0000-00000000000d';
    get diagnostics n = row_count;
    if n = 0 then perform t_ok('não consegue tirar outra pessoa da fila');
    else perform t_falha('APAGOU o lugar de outra cliente na fila');
    end if;
  end $$;

  do $$
  declare n int;
  begin
    delete from public.lista_espera where id = 'ee000000-0000-0000-0000-00000000000a';
    get diagnostics n = row_count;
    if n = 1 then perform t_ok('mas desiste do lugar dela quando quiser');
    else perform t_falha('não conseguiu sair da própria fila');
    end if;
  end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';  -- Ana, dona

  do $$ begin perform t_igual(
    'a dona vê a fila inteira do salão dela',
    (select count(*) from public.lista_espera), 2); end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'e0000000-0000-0000-0000-00000000000e';  -- Zé, salão B

  do $$ begin perform t_igual(
    'o salão vizinho não vê a fila de espera do outro',
    (select count(*) from public.lista_espera), 0); end $$;
rollback;


\echo ''
\echo 'Autoatendimento — o dono se cadastra sozinho'

insert into auth.users (id) values ('f0000000-0000-0000-0000-00000000000f');
insert into public.perfis (id, nome, telefone)
values ('f0000000-0000-0000-0000-00000000000f', 'Rogério Alves', '+5511900000009');

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'f0000000-0000-0000-0000-00000000000f';

  -- Sem a função, ele não cria salão nenhum: a policy só deixa is_super().
  do $$
  begin
    if recusado($q$insert into public.saloes (slug, nome)
                   values ('na-marra', 'Na Marra')$q$)
    then perform t_ok('inserir salão direto na tabela é barrado');
    else perform t_falha('CRIOU salão passando por cima da policy');
    end if;
  end $$;

  -- Mas pela função, sim.
  do $$
  declare r record;
  begin
    select * into r from public.criar_salao(
      'Barbearia Os Meninos dá Vila', 'barbearia', null,
      '(11) 90000-0009', '123.456.789-09', 'indicacao', 'Barbeiro Responde');

    if r.slug = 'barbearia-os-meninos-da-vila'
    then perform t_ok('o apelido sai do nome, sem acento e sem espaço');
    else perform t_falha('apelido saiu como ' || r.slug);
    end if;

    if (select count(*) from public.saloes where id = r.salao_id) = 1
    then perform t_ok('o salão é criado pela função');
    else perform t_falha('o salão não apareceu');
    end if;

    if (select papel from public.vinculos
         where salao_id = r.salao_id
           and perfil_id = 'f0000000-0000-0000-0000-00000000000f') = 'dono'
    then perform t_ok('quem criou já entra como dono');
    else perform t_falha('o criador não virou dono — salão órfão');
    end if;

    if (select count(*) from public.profissionais where salao_id = r.salao_id) = 1
    then perform t_ok('o dono já entra como o primeiro profissional');
    else perform t_falha('não criou o primeiro profissional');
    end if;

    if (select status from public.assinaturas where salao_id = r.salao_id) = 'trial'
    then perform t_ok('a assinatura nasce em teste grátis');
    else perform t_falha('assinatura não nasceu em trial');
    end if;

    if (select trial_ate from public.assinaturas where salao_id = r.salao_id)
       = current_date + 7
    then perform t_ok('o teste tem prazo de 7 dias');
    else perform t_falha('prazo do teste saiu errado');
    end if;

    if (select indicado_por from public.assinaturas where salao_id = r.salao_id)
       = 'Barbeiro Responde'
    then perform t_ok('a origem da indicação fica registrada');
    else perform t_falha('perdeu de onde veio o cliente');
    end if;

    -- E o limite do trial vale desde o primeiro minuto.
    if recusado(format($q$insert into public.profissionais (salao_id, nome)
                          values (%L, 'Segundo barbeiro')$q$, r.salao_id))
    then perform t_ok('o teste grátis já nasce limitado a 1 profissional');
    else perform t_falha('o trial aceitou o segundo profissional');
    end if;
  end $$;

  -- Nome repetido não quebra: ganha apelido livre.
  do $$
  declare r record;
  begin
    select * into r from public.criar_salao('Barbearia Os Meninos dá Vila', 'barbearia');
    if r.slug = 'barbearia-os-meninos-da-vila-2'
    then perform t_ok('nome repetido vira apelido-2, sem erro na cara do dono');
    else perform t_falha('segundo apelido saiu como ' || r.slug);
    end if;
  end $$;

  -- A vista da própria conta.
  do $$
  declare a record;
  begin
    select * into a from public.minha_assinatura limit 1;
    if a.dias_de_teste = 7 and a.max_profissionais = 1 and a.profissionais_ativos = 1
    then perform t_ok('a vista mostra plano, uso e dias de teste restantes');
    else perform t_falha(format('vista trouxe dias=%s max=%s usados=%s',
      a.dias_de_teste, a.max_profissionais, a.profissionais_ativos));
    end if;
  end $$;

  do $$
  begin
    if recusado($q$update public.assinaturas set plano = 'salao'$q$)
    then perform t_ok('o dono não se promove sozinho para o plano maior');
    else
      if (select plano from public.assinaturas
           where salao_id in (select salao_id from public.vinculos
                               where perfil_id = auth.uid() and papel = 'dono')
           limit 1) = 'salao'
      then perform t_falha('TROCOU o próprio plano sem pagar');
      else perform t_ok('o dono não se promove sozinho para o plano maior');
      end if;
    end if;
  end $$;
rollback;

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'e0000000-0000-0000-0000-00000000000e';  -- Zé

  do $$ begin perform t_igual(
    'o dono de um salão não lê o documento fiscal de outro',
    (select count(*) from public.documentos_cobranca), 0); end $$;
rollback;

begin;
  set local role anon;
  -- A tela de cadastro consulta o apelido enquanto a pessoa digita, antes
  -- de existir login. Isso precisa funcionar sem expor a tabela.
  do $$
  begin
    if public.slug_disponivel('um-nome-que-ninguem-usou')
    then perform t_ok('quem não fez login consegue conferir se o apelido está livre');
    else perform t_falha('a consulta de apelido não funciona sem login');
    end if;
  end $$;

  do $$
  begin
    if not public.slug_disponivel('salao-a')
    then perform t_ok('apelido já usado é recusado');
    else perform t_falha('deixou usar apelido ocupado');
    end if;
  end $$;

  do $$
  begin
    if recusado($q$select public.criar_salao('Sem Login')$q$)
    then perform t_ok('criar salão sem login é barrado');
    else perform t_falha('CRIOU salão sem ninguém logado');
    end if;
  end $$;
rollback;

\echo ''
\echo 'As imagens do salão (Storage)'

-- A logo e a foto do salão são públicas para LER — é a vitrine, e imagem atrás
-- de login numa página pública é imagem que não carrega. O que precisa de
-- trava é a ESCRITA: sem ela, qualquer dono logado troca a logo do concorrente
-- por um palavrão, e o estrago aparece para os clientes dele.
--
-- A policy decide pela primeira pasta do caminho, que é o uuid do salão. Os
-- testes cercam os quatro caminhos possíveis: a própria pasta, a do vizinho,
-- a raiz do balde e uma pasta com nome inventado.
--
-- O `begin`/`set local role` fica aqui fora, e não dentro do DO: `SET LOCAL`
-- precisa de uma transação de verdade, e psql abre uma implícita por comando.
-- Dentro do bloco ele não pega, o teste roda como superusuário e passa por
-- cima do RLS — verde mentiroso, que é o pior resultado possível.

begin;
  set local role authenticated;
  set local request.jwt.claim.sub = 'a0000000-0000-0000-0000-00000000000a';

  do $$
  declare n int;
  begin
    insert into storage.objects (bucket_id, name)
    values ('salao', '5a100000-0000-0000-0000-00000000000a/logo.jpg');
    get diagnostics n = row_count;
    if n = 1 then perform t_ok('a dona envia imagem na pasta do próprio salão');
    else perform t_falha('não conseguiu enviar na própria pasta'); end if;
  end $$;

  do $$ begin
    if recusado($q$insert into storage.objects (bucket_id, name)
                   values ('salao','5a100000-0000-0000-0000-00000000000b/logo.jpg')$q$)
    then perform t_ok('não escreve na pasta de outro salão');
    else perform t_falha('trocou a imagem do salão do vizinho'); end if;
  end $$;

  do $$ begin
    if recusado($q$insert into storage.objects (bucket_id, name)
                   values ('salao','solto.jpg')$q$)
    then perform t_ok('arquivo na raiz do balde, sem dono, é recusado');
    else perform t_falha('entrou arquivo sem pasta de salão'); end if;
  end $$;

  do $$ begin
    if recusado($q$insert into storage.objects (bucket_id, name)
                   values ('salao','qualquer/logo.jpg')$q$)
    then perform t_ok('pasta que não é uuid é recusada, sem derrubar a consulta');
    else perform t_falha('pasta inventada foi aceita'); end if;
  end $$;
commit;

begin;
  set local role anon;
  do $$ begin
    if (select count(*) from storage.objects where bucket_id = 'salao') >= 1
    then perform t_ok('quem não fez login LÊ as imagens — a vitrine precisa disso');
    else perform t_falha('a vitrine não enxerga as imagens'); end if;
  end $$;
commit;

\echo ''
\echo 'A exposição automática do Supabase'

-- Este banco de teste nasce com a mesma opção que o Supabase liga sozinho:
-- ALL para anon e authenticated em toda tabela nova do schema public. O que
-- se prova aqui é que o 02_rls.sql desfaz isso.
--
-- Por que importa, se o RLS já segura: com o grant no lugar, uma policy
-- escrita com pressa — um `using (true)` — vira vazamento público na hora.
-- Sem o grant, a mesma policy descuidada continua inalcançável, porque quem
-- não fez login nem chega na tabela para a policy ser consultada. Duas
-- camadas custam uma linha de SQL.
do $$
declare v_sobrou text;
begin
  select string_agg(distinct table_name, ', ' order by table_name)
    into v_sobrou
    from information_schema.role_table_grants g
   where g.grantee = 'anon' and g.table_schema = 'public'
     and g.table_name in (select table_name from information_schema.tables
                           where table_schema='public' and table_type='BASE TABLE')
     -- `planos` é exceção deliberada: é tabela de preço, e a tela de cadastro
     -- precisa mostrá-la antes de a pessoa ter conta.
     and g.table_name <> 'planos';

  if v_sobrou is null then
    perform t_ok('anon não alcança nenhuma tabela — só as vistas e planos');
  else
    perform t_falha('anon ainda alcança: ' || v_sobrou);
  end if;
end $$;

do $$
declare v_n int;
begin
  -- As vistas públicas TÊM que continuar de pé depois da revogação. Elas são
  -- a vitrine: sem elas o link do salão abre vazio para a cliente.
  select count(*) into v_n from information_schema.role_table_grants
   where grantee='anon' and table_schema='public'
     and table_name in ('saloes_publicos','servicos_publicos','profissionais_publicos')
     and privilege_type='SELECT';
  perform t_igual('as 3 vistas públicas sobreviveram à revogação', v_n::bigint, 3);
end $$;

do $$
declare v_n int;
begin
  -- E o dono logado precisa continuar escrevendo o que é dele.
  select count(*) into v_n from information_schema.role_table_grants
   where grantee='authenticated' and table_schema='public'
     and table_name='agendamentos' and privilege_type in ('SELECT','INSERT','UPDATE','DELETE');
  perform t_igual('authenticated mantém as 4 operações na agenda', v_n::bigint, 4);
end $$;

do $$
declare v_n int;
begin
  -- Mas NÃO ganha escrita em assinaturas: é a linha que decide quanto ele
  -- paga. Quem muda plano é a plataforma, nunca o salão.
  select count(*) into v_n from information_schema.role_table_grants
   where grantee='authenticated' and table_schema='public'
     and table_name='assinaturas' and privilege_type in ('INSERT','UPDATE','DELETE');
  perform t_igual('e continua sem poder escrever na própria assinatura', v_n::bigint, 0);
end $$;
