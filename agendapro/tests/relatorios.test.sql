-- ===========================================================================
-- AgendaPro — os relatórios batem com o que está gravado
--
-- Relatório errado é pior que relatório nenhum: o dono paga comissão a mais,
-- ou a menos, e descobre pela funcionária. Então aqui os números NÃO são
-- conferidos contra outra consulta parecida — são conferidos contra valores
-- que dá para somar de cabeça, escritos no próprio teste.
--
-- As perguntas que este arquivo responde:
--   1. O que conta como faturamento? (fechada, e pela data em que FECHOU)
--   2. A comissão sai por PESSOA, do item, e não da comanda?
--   3. Comanda aberta e cancelada ficam de fora?
--   4. O salão A lê o mês do salão B trocando o uuid?
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-00000000000a', 'donaR@teste.com'),
  ('f0000000-0000-0000-0000-00000000000b', 'donoS@teste.com');
insert into public.perfis (id, nome, telefone) values
  ('f0000000-0000-0000-0000-00000000000a', 'Dona R', '+5511900000201'),
  ('f0000000-0000-0000-0000-00000000000b', 'Dono S', '+5511900000202')
on conflict (id) do nothing;

insert into public.saloes (id, slug, nome, tipo, fuso) values
  ('f0000000-1111-0000-0000-00000000000a', 'salao-r', 'Salão R', 'salao',
   'America/Sao_Paulo'),
  ('f0000000-1111-0000-0000-00000000000b', 'salao-s', 'Salão S', 'salao',
   'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status) values
  ('f0000000-1111-0000-0000-00000000000a', 'time', 'ativa'),
  ('f0000000-1111-0000-0000-00000000000b', 'time', 'ativa');
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('f0000000-0000-0000-0000-00000000000a',
   'f0000000-1111-0000-0000-00000000000a', 'dono', 'ativo'),
  ('f0000000-0000-0000-0000-00000000000b',
   'f0000000-1111-0000-0000-00000000000b', 'dono', 'ativo');

insert into public.profissionais (id, salao_id, nome, comissao_pct) values
  ('f0000000-2222-0000-0000-00000000000a',
   'f0000000-1111-0000-0000-00000000000a', 'Ana', 40),
  ('f0000000-2222-0000-0000-00000000000b',
   'f0000000-1111-0000-0000-00000000000a', 'Bia', 50);

insert into public.clientes (id, salao_id, nome, telefone) values
  ('f0000000-3333-0000-0000-00000000000a',
   'f0000000-1111-0000-0000-00000000000a', 'Cliente Velha', '11911110001'),
  ('f0000000-3333-0000-0000-00000000000b',
   'f0000000-1111-0000-0000-00000000000a', 'Cliente Nova',  '11911110002');

/* ── O CENÁRIO, com contas que dá para fazer de cabeça ─────────────────────

   Março de 2026, no fuso do salão.

   FECHADA em 10/03 · Ana  · corte 100,00 · 40% → comissão 40,00
   FECHADA em 20/03 · Bia  · mecha 200,00 · 50% → comissão 100,00
                             desconto de 20,00 na comanda
   FECHADA em 05/02 (mês ANTERIOR) · Ana · corte 80,00
   ABERTA   em 15/03 · não conta: é atendimento, não é dinheiro
   CANCELADA em 16/03 · não conta

   Faturamento de março = 100 + (200 − 20) = 280,00
   Comissão: Ana 40,00 · Bia 100,00
   Faturamento de fevereiro (o período anterior) = 80,00
   ───────────────────────────────────────────────────────────────────────── */

-- Fevereiro
insert into public.comandas (id, salao_id, cliente_id, status, desconto,
                             aberta_em, fechada_em) values
  ('f0000000-4444-0000-0000-000000000001',
   'f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'fechada', 0, '2026-02-05 10:00-03', '2026-02-05 11:00-03');
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct) values
  ('f0000000-4444-0000-0000-000000000001', 'servico', 'Corte', 1, 80.00,
   'f0000000-2222-0000-0000-00000000000a', 40);

-- Março
insert into public.comandas (id, salao_id, cliente_id, status, desconto,
                             aberta_em, fechada_em) values
  ('f0000000-4444-0000-0000-000000000002',
   'f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'fechada', 0, '2026-03-10 09:00-03', '2026-03-10 10:00-03'),
  ('f0000000-4444-0000-0000-000000000003',
   'f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000b',
   'fechada', 20.00, '2026-03-20 09:00-03', '2026-03-20 12:00-03'),
  ('f0000000-4444-0000-0000-000000000004',
   'f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'aberta', 0, '2026-03-15 09:00-03', null),
  ('f0000000-4444-0000-0000-000000000005',
   'f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'cancelada', 0, '2026-03-16 09:00-03', '2026-03-16 10:00-03');

insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct) values
  ('f0000000-4444-0000-0000-000000000002', 'servico', 'Corte', 1, 100.00,
   'f0000000-2222-0000-0000-00000000000a', 40),
  ('f0000000-4444-0000-0000-000000000003', 'servico', 'Mecha', 1, 200.00,
   'f0000000-2222-0000-0000-00000000000b', 50),
  -- Nas que não contam, valores grandes de propósito: se entrarem, o número
  -- salta e o teste não passa por pouco.
  ('f0000000-4444-0000-0000-000000000004', 'servico', 'Nao conta', 1, 9999.00,
   'f0000000-2222-0000-0000-00000000000a', 40),
  ('f0000000-4444-0000-0000-000000000005', 'servico', 'Nao conta', 1, 9999.00,
   'f0000000-2222-0000-0000-00000000000a', 40);

insert into public.pagamentos (comanda_id, forma, valor, taxa) values
  ('f0000000-4444-0000-0000-000000000002', 'pix',     100.00, 0),
  ('f0000000-4444-0000-0000-000000000003', 'credito', 180.00, 5.40);

\echo ''
\echo 'O fechamento de março'

select set_config('request.jwt.claim.sub',
                  'f0000000-0000-0000-0000-00000000000a', false);
select public.relatorio('f0000000-1111-0000-0000-00000000000a',
                        '2026-03-01', '2026-03-31') as r \gset

select t_texto('faturou 280,00 — o corte mais a mecha, menos o desconto',
  (:'r'::jsonb->>'faturamento'), '280.00');
select t_igual('em 2 atendimentos',
  (:'r'::jsonb->>'atendimentos')::bigint, 2);
select t_texto('com 20,00 de desconto no período',
  (:'r'::jsonb->>'descontos'), '20.00');

-- A comanda ABERTA tem item de 9.999: se ela entrasse, o número saltaria.
select t_falso('comanda aberta e cancelada ficam de fora',
  (:'r'::jsonb->>'faturamento')::numeric > 300);

\echo ''
\echo 'A comissão, por pessoa'

select t_igual('duas pessoas na lista',
  jsonb_array_length(:'r'::jsonb->'comissoes'), 2);

select t_texto('a Bia é a primeira, porque comissão vem em ordem de valor',
  (:'r'::jsonb->'comissoes'->0->>'nome'), 'Bia');
select t_texto('e ela tem 100,00 a receber (50% de 200)',
  (:'r'::jsonb->'comissoes'->0->>'comissao'), '100.00');
select t_texto('a Ana tem 40,00 (40% de 100)',
  (:'r'::jsonb->'comissoes'->1->>'comissao'), '40.00');

-- A comissão sai do ITEM: o desconto da comanda não a reduz. É de propósito e
-- é a prática do ramo — o desconto é do salão, não da profissional.
select t_texto('e a comissão da Bia sai do item, não do total com desconto',
  (:'r'::jsonb->'comissoes'->0->>'vendido'), '200.00');

\echo ''
\echo 'Como entrou, e quanto a maquininha levou'

select t_igual('duas formas de pagamento',
  jsonb_array_length(:'r'::jsonb->'formas'), 2);
select t_texto('o crédito foi o maior',
  (:'r'::jsonb->'formas'->0->>'forma'), 'credito');
select t_texto('e a taxa dele aparece — o salão recebe menos do que a cliente pagou',
  (:'r'::jsonb->'formas'->0->>'taxa'), '5.40');

\echo ''
\echo 'A comparação com o período anterior'

-- 01/03 a 31/03 são 31 dias; o anterior são os 31 dias imediatamente antes,
-- que pegam a comanda de 05/02.
select t_texto('o período anterior faturou 80,00',
  (:'r'::jsonb->>'faturamentoAntes'), '80.00');
select t_igual('e o período tem 31 dias', (:'r'::jsonb->>'dias')::bigint, 31);

\echo ''
\echo 'Quem voltou e quem é nova'

select t_igual('duas clientes atendidas em março',
  (:'r'::jsonb->'clientes'->>'atendidas')::bigint, 2);
-- A Velha já tinha comanda fechada em fevereiro; a Nova, não.
select t_igual('e uma delas é nova na casa',
  (:'r'::jsonb->'clientes'->>'novas')::bigint, 1);

\echo ''
\echo 'A data que conta é a do FECHAMENTO, não a da abertura'

/* A comanda abre quando a cliente senta e fecha quando ela paga. Abrindo dia
   31 e fechando dia 1º, o dinheiro entrou no mês NOVO. Usar `aberta_em`
   jogaria a receita para o mês errado, e o dono só descobriria fechando o
   caixa e não batendo. */
insert into public.comandas (id, salao_id, cliente_id, status, aberta_em, fechada_em)
values ('f0000000-4444-0000-0000-000000000006',
        'f0000000-1111-0000-0000-00000000000a',
        'f0000000-3333-0000-0000-00000000000a', 'fechada',
        '2026-03-31 22:00-03', '2026-04-01 01:00-03');
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct)
values ('f0000000-4444-0000-0000-000000000006', 'servico', 'Virada', 1, 50.00,
        'f0000000-2222-0000-0000-00000000000a', 40);

select public.relatorio('f0000000-1111-0000-0000-00000000000a',
                        '2026-03-01', '2026-03-31') as r2 \gset
select t_texto('a comanda que virou a noite NÃO entra em março',
  (:'r2'::jsonb->>'faturamento'), '280.00');

select public.relatorio('f0000000-1111-0000-0000-00000000000a',
                        '2026-04-01', '2026-04-30') as r3 \gset
select t_texto('ela entra em abril, que foi quando o dinheiro entrou',
  (:'r3'::jsonb->>'faturamento'), '50.00');

\echo ''
\echo 'A agenda: faltas e o que ficou na mesa'

insert into public.agendamentos (salao_id, cliente_id, profissional_id,
                                 inicio, fim, status, valor_previsto) values
  ('f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'f0000000-2222-0000-0000-00000000000a',
   '2026-03-05 09:00-03', '2026-03-05 10:00-03', 'concluido', 100),
  ('f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'f0000000-2222-0000-0000-00000000000a',
   '2026-03-06 09:00-03', '2026-03-06 10:00-03', 'faltou', 120),
  ('f0000000-1111-0000-0000-00000000000a', 'f0000000-3333-0000-0000-00000000000a',
   'f0000000-2222-0000-0000-00000000000a',
   '2026-03-07 09:00-03', '2026-03-07 10:00-03', 'cancelado', 80);

select public.relatorio('f0000000-1111-0000-0000-00000000000a',
                        '2026-03-01', '2026-03-31') as r4 \gset
select t_igual('uma falta em março',
  (:'r4'::jsonb->'agenda'->>'faltas')::bigint, 1);
select t_igual('um cancelamento',
  (:'r4'::jsonb->'agenda'->>'cancelados')::bigint, 1);
select t_texto('e 200,00 ficaram na mesa entre falta e cancelamento',
  (:'r4'::jsonb->'agenda'->>'perdido'), '200.00');

\echo ''
\echo 'O SALÃO S NÃO LÊ O MÊS DO SALÃO R'

select set_config('request.jwt.claim.sub',
                  'f0000000-0000-0000-0000-00000000000b', false);
set role authenticated;
select t_texto('rodando como authenticated', current_user, 'authenticated');

select t_verdade('trocar o uuid na chamada é RECUSADO',
  recusado($$select public.relatorio(
    'f0000000-1111-0000-0000-00000000000a', '2026-03-01', '2026-03-31')$$));

-- E o próprio salão dele, vazio, não estoura.
select t_texto('o relatório do salão dele volta zerado, sem erro',
  (public.relatorio('f0000000-1111-0000-0000-00000000000b',
                    '2026-03-01', '2026-03-31')->>'faturamento'), '0');

reset role;
select set_config('request.jwt.claim.sub', '', false);
