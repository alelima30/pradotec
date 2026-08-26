-- ===========================================================================
-- AgendaPro — quando o telefone digitado é de outra pessoa
--
-- ── O QUE ESTE ARQUIVO GUARDA ──────────────────────────────────────────────
-- A ficha é reencontrada pelo TELEFONE, e não existe verificação por SMS.
-- Então nada impede alguém de marcar com o número da mãe, do marido, ou com
-- um dígito trocado. O horário cai na ficha de outra pessoa.
--
-- Isso NÃO se resolve sem verificar o número de verdade, e é honesto dizer
-- isso em vez de fingir. O que dá para garantir são os dois estragos que
-- passavam em silêncio:
--
--   1. A CONTA NÃO PODE ADOTAR A FICHA ALHEIA. `ficha_do_cliente` amarrava
--      `perfil_id` a qualquer ficha achada pelo telefone. Bastava digitar o
--      número de outra pessoa uma vez e, dali em diante, TODA marcação
--      daquela conta caía no histórico dela — para sempre, porque a busca
--      seguinte acha pelo perfil antes de olhar o telefone.
--
--   2. O SALÃO TEM QUE SABER QUEM VEM. Se o nome informado não é o da ficha,
--      ele fica registrado em `atendido_nome`. O painel mostra como
--      "Quem vem". Melhor um nome a mais na tela do que o salão ligar para
--      a mãe perguntando de um horário que ela não marcou.
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('cccccccc-1111-1111-1111-111111111111', 'dona@salao.com'),
  ('cccccccc-2222-2222-2222-222222222222', 'filha@teste.com');

insert into public.saloes (id, slug, nome, tipo) values
  ('cccccccc-0000-0000-0000-000000000001', 'salao-do-tel', 'Salão do Telefone', 'salao');
insert into public.assinaturas (salao_id, plano, status) values
  ('cccccccc-0000-0000-0000-000000000001', 'time', 'ativa');

insert into public.perfis (id, nome, telefone) values
  ('cccccccc-1111-1111-1111-111111111111', 'Dona',  '+5511900000001'),
  ('cccccccc-2222-2222-2222-222222222222', 'Filha', '+5511900000002')
on conflict (id) do update set nome = excluded.nome;

insert into public.profissionais (id, salao_id, perfil_id, nome) values
  ('cccccccc-3333-0000-0000-000000000001',
   'cccccccc-0000-0000-0000-000000000001',
   'cccccccc-1111-1111-1111-111111111111', 'Dona');

-- A MÃE já é cliente da casa, cadastrada no balcão.
insert into public.clientes (id, salao_id, nome, telefone) values
  ('cccccccc-4444-0000-0000-000000000001',
   'cccccccc-0000-0000-0000-000000000001', 'Maria Mãe', '11988887777');

\echo ''
\echo 'A filha marca usando o telefone da mãe'

/* Quem "loga" no teste é `request.jwt.claim.sub` — o nome que o
   `auth.uid()` do stub lê. Com `set local` fora de transação, ou com o nome
   errado, `auth.uid()` volta NULL e o teste inteiro passa sem testar nada:
   sem perfil não há o que amarrar. Por isso a linha seguinte confere que o
   login pegou, antes de qualquer outra coisa. */
select set_config('request.jwt.claim.sub',
                  'cccccccc-2222-2222-2222-222222222222', false);
select t_verdade('o teste está logado como a filha',
  auth.uid() = 'cccccccc-2222-2222-2222-222222222222');

select public.ficha_do_cliente(
  'cccccccc-0000-0000-0000-000000000001', 'Ana Filha', '11988887777')
  as ficha \gset

select t_texto('caiu na ficha da mãe, que é a dona do número',
  (select nome from public.clientes where id = :'ficha'),
  'Maria Mãe');

-- Este é o ponto: a conta da filha NÃO pode virar dona da ficha da mãe.
select t_verdade('mas a conta da filha não adotou a ficha da mãe',
  (select perfil_id from public.clientes where id = :'ficha') is null);

select t_texto('e o nome da ficha continua o da mãe',
  (select nome from public.clientes
    where id = 'cccccccc-4444-0000-0000-000000000001'),
  'Maria Mãe');

\echo ''
\echo 'A própria mãe, criando conta depois, continua sendo amarrada'

select set_config('request.jwt.claim.sub',
                  'cccccccc-1111-1111-1111-111111111111', false);

select public.ficha_do_cliente(
  'cccccccc-0000-0000-0000-000000000001', 'Maria Mãe', '11988887777')
  as ficha2 \gset

select t_verdade('nome batendo, a conta vira dona da própria ficha',
  (select perfil_id from public.clientes where id = :'ficha2')
    = 'cccccccc-1111-1111-1111-111111111111');

select t_texto('e é a MESMA ficha, não uma segunda',
  :'ficha2', 'cccccccc-4444-0000-0000-000000000001');

\echo ''
\echo 'O apelido continua sendo a mesma pessoa'

-- Medido de verdade: a mesma mulher marcou sem login como "Juliana Ferreira"
-- e depois, com conta, como "Ju Barbosa". Igualdade exata a deixaria
-- desamarrada da própria ficha para sempre.
select t_verdade('"Ju" e "Juliana" são a mesma pessoa',
  public.mesmo_primeiro_nome('Juliana Ferreira', 'Ju Barbosa'));
select t_falso('"Ana" e "Maria" não são',
  public.mesmo_primeiro_nome('Maria Mãe', 'Ana Filha'));
select t_falso('e uma inicial sozinha não casa com ninguém',
  public.mesmo_primeiro_nome('Maria Mãe', 'M'));

select set_config('request.jwt.claim.sub', '', false);
