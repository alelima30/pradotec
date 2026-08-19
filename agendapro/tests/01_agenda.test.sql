-- ===========================================================================
-- AgendaPro — testes do banco
--
--   bash tests/rodar.sh
--
-- Falhou um caso, o script inteiro para com erro (ON_ERROR_STOP). É de
-- propósito: teste que avisa baixinho vira paisagem.
--
-- O que se prova aqui é o que NÃO pode depender do navegador: a trava de
-- horário duplicado, a numeração da comanda e a conta da comissão.
-- ===========================================================================

\set ON_ERROR_STOP on

-- ── Cenário ────────────────────────────────────────────────────────────────
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'ana@salao.com'),
  ('22222222-2222-2222-2222-222222222222', 'cliente@teste.com');

insert into public.saloes (id, slug, nome, tipo) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'salao-da-ana', 'Salão da Ana', 'salao'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'barbearia-do-ze', 'Barbearia do Zé', 'barbearia');

-- Os salões do cenário assinam um plano que comporta a equipe. Sem isto o
-- gatilho de limite recusaria o segundo profissional — e recusaria certo.
insert into public.assinaturas (salao_id, plano, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'time', 'ativa'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'time', 'ativa');

insert into public.perfis (id, nome, telefone) values
  ('11111111-1111-1111-1111-111111111111', 'Ana Souza',   '+5511988887777'),
  ('22222222-2222-2222-2222-222222222222', 'Maria Silva', '+5511977776666');

insert into public.profissionais (id, salao_id, perfil_id, nome, comissao_pct) values
  ('bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111', 'Ana', 40);

insert into public.servicos (id, salao_id, nome, duracao_min, preco) values
  ('cccccccc-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'Corte feminino', 60, 90.00);

insert into public.clientes (id, salao_id, perfil_id, nome, telefone) values
  ('dddddddd-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222', 'Maria Silva', '+5511977776666');


\echo ''
\echo 'Trava de horário (a que o AdminPro faz no JavaScript)'

-- Base: Ana ocupada das 09:00 às 10:00 de 20/08.
insert into public.agendamentos
  (id, salao_id, cliente_id, profissional_id, inicio, fim)
values
  ('eeeeeeee-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   'dddddddd-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001',
   '2026-08-20 09:00-03', '2026-08-20 10:00-03');

do $$
begin
  if recusado($q$
      insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
      values ('aaaaaaaa-0000-0000-0000-000000000001',
              'dddddddd-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001',
              '2026-08-20 09:30-03', '2026-08-20 10:30-03')$q$)
  then perform t_ok('sobreposição parcial é recusada pelo banco');
  else perform t_falha('DEIXOU marcar 09:30 em cima de 09:00-10:00');
  end if;
end $$;

do $$
begin
  if recusado($q$
      insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
      values ('aaaaaaaa-0000-0000-0000-000000000001',
              'dddddddd-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001',
              '2026-08-20 09:15-03', '2026-08-20 09:45-03')$q$)
  then perform t_ok('agendamento inteiro dentro de outro é recusado');
  else perform t_falha('DEIXOU marcar 09:15-09:45 dentro de 09:00-10:00');
  end if;
end $$;

do $$
begin
  if recusado($q$
      insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
      values ('aaaaaaaa-0000-0000-0000-000000000001',
              'dddddddd-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001',
              '2026-08-20 09:00-03', '2026-08-20 10:00-03')$q$)
  then perform t_ok('horário idêntico é recusado');
  else perform t_falha('DEIXOU marcar exatamente o mesmo horário');
  end if;
end $$;

-- Encostado NÃO é conflito: 10:00 começa quando 09:00-10:00 termina.
insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001',
        '2026-08-20 10:00-03', '2026-08-20 11:00-03');
do $$ begin perform t_ok('horário encostado (10:00 logo após 09:00-10:00) é aceito'); end $$;

-- Outro profissional no mesmo horário pode: a trava é por profissional.
insert into public.profissionais (id, salao_id, nome)
values ('bbbbbbbb-0000-0000-0000-000000000002',
        'aaaaaaaa-0000-0000-0000-000000000001', 'Bia');

insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000002',
        '2026-08-20 09:00-03', '2026-08-20 10:00-03');
do $$ begin perform t_ok('outra profissional no mesmo horário é aceita'); end $$;

-- Cancelar devolve o horário para a agenda.
update public.agendamentos set status = 'cancelado'
 where id = 'eeeeeeee-0000-0000-0000-000000000001';

insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'dddddddd-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001',
        '2026-08-20 09:00-03', '2026-08-20 10:00-03');
do $$ begin perform t_ok('horário cancelado volta a ficar livre'); end $$;

-- Falta também libera (o cliente não veio, a cadeira está vaga).
do $$
declare n int;
begin
  update public.agendamentos set status = 'faltou'
   where inicio = '2026-08-20 10:00-03'
     and profissional_id = 'bbbbbbbb-0000-0000-0000-000000000001';
  insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'dddddddd-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          '2026-08-20 10:00-03', '2026-08-20 10:30-03');
  get diagnostics n = row_count;
  if n = 1 then perform t_ok('marcado como falta, o horário é reaproveitável');
  else perform t_falha('não consegui remarcar em cima de uma falta');
  end if;
end $$;

do $$
begin
  if recusado($q$
      insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
      values ('aaaaaaaa-0000-0000-0000-000000000001',
              'dddddddd-0000-0000-0000-000000000001',
              'bbbbbbbb-0000-0000-0000-000000000001',
              '2026-08-20 11:00-03', '2026-08-20 10:00-03')$q$)
  then perform t_ok('fim antes do início é recusado');
  else perform t_falha('DEIXOU gravar fim antes do início');
  end if;
end $$;


\echo ''
\echo 'Isolamento entre salões'

do $$
begin
  -- Cliente do salão A com profissional do salão A: ok. O caso perigoso é
  -- cruzar salões, e é a policy de RLS que barra (02_rls.sql). Aqui só
  -- garantimos que a ficha do cliente não vaza por chave estrangeira.
  if recusado($q$
      insert into public.clientes (salao_id, perfil_id, nome)
      values ('aaaaaaaa-0000-0000-0000-000000000001',
              '22222222-2222-2222-2222-222222222222', 'Maria de novo')$q$)
  then perform t_ok('mesma pessoa não duplica ficha no mesmo salão');
  else perform t_falha('DEIXOU criar duas fichas da mesma pessoa no mesmo salão');
  end if;
end $$;

-- Mas a MESMA pessoa pode ser cliente de outro salão — é o ponto do modelo.
insert into public.clientes (salao_id, perfil_id, nome)
values ('aaaaaaaa-0000-0000-0000-000000000002',
        '22222222-2222-2222-2222-222222222222', 'Maria Silva');
do $$ begin perform t_ok('a mesma pessoa é cliente em dois salões, com fichas separadas'); end $$;

insert into public.vinculos (perfil_id, salao_id, papel) values
  ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000001', 'cliente'),
  ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000002', 'cliente'),
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'dono'),
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002', 'profissional');
do $$ begin perform t_ok('um login, papéis diferentes em salões diferentes'); end $$;


\echo ''
\echo 'Telefone e cadastro'

do $$
begin
  if recusado($q$insert into auth.users (id) values ('33333333-3333-3333-3333-333333333333');
                 insert into public.perfis (id, nome, telefone)
                 values ('33333333-3333-3333-3333-333333333333', 'Fulano', '11988887777')$q$)
  then perform t_ok('telefone fora do padrão E.164 é recusado');
  else perform t_falha('ACEITOU telefone sem o +55');
  end if;
end $$;

do $$
begin
  if recusado($q$insert into auth.users (id) values ('44444444-4444-4444-4444-444444444444');
                 insert into public.perfis (id, nome, telefone)
                 values ('44444444-4444-4444-4444-444444444444', 'Outro', '+5511988887777')$q$)
  then perform t_ok('telefone repetido é recusado (uma pessoa, um login)');
  else perform t_falha('ACEITOU dois perfis com o mesmo telefone');
  end if;
end $$;


\echo ''
\echo 'Comanda, comissão e caixa'

insert into public.comandas (id, salao_id, cliente_id) values
  ('ffffffff-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   'dddddddd-0000-0000-0000-000000000001');
insert into public.comandas (id, salao_id, cliente_id) values
  ('ffffffff-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001',
   'dddddddd-0000-0000-0000-000000000001');
-- Outro salão recomeça do 1: a numeração é de cada casa.
insert into public.comandas (id, salao_id, cliente_id) values
  ('ffffffff-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000002',
   (select id from public.clientes where salao_id = 'aaaaaaaa-0000-0000-0000-000000000002'));

do $$
declare a bigint; b bigint; c bigint;
begin
  select numero into a from public.comandas where id = 'ffffffff-0000-0000-0000-000000000001';
  select numero into b from public.comandas where id = 'ffffffff-0000-0000-0000-000000000002';
  select numero into c from public.comandas where id = 'ffffffff-0000-0000-0000-000000000003';
  if a = 1 and b = 2 then perform t_ok('comanda numera em sequência dentro do salão');
  else perform t_falha(format('numeração saiu errada: %s, %s', a, b));
  end if;
  if c = 1 then perform t_ok('outro salão começa a numeração do 1 de novo');
  else perform t_falha(format('salão 2 devia começar em 1 e veio %s', c));
  end if;
end $$;

-- Corte de 90,00 com 40% de comissão, e um produto de 2 × 35,00 com 10%.
insert into public.comanda_itens
  (comanda_id, tipo, servico_id, descricao, qtd, preco_unit, profissional_id, comissao_pct)
values
  ('ffffffff-0000-0000-0000-000000000001', 'servico',
   'cccccccc-0000-0000-0000-000000000001', 'Corte feminino', 1, 90.00,
   'bbbbbbbb-0000-0000-0000-000000000001', 40);

insert into public.produtos (id, salao_id, nome, preco)
values ('99999999-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000001', 'Máscara capilar', 35.00);

insert into public.comanda_itens
  (comanda_id, tipo, produto_id, descricao, qtd, preco_unit, profissional_id, comissao_pct)
values
  ('ffffffff-0000-0000-0000-000000000001', 'produto',
   '99999999-0000-0000-0000-000000000001', 'Máscara capilar', 2, 35.00,
   'bbbbbbbb-0000-0000-0000-000000000001', 10);

do $$
declare v_total numeric; v_com numeric;
begin
  select total, comissao_total into v_total, v_com
    from public.comandas_totais where id = 'ffffffff-0000-0000-0000-000000000001';
  -- 90 + 70 = 160
  if v_total = 160.00 then perform t_ok('total da comanda soma os itens (90 + 2×35 = 160)');
  else perform t_falha(format('total deveria ser 160,00 e veio %s', v_total));
  end if;
  -- 90×40% = 36 ; 70×10% = 7 ; total 43
  if v_com = 43.00 then perform t_ok('comissão sai do banco, item a item (36 + 7 = 43)');
  else perform t_falha(format('comissão deveria ser 43,00 e veio %s', v_com));
  end if;
end $$;

do $$
begin
  if recusado($q$
      insert into public.comanda_itens
        (comanda_id, tipo, servico_id, produto_id, descricao, preco_unit)
      values ('ffffffff-0000-0000-0000-000000000001', 'servico',
              'cccccccc-0000-0000-0000-000000000001',
              '99999999-0000-0000-0000-000000000001', 'Confuso', 10)$q$)
  then perform t_ok('item não pode ser serviço e produto ao mesmo tempo');
  else perform t_falha('ACEITOU item apontando para serviço E produto');
  end if;
end $$;

do $$
begin
  if recusado($q$insert into public.pagamentos (comanda_id, forma, valor)
                 values ('ffffffff-0000-0000-0000-000000000001', 'bitcoin', 50)$q$)
  then perform t_ok('forma de pagamento fora da lista é recusada');
  else perform t_falha('ACEITOU forma de pagamento inválida');
  end if;
end $$;

insert into public.pagamentos (comanda_id, forma, valor, taxa) values
  ('ffffffff-0000-0000-0000-000000000001', 'pix',     100.00, 0),
  ('ffffffff-0000-0000-0000-000000000001', 'credito',  60.00, 2.34);
do $$ begin perform t_ok('pagamento dividido em duas formas na mesma comanda'); end $$;

\echo ''
\echo '── Todos os casos passaram ──'


\echo ''
\echo 'Lista de espera — a vaga que abre e a fila que espera'

-- Sábado 22/08: a Ana está cheia. Três pessoas na fila.
insert into public.lista_espera (id, salao_id, cliente_id, profissional_id,
                                 duracao_min, de, ate, turno, criado_em) values
  -- 1ª a chegar, mas só aceita a Ana
  ('11100000-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001', 60, '2026-08-22', '2026-08-22',
   'qualquer', '2026-08-15 10:00-03'),
  -- 2ª a chegar, aceita qualquer profissional
  ('11100000-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
   null, 60, '2026-08-22', '2026-08-22', 'qualquer', '2026-08-15 11:00-03'),
  -- 3ª: só de manhã
  ('11100000-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
   null, 60, '2026-08-22', '2026-08-22', 'manha', '2026-08-15 12:00-03'),
  -- 4ª: serviço longo, não cabe num buraco de 1h
  ('11100000-0000-0000-0000-000000000004',
   'aaaaaaaa-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
   null, 180, '2026-08-22', '2026-08-22', 'qualquer', '2026-08-15 13:00-03');

-- Abriu um buraco de 1h à TARDE com a Ana (alguém cancelou às 14h).
do $$
declare fila uuid[];
begin
  select array_agg(id order by ord) into fila from (
    select id, row_number() over () as ord
      from public.espera_para_vaga(
        'aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001',
        '2026-08-22 14:00-03', '2026-08-22 15:00-03')) x;

  -- Quem aceita qualquer profissional vem primeiro, mesmo tendo chegado depois:
  -- a vaga serve para ele com certeza.
  if fila[1] = '11100000-0000-0000-0000-000000000002' then
    perform t_ok('quem aceita qualquer profissional é chamado primeiro');
  else perform t_falha('ordem da fila errada: veio ' || coalesce(fila[1]::text,'nada'));
  end if;

  -- Depois dele, quem pediu a Ana especificamente.
  if fila[2] = '11100000-0000-0000-0000-000000000001' then
    perform t_ok('depois vem quem pediu justamente essa profissional');
  else perform t_falha('segunda posição errada');
  end if;

  -- A de manhã não entra numa vaga das 14h.
  if not ('11100000-0000-0000-0000-000000000003' = any(fila)) then
    perform t_ok('quem só pode de manhã não é chamado para vaga da tarde');
  else perform t_falha('CHAMOU quem só pode de manhã para uma vaga das 14h');
  end if;

  -- Mecha de 3h não cabe num buraco de 1h.
  if not ('11100000-0000-0000-0000-000000000004' = any(fila)) then
    perform t_ok('serviço que não cabe no buraco não é chamado');
  else perform t_falha('CHAMOU alguém cujo serviço não cabe na vaga');
  end if;

  if array_length(fila,1) = 2 then
    perform t_ok('a fila devolveu exatamente as 2 pessoas que servem');
  else perform t_falha('a fila devolveu ' || coalesce(array_length(fila,1),0) || ' em vez de 2');
  end if;
end $$;

-- Vaga de manhã: agora a terceira entra.
do $$
declare n int;
begin
  select count(*) into n from public.espera_para_vaga(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'bbbbbbbb-0000-0000-0000-000000000001',
    '2026-08-22 09:00-03', '2026-08-22 10:00-03')
   where id = '11100000-0000-0000-0000-000000000003';
  if n = 1 then perform t_ok('vaga de manhã chama quem pediu manhã');
  else perform t_falha('quem pediu manhã não foi chamado para vaga das 9h');
  end if;
end $$;

-- Quem já foi avisado sai da fila de chamada.
do $$
declare n int;
begin
  update public.lista_espera set status = 'avisado', avisado_em = now()
   where id = '11100000-0000-0000-0000-000000000002';
  select count(*) into n from public.espera_para_vaga(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'bbbbbbbb-0000-0000-0000-000000000001',
    '2026-08-22 14:00-03', '2026-08-22 15:00-03');
  if n = 1 then perform t_ok('quem já foi avisado sai da fila');
  else perform t_falha('avisado continua sendo chamado (' || n || ' na fila)');
  end if;
end $$;

do $$
begin
  if recusado($q$insert into public.lista_espera
                   (salao_id, cliente_id, de, ate)
                 values ('aaaaaaaa-0000-0000-0000-000000000001',
                         'dddddddd-0000-0000-0000-000000000001',
                         '2026-08-30', '2026-08-20')$q$)
  then perform t_ok('faixa de datas invertida é recusada');
  else perform t_falha('ACEITOU faixa terminando antes de começar');
  end if;
end $$;


\echo ''
\echo 'Atendimento para outra pessoa (o pai que leva o filho)'

do $$
declare a uuid;
begin
  insert into public.agendamentos (salao_id, cliente_id, profissional_id,
                                   inicio, fim, atendido_nome)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'dddddddd-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000002',
          '2026-08-25 10:00-03', '2026-08-25 10:30-03', 'João')
  returning id into a;

  if (select atendido_nome from public.agendamentos where id = a) = 'João'
  then perform t_ok('o filho é atendido sem virar cadastro próprio');
  else perform t_falha('não guardou quem seria atendido');
  end if;

  -- O responsável continua sendo o titular: é para o telefone dele que vai
  -- o lembrete, e é a ficha dele que guarda o histórico.
  if (select cliente_id from public.agendamentos where id = a)
     = 'dddddddd-0000-0000-0000-000000000001'
  then perform t_ok('o responsável segue como titular do agendamento');
  else perform t_falha('o vínculo com o responsável se perdeu');
  end if;
end $$;

-- O teste que impede o bug de fuso de voltar.
--
-- O PostgREST roda a sessão em UTC. Se a função usar o fuso da sessão em vez
-- do fuso do salão, "manhã" em São Paulo vira "tarde" para o banco. Aqui
-- forçamos UTC de propósito: a resposta tem que ser a mesma.
do $$
declare n_utc int; n_sp int;
begin
  set local timezone = 'UTC';
  select count(*) into n_utc from public.espera_para_vaga(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'bbbbbbbb-0000-0000-0000-000000000001',
    '2026-08-22 09:00-03', '2026-08-22 10:00-03')
   where id = '11100000-0000-0000-0000-000000000003';

  set local timezone = 'America/Sao_Paulo';
  select count(*) into n_sp from public.espera_para_vaga(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'bbbbbbbb-0000-0000-0000-000000000001',
    '2026-08-22 09:00-03', '2026-08-22 10:00-03')
   where id = '11100000-0000-0000-0000-000000000003';

  if n_utc = 1 and n_sp = 1 then
    perform t_ok('o turno sai do fuso do SALÃO, não do fuso da sessão');
  else perform t_falha(format(
    'a fila mudou com o fuso da sessão: UTC=%s, São Paulo=%s', n_utc, n_sp));
  end if;
end $$;


\echo ''
\echo 'Limite do plano — a trava que protege a receita'

-- Salão novo, sem assinatura nenhuma. O padrão TEM que ser o mais restrito.
insert into public.saloes (id, slug, nome, tipo) values
  ('aaaaaaaa-0000-0000-0000-000000000009', 'salao-novo', 'Salão Novo', 'barbearia');

do $$
begin
  if public.limite_profissionais('aaaaaaaa-0000-0000-0000-000000000009') = 1
  then perform t_ok('salão sem assinatura vale como 1 profissional, não ilimitado');
  else perform t_falha('salão sem assinatura ficou com limite '
    || public.limite_profissionais('aaaaaaaa-0000-0000-0000-000000000009'));
  end if;
end $$;

insert into public.assinaturas (salao_id, plano, status, trial_ate)
values ('aaaaaaaa-0000-0000-0000-000000000009', 'trial', 'trial',
        current_date + 7);

insert into public.profissionais (id, salao_id, nome) values
  ('bbbbbbbb-0000-0000-0000-000000000009',
   'aaaaaaaa-0000-0000-0000-000000000009', 'Único');
do $$ begin perform t_ok('o primeiro profissional entra no teste grátis'); end $$;

do $$
begin
  if recusado($q$insert into public.profissionais (salao_id, nome)
                 values ('aaaaaaaa-0000-0000-0000-000000000009', 'Segundo')$q$)
  then perform t_ok('o segundo é RECUSADO PELO BANCO, não pela tela');
  else perform t_falha('DEIXOU passar do limite do plano — receita vazando');
  end if;
end $$;

-- Desativar abre vaga sem apagar o histórico de quem saiu.
do $$
declare n int;
begin
  update public.profissionais set ativo = false
   where id = 'bbbbbbbb-0000-0000-0000-000000000009';
  insert into public.profissionais (salao_id, nome)
  values ('aaaaaaaa-0000-0000-0000-000000000009', 'Substituto');
  get diagnostics n = row_count;
  if n = 1 then perform t_ok('desativar alguém abre vaga sem perder o histórico');
  else perform t_falha('não consegui trocar de profissional dentro do limite');
  end if;
end $$;

-- Subir de plano libera de verdade.
update public.assinaturas set plano = 'duo', status = 'ativa', trial_ate = null
 where salao_id = 'aaaaaaaa-0000-0000-0000-000000000009';

do $$
declare n int;
begin
  insert into public.profissionais (salao_id, nome)
  values ('aaaaaaaa-0000-0000-0000-000000000009', 'Segundo de verdade');
  get diagnostics n = row_count;
  if n = 1 then perform t_ok('assinando o Duo, o segundo profissional entra');
  else perform t_falha('trocar de plano não liberou a vaga');
  end if;
end $$;

do $$
begin
  if recusado($q$insert into public.profissionais (salao_id, nome)
                 values ('aaaaaaaa-0000-0000-0000-000000000009', 'Terceiro')$q$)
  then perform t_ok('mas o terceiro esbarra no limite do Duo');
  else perform t_falha('o Duo aceitou 3 profissionais');
  end if;
end $$;

-- Teste vencido volta ao limite mínimo. Sem isso, quem nunca pagou continua
-- usando para sempre.
do $$
begin
  update public.assinaturas
     set plano = 'duo', status = 'trial', trial_ate = current_date - 1
   where salao_id = 'aaaaaaaa-0000-0000-0000-000000000009';
  if public.limite_profissionais('aaaaaaaa-0000-0000-0000-000000000009') = 1
  then perform t_ok('teste vencido volta a valer 1 profissional');
  else perform t_falha('teste vencido continuou com o limite do plano pago');
  end if;
end $$;

do $$
begin
  update public.assinaturas set status = 'cancelada'
   where salao_id = 'aaaaaaaa-0000-0000-0000-000000000009';
  if public.limite_profissionais('aaaaaaaa-0000-0000-0000-000000000009') = 1
  then perform t_ok('assinatura cancelada também volta ao mínimo');
  else perform t_falha('cancelada seguiu liberando o plano inteiro');
  end if;
end $$;

\echo ''
\echo 'Bloqueio e atendimento não convivem'

-- O almoço é um bloqueio, noutra tabela. A trava `agenda_sem_choque` não
-- alcança ele — quem alcança é o gatilho. Sem esse par de testes, a semente
-- da demonstração voltaria a marcar mecha de três horas por cima do almoço.
insert into public.bloqueios (salao_id, profissional_id, inicio, fim, motivo)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'bbbbbbbb-0000-0000-0000-000000000001',
        '2026-09-10 12:00-03', '2026-09-10 13:00-03', 'Almoço');

do $$
begin
  if recusado($q$insert into public.agendamentos
                   (salao_id, cliente_id, profissional_id, inicio, fim)
                 values ('aaaaaaaa-0000-0000-0000-000000000001',
                         'dddddddd-0000-0000-0000-000000000001',
                         'bbbbbbbb-0000-0000-0000-000000000001',
                         '2026-09-10 11:00-03', '2026-09-10 12:30-03')$q$)
  then perform t_ok('atendimento que invade o almoço é recusado');
  else perform t_falha('marcou por cima do almoço');
  end if;
end $$;

do $$
declare n int;
begin
  insert into public.agendamentos
    (salao_id, cliente_id, profissional_id, inicio, fim)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'dddddddd-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          '2026-09-10 11:00-03', '2026-09-10 12:00-03');
  get diagnostics n = row_count;
  if n = 1 then perform t_ok('encostar no almoço sem invadir continua valendo');
  else perform t_falha('11:00-12:00 foi recusado sem encostar no bloqueio');
  end if;
end $$;

-- E o contrário: bloquear em cima de quem já está marcado. Se só um lado
-- fosse conferido, bastava inverter a ordem para furar a regra.
do $$
begin
  if recusado($q$insert into public.bloqueios
                   (salao_id, profissional_id, inicio, fim, motivo)
                 values ('aaaaaaaa-0000-0000-0000-000000000001',
                         'bbbbbbbb-0000-0000-0000-000000000001',
                         '2026-09-10 11:30-03', '2026-09-10 14:00-03', 'Médico')$q$)
  then perform t_ok('bloquear em cima de atendimento marcado é recusado');
  else perform t_falha('o bloqueio passou por cima de um cliente marcado');
  end if;
end $$;

-- Fechar o salão inteiro (profissional_id nulo) vale para todo mundo.
do $$
begin
  if recusado($q$insert into public.bloqueios (salao_id, inicio, fim, motivo)
                 values ('aaaaaaaa-0000-0000-0000-000000000001',
                         '2026-09-10 11:30-03', '2026-09-10 12:00-03', 'Feriado')$q$)
  then perform t_ok('feriado do salão também esbarra em quem já está marcado');
  else perform t_falha('o feriado ignorou os atendimentos do dia');
  end if;
end $$;

do $$
begin
  insert into public.bloqueios (salao_id, inicio, fim, motivo)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          '2026-09-11 08:00-03', '2026-09-11 23:00-03', 'Feriado');
  perform t_ok('feriado em dia vazio entra sem reclamar');
end $$;

-- Cancelado libera: o horário volta a ficar livre para bloquear.
do $$
begin
  update public.agendamentos set status = 'cancelado'
   where profissional_id = 'bbbbbbbb-0000-0000-0000-000000000001'
     and inicio = '2026-09-10 11:00-03';
  insert into public.bloqueios (salao_id, profissional_id, inicio, fim, motivo)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'bbbbbbbb-0000-0000-0000-000000000001',
          '2026-09-10 11:00-03', '2026-09-10 12:00-03', 'Médico');
  perform t_ok('atendimento cancelado libera o horário para bloqueio');
end $$;
