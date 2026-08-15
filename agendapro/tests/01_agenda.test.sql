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
