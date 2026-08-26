-- ===========================================================================
-- Deixa o banco do jeito que a instalação de verdade está HOJE, antes do
-- remendo. Carregado por tests/rodar.sh, nunca sozinho.
--
-- O 00_tudo.sql já traz a correção do telefone, então um banco recém-criado
-- nasce limpo — e um teste que rodasse só nele aprovaria um remendo vazio.
-- Aqui a correção é DESFEITA de propósito e o cadastro é sujado com os dois
-- estragos medidos, para o remendo ter o que consertar.
-- ===========================================================================

\set ON_ERROR_STOP on

-- A instalação antiga não tinha a trava. Sem tirar, nada sujo entra.
alter table public.clientes drop constraint if exists cli_tel_so_digitos;

insert into public.saloes (id, slug, nome, tipo) values
  ('aaaaaaaa-9999-0000-0000-000000000001', 'salao-sujo', 'Salão Sujo', 'salao');

-- `criado_em` explícito: a migração desempata pela ordem de cadastro, e sem
-- data fixa as quatro fichas nascem no mesmo instante e o desempate vira
-- sorteio — o teste passaria ou falharia conforme o dia.
insert into public.clientes (id, salao_id, nome, telefone, criado_em) values
  -- 1) Passou sem deixar número. O painel gravou string vazia.
  ('dddddddd-9999-0000-0000-00000000000a',
   'aaaaaaaa-9999-0000-0000-000000000001', 'Sem número', '',
   '2026-01-01 10:00-03'),
  -- 2) Cadastrada no balcão, com máscara. Ninguém mais tem esse número.
  ('dddddddd-9999-0000-0000-00000000000b',
   'aaaaaaaa-9999-0000-0000-000000000001', 'Com máscara', '(11) 98888-7777',
   '2026-01-01 11:00-03'),
  -- 3 e 4) A MESMA pessoa em duas fichas: uma veio pelo link da cliente (já
  -- em dígitos), outra do balcão (com máscara). Limpar a 4 criaria dois
  -- telefones iguais no mesmo salão, e `ux_cli_tel` derrubaria a migração.
  ('dddddddd-9999-0000-0000-00000000000c',
   'aaaaaaaa-9999-0000-0000-000000000001', 'Dividida (link)', '51999990000',
   '2026-01-01 12:00-03'),
  ('dddddddd-9999-0000-0000-00000000000d',
   'aaaaaaaa-9999-0000-0000-000000000001', 'Dividida (balcão)', '(51) 99999-0000',
   '2026-01-01 13:00-03');
