-- ===========================================================================
-- AgendaPro — a cobrança não dá o produto de graça
--
-- Módulo de pagamento é o único do sistema em que um defeito não custa
-- suporte: custa dinheiro, direto, e sem ninguém perceber por meses. As
-- perguntas deste arquivo são as quatro que decidem isso:
--
--   1. Dá para escolher quanto pagar?
--   2. O aviso de pagamento repetido paga o mês mais de uma vez?
--   3. O salão A assina no nome do salão B — ou pior, no próprio, de graça?
--   4. Quem está logado alcança as funções que movem a assinatura?
--
-- ⚠ E uma observação sobre como este arquivo é escrito. `abrir_cobranca()` e
-- `registrar_pagamento()` são `security definer` e NEGADAS a `authenticated`
-- de propósito — quem as chama é a função de borda, com a chave de serviço.
-- Então os testes de conta rodam como `postgres` (que é o que a borda é, em
-- poder) e os testes de PERMISSÃO trocam para `authenticated` de verdade,
-- com `set role`. Misturar os dois faria a suíte aprovar uma função aberta.
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('c0000000-0000-0000-0000-00000000000a', 'donaA@teste.com'),
  ('c0000000-0000-0000-0000-00000000000b', 'donoB@teste.com');
insert into public.perfis (id, nome, telefone) values
  ('c0000000-0000-0000-0000-00000000000a', 'Dona A', '+5511900000301'),
  ('c0000000-0000-0000-0000-00000000000b', 'Dono B', '+5511900000302')
on conflict (id) do nothing;

insert into public.saloes (id, slug, nome, tipo, fuso) values
  ('c0000000-1111-0000-0000-00000000000a', 'salao-a', 'Salão A', 'salao',
   'America/Sao_Paulo'),
  ('c0000000-1111-0000-0000-00000000000b', 'salao-b', 'Salão B', 'salao',
   'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status, trial_ate) values
  ('c0000000-1111-0000-0000-00000000000a', 'trial', 'trial', current_date + 3),
  ('c0000000-1111-0000-0000-00000000000b', 'trial', 'trial', current_date + 3);
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('c0000000-0000-0000-0000-00000000000a',
   'c0000000-1111-0000-0000-00000000000a', 'dono', 'ativo'),
  ('c0000000-0000-0000-0000-00000000000b',
   'c0000000-1111-0000-0000-00000000000b', 'dono', 'ativo');

\echo ''
\echo 'O PREÇO É LIDO NO SERVIDOR, NÃO ESCOLHIDO POR QUEM PEDE'

-- `abrir_cobranca` nem aceita valor: o preço sai de `planos`. Este teste
-- confere que ele é o da tabela, e não outro qualquer.
select preco_mes as preco_salao from public.planos where codigo = 'salao' \gset

select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000a',
        'salao', 'pix', 'c0000000-0000-0000-0000-00000000000a')).id as cob1 \gset

select t_texto('a cobrança nasce com o preço da tabela de planos',
  (select valor::text from public.cobrancas where id = :'cob1'),
  (select preco_mes::text from public.planos where codigo = 'salao'));
select t_texto('e pendente', (select status from public.cobrancas where id = :'cob1'),
  'pendente');

-- Plano que não existe, e plano que não é pago, não viram cobrança.
select t_verdade('plano inventado é recusado',
  recusado($$select public.abrir_cobranca(
    'c0000000-1111-0000-0000-00000000000a', 'plano_de_ouro', 'pix',
    'c0000000-0000-0000-0000-00000000000a')$$));
select t_verdade('plano Grátis não vira cobrança de R$ 0,00',
  recusado($$select public.abrir_cobranca(
    'c0000000-1111-0000-0000-00000000000a', 'gratuito', 'pix',
    'c0000000-0000-0000-0000-00000000000a')$$));
select t_verdade('forma de pagamento inventada é recusada',
  recusado($$select public.abrir_cobranca(
    'c0000000-1111-0000-0000-00000000000a', 'salao', 'cripto',
    'c0000000-0000-0000-0000-00000000000a')$$));

\echo ''
\echo 'UM PIX POR VEZ NA MÃO DO DONO'

select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000a',
        'salao', 'pix', 'c0000000-0000-0000-0000-00000000000a')).id as cob2 \gset
select t_texto('clicar de novo devolve A MESMA cobrança, não abre outra',
  :'cob2', :'cob1');
select t_igual('e continua havendo uma pendente só',
  (select count(*) from public.cobrancas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'
      and status = 'pendente'), 1);

-- Trocar de plano precisa de cobrança nova — e a antiga sai do caminho.
select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000a',
        'individual', 'pix', 'c0000000-0000-0000-0000-00000000000a')).id as cob3 \gset
select t_verdade('trocar de plano abre uma cobrança nova', :'cob3' <> :'cob1');
select t_texto('e a anterior é cancelada',
  (select status from public.cobrancas where id = :'cob1'), 'cancelada');
select t_igual('sem deixar duas pendentes',
  (select count(*) from public.cobrancas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'
      and status = 'pendente'), 1);

\echo ''
\echo 'O PAGAMENTO CONFIRMADO — E O AVISO QUE CHEGA TRÊS VEZES'

select public.anotar_cobranca(:'cob3', 'MP-111', 'pending',
  '00020126580014BR.GOV.BCB.PIX', 'iVBORw0KG', null, null);

select t_texto('antes de pagar, a assinatura ainda é o teste',
  (select status from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'), 'trial');

select public.registrar_pagamento('MP-111',
  (select valor from public.cobrancas where id = :'cob3'), 'approved');

select t_texto('paga', (select status from public.cobrancas where id = :'cob3'), 'paga');
select t_texto('a assinatura virou ativa',
  (select status from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'), 'ativa');
select t_texto('no plano que foi pago',
  (select plano from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'), 'individual');
select t_texto('e vence daqui a um mês',
  (select vence_em::text from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'),
  (current_date + interval '1 month')::date::text);
select t_texto('o teste grátis foi encerrado junto',
  (select trial_ate::text from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'), null);

/* ⚠ AQUI ESTÁ O DEFEITO QUE DÁ MESES DE GRAÇA.
   O Mercado Pago reenvia o mesmo aviso até receber 200, e reenvia de novo a
   cada mudança do pagamento. Se cada chegada somasse um mês, quem pagou uma
   vez ficaria com meio ano. */
select vence_em as venc_apos_1 from public.assinaturas
 where salao_id = 'c0000000-1111-0000-0000-00000000000a' \gset

select public.registrar_pagamento('MP-111',
  (select valor from public.cobrancas where id = :'cob3'), 'approved');
select public.registrar_pagamento('MP-111',
  (select valor from public.cobrancas where id = :'cob3'), 'approved');

select t_texto('o mesmo aviso três vezes NÃO soma três meses',
  (select vence_em::text from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'),
  :'venc_apos_1'::text);

\echo ''
\echo 'O QUE NÃO PODE VIRAR ASSINATURA'

-- Valor divergente: alguém pagou 47 e o id aponta para a cobrança de 297.
select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000b',
        'salao', 'pix', 'c0000000-0000-0000-0000-00000000000b')).id as cob_b \gset
select public.anotar_cobranca(:'cob_b', 'MP-222', 'pending', 'pix', null, null, null);

select t_falso('pagar menos que a cobrança NÃO ativa o plano',
  (public.registrar_pagamento('MP-222', 1.00, 'approved') ->> 'ok')::boolean);
select t_texto('e a assinatura do B continua no teste',
  (select status from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000b'), 'trial');
select t_texto('a cobrança fica marcada para o suporte achar',
  (select left(mp_status, 16) from public.cobrancas where id = :'cob_b'),
  'valor_divergente');

-- Status que não é 'approved' (pendente, recusado, estornado).
select t_texto('aviso de pagamento recusado não ativa nada',
  (public.registrar_pagamento('MP-222',
     (select valor from public.cobrancas where id = :'cob_b'), 'rejected') ->> 'motivo'),
  'nao_aprovado');
select t_texto('a assinatura do B segue no teste',
  (select status from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000b'), 'trial');

-- Aviso de um pagamento que não é deste sistema: não estoura, só ignora.
select t_texto('aviso de pagamento desconhecido é ignorado sem erro',
  (public.registrar_pagamento('MP-DE-OUTRO-LUGAR', 10, 'approved') ->> 'motivo'),
  'cobranca_desconhecida');

\echo ''
\echo 'QUEM PAGA ANTES NÃO PERDE OS DIAS QUE COMPROU'

-- O salão A já está ativo até daqui a um mês. Pagando de novo agora, o mês
-- novo tem que SOMAR ao que sobrou, não recomeçar de hoje.
select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000a',
        'individual', 'pix', 'c0000000-0000-0000-0000-00000000000a')).id as cob4 \gset
select public.anotar_cobranca(:'cob4', 'MP-333', 'pending', 'pix', null, null, null);
select public.registrar_pagamento('MP-333',
  (select valor from public.cobrancas where id = :'cob4'), 'approved');

select t_texto('pagar adiantado empurra o vencimento a partir do que já tinha',
  (select vence_em::text from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'),
  (:'venc_apos_1'::date + interval '1 month')::date::text);

-- E quem paga atrasado começa de hoje: retroativo faria vencer de novo na
-- semana seguinte.
update public.assinaturas set vence_em = current_date - 40
 where salao_id = 'c0000000-1111-0000-0000-00000000000b';
update public.assinaturas set status = 'ativa'
 where salao_id = 'c0000000-1111-0000-0000-00000000000b';
select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000b',
        'individual', 'boleto', 'c0000000-0000-0000-0000-00000000000b')).id as cob5 \gset
select public.anotar_cobranca(:'cob5', 'MP-444', 'pending', null, null,
  'https://boleto', '34191');
select public.registrar_pagamento('MP-444',
  (select valor from public.cobrancas where id = :'cob5'), 'approved');
select t_texto('quem estava vencido recomeça de hoje, não retroativo',
  (select vence_em::text from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000b'),
  (current_date + interval '1 month')::date::text);

\echo ''
\echo 'A COBRANÇA VENCIDA NÃO TRAVA O DONO PARA SEMPRE'

select (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000b',
        'salao', 'pix', 'c0000000-0000-0000-0000-00000000000b')).id as cob6 \gset
update public.cobrancas set vence_em = now() - interval '1 hour' where id = :'cob6';
select t_igual('a faxina do dia vence a cobrança velha',
  public.vencer_cobrancas()::bigint, 1);
select t_texto('que sai do caminho', (select status from public.cobrancas
  where id = :'cob6'), 'vencida');
-- E com ela fora, o dono consegue abrir outra: era o travamento que o índice
-- parcial causaria sozinho.
select t_verdade('e o dono consegue abrir uma nova',
  (public.abrir_cobranca('c0000000-1111-0000-0000-00000000000b',
    'salao', 'pix', 'c0000000-0000-0000-0000-00000000000b')).id is not null);

\echo ''
\echo 'A LISTA DE QUEM PRECISA RECEBER O PIX DO MÊS'

update public.assinaturas set vence_em = current_date + 2, plano = 'salao'
 where salao_id = 'c0000000-1111-0000-0000-00000000000a';
-- O A tem cobrança pendente? Se tiver, não deve aparecer: já mandamos.
update public.cobrancas set status = 'cancelada'
 where salao_id = 'c0000000-1111-0000-0000-00000000000a' and status = 'pendente';

select t_verdade('quem vence em 2 dias entra na lista',
  exists (select 1 from public.assinaturas_a_vencer(5)
           where salao_id = 'c0000000-1111-0000-0000-00000000000a'));

select public.abrir_cobranca('c0000000-1111-0000-0000-00000000000a', 'salao', 'pix',
       'c0000000-0000-0000-0000-00000000000a');
select t_falso('e sai dela assim que a cobrança do mês é aberta',
  exists (select 1 from public.assinaturas_a_vencer(5)
           where salao_id = 'c0000000-1111-0000-0000-00000000000a'));

\echo ''
\echo 'O NAVEGADOR NÃO ALCANÇA NADA DISSO'

select set_config('request.jwt.claim.sub',
                  'c0000000-0000-0000-0000-00000000000a', false);
set role authenticated;
select t_texto('rodando como authenticated', current_user, 'authenticated');

/* ⚠ A LINHA QUE MAIS IMPORTA DO ARQUIVO.
   Com `registrar_pagamento` alcançável, qualquer dono de salão assina o plano
   de R$ 297 de graça — basta chamar a função com o mp_id da própria cobrança
   e o valor dela. Não é hipótese: é uma linha no console do navegador. */
select t_verdade('quem fez login NÃO registra pagamento',
  recusado($$select public.registrar_pagamento('MP-111', 47, 'approved')$$));
select t_verdade('NÃO abre cobrança direto no banco',
  recusado($$select public.abrir_cobranca(
    'c0000000-1111-0000-0000-00000000000a', 'salao', 'pix',
    'c0000000-0000-0000-0000-00000000000a')$$));
select t_verdade('NÃO anota instrumento de pagamento',
  recusado($$select public.anotar_cobranca(
    '00000000-0000-0000-0000-000000000000', 'x', 'approved')$$));
select t_verdade('NÃO roda a faxina', recusado($$select public.vencer_cobrancas()$$));
select t_verdade('NÃO lê a lista de quem vence — que é a carteira inteira',
  recusado($$select * from public.assinaturas_a_vencer(90)$$));

-- E o caminho direto, sem função nenhuma: editar a própria assinatura.
select t_verdade('e NÃO edita a própria assinatura na mão',
  recusado($$update public.assinaturas set plano = 'salao',
              vence_em = current_date + 3650
              where salao_id = 'c0000000-1111-0000-0000-00000000000a'$$));
-- `recusado()` fica verde tanto por RLS quanto por erro de digitação: aqui o
-- que prova é o valor DEPOIS da tentativa.
select t_texto('o plano continua o que estava',
  (select plano from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a'), 'salao');
select t_verdade('e a validade não foi para 2035',
  (select vence_em from public.assinaturas
    where salao_id = 'c0000000-1111-0000-0000-00000000000a')
  < current_date + 400);

-- Nem escrever direto na tabela de cobranças, que é o mesmo furo por outra
-- porta: bastaria um INSERT com status 'paga'.
select t_verdade('nem escreve na tabela de cobranças',
  recusado($$insert into public.cobrancas
    (salao_id, plano, valor, metodo, status, vence_em)
    values ('c0000000-1111-0000-0000-00000000000a','salao',0.01,'pix','paga',
            now() + interval '1 day')$$));

\echo ''
\echo 'O QUE A TELA DO DONO PODE LER'

select t_verdade('a dona A lê a cobrança aberta dela',
  (public.minha_cobranca('c0000000-1111-0000-0000-00000000000a')
    -> 'aberta' ->> 'plano') = 'salao');
select t_verdade('com o Pix copia-e-cola, que é dela mesma',
  (public.minha_cobranca('c0000000-1111-0000-0000-00000000000a')
    -> 'historico') is not null);

select t_verdade('mas NÃO lê a do salão do vizinho',
  recusado($$select public.minha_cobranca(
    'c0000000-1111-0000-0000-00000000000b')$$));
select t_igual('nem enxerga as cobranças dele pela tabela',
  (select count(*) from public.cobrancas
    where salao_id = 'c0000000-1111-0000-0000-00000000000b'), 0);

reset role;
select set_config('request.jwt.claim.sub', '', false);
