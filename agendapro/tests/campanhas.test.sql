-- ===========================================================================
-- AgendaPro — Campanhas de WhatsApp: isolamento, fila e idempotência
--
-- Este arquivo existe para responder às três perguntas que, se erradas,
-- tornam o módulo inaceitável num SaaS:
--
--   1. O Salão A consegue enxergar, alterar ou mandar mensagem para a
--      clientela do Salão B? (multi-tenant)
--   2. Dois disparos ao mesmo tempo mandam a mesma mensagem duas vezes?
--   3. Quem pediu para não receber promoção recebe promoção?
--
-- As respostas não são conferidas no navegador. São conferidas AQUI, contra
-- o banco, com o RLS ligado e trocando de usuário — porque é assim que um
-- atacante chega: pela API, com o uuid do outro na mão.
-- ===========================================================================

\set ON_ERROR_STOP on

-- ── Dois salões, dois donos, clientelas separadas ──────────────────────────
insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-00000000000a', 'donoA@teste.com'),
  ('b0000000-0000-0000-0000-00000000000b', 'donoB@teste.com');

insert into public.perfis (id, nome, telefone) values
  ('a0000000-0000-0000-0000-00000000000a', 'Dona A', '+5511900000011'),
  ('b0000000-0000-0000-0000-00000000000b', 'Dono B', '+5511900000022')
on conflict (id) do nothing;

insert into public.saloes (id, slug, nome, tipo) values
  ('a0000000-1111-0000-0000-000000000001', 'salao-a', 'Salão A', 'salao'),
  ('b0000000-1111-0000-0000-000000000001', 'salao-b', 'Salão B', 'salao');

insert into public.assinaturas (salao_id, plano, status) values
  ('a0000000-1111-0000-0000-000000000001', 'time', 'ativa'),
  ('b0000000-1111-0000-0000-000000000001', 'time', 'ativa');

insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a0000000-0000-0000-0000-00000000000a',
   'a0000000-1111-0000-0000-000000000001', 'dono', 'ativo'),
  ('b0000000-0000-0000-0000-00000000000b',
   'b0000000-1111-0000-0000-000000000001', 'dono', 'ativo')
on conflict do nothing;

insert into public.clientes (id, salao_id, nome, telefone, aceita_marketing) values
  ('a0000000-2222-0000-0000-000000000001',
   'a0000000-1111-0000-0000-000000000001', 'Ana do A',   '11911111111', true),
  ('a0000000-2222-0000-0000-000000000002',
   'a0000000-1111-0000-0000-000000000001', 'Bia do A',   '11922222222', true),
  -- Pediu para não receber promoção.
  ('a0000000-2222-0000-0000-000000000003',
   'a0000000-1111-0000-0000-000000000001', 'Célia do A', '11933333333', false),
  -- Sem telefone: não há para onde mandar.
  ('a0000000-2222-0000-0000-000000000004',
   'a0000000-1111-0000-0000-000000000001', 'Dora do A',  null, true),
  ('b0000000-2222-0000-0000-000000000001',
   'b0000000-1111-0000-0000-000000000001', 'Elza do B',  '11944444444', true);

\echo ''
\echo 'Quem entra numa campanha de promoção'

select set_config('request.jwt.claim.sub',
                  'a0000000-0000-0000-0000-00000000000a', false);
select t_verdade('o teste está logado como a dona do Salão A',
  auth.uid() = 'a0000000-0000-0000-0000-00000000000a');

select t_igual('promoção alcança 2 das 4 fichas do salão',
  (select count(*) from public.publico_da_campanha(
     'a0000000-1111-0000-0000-000000000001', 'promocao')), 2);

select t_falso('quem pediu para não receber promoção ficou de fora',
  exists (select 1 from public.publico_da_campanha(
            'a0000000-1111-0000-0000-000000000001', 'promocao') p
           where p.cliente_id = 'a0000000-2222-0000-0000-000000000003'));

select t_falso('ficha sem telefone ficou de fora',
  exists (select 1 from public.publico_da_campanha(
            'a0000000-1111-0000-0000-000000000001', 'promocao') p
           where p.cliente_id = 'a0000000-2222-0000-0000-000000000004'));

-- Lembrete de horário é serviço, não propaganda: o opt-out de marketing não
-- pode calar o aviso de que a pessoa tem hora marcada.
select t_igual('já um lembrete alcança as 3 com telefone',
  (select count(*) from public.publico_da_campanha(
     'a0000000-1111-0000-0000-000000000001', 'lembrete')), 3);

select t_falso('e NUNCA alcança a cliente do outro salão',
  exists (select 1 from public.publico_da_campanha(
            'a0000000-1111-0000-0000-000000000001', 'lembrete') p
           where p.cliente_id = 'b0000000-2222-0000-0000-000000000001'));

\echo ''
\echo 'Montar a fila e disparar'

insert into public.campanhas (id, salao_id, nome, tipo, corpo, template_nome, criada_por)
values ('a0000000-3333-0000-0000-000000000001',
        'a0000000-1111-0000-0000-000000000001',
        'Promoção de setembro', 'promocao', null, 'promo_setembro',
        'a0000000-0000-0000-0000-00000000000a');

select t_igual('a fila nasce com os 2 do público',
  public.montar_fila('a0000000-3333-0000-0000-000000000001')::bigint, 2);

-- Item 23 do pedido: refresh, timeout, duplo clique. Montar de novo não pode
-- criar uma segunda linha para a mesma pessoa.
select t_igual('montar de novo NÃO duplica ninguém',
  public.montar_fila('a0000000-3333-0000-0000-000000000001')::bigint, 2);

-- Confere pela TRAVA que barrou, não pelo começo da frase: recortar a
-- mensagem por caracteres faz o teste depender da redação do Postgres.
select t_verdade('e o banco recusa a duplicata na marra também',
  erro_de($$
     insert into public.campanha_destinatarios (campanha_id, salao_id, cliente_id, telefone)
     values ('a0000000-3333-0000-0000-000000000001',
             'a0000000-1111-0000-0000-000000000001',
             'a0000000-2222-0000-0000-000000000001', '11911111111')$$)
  like '%ux_camp_dest%');

\echo ''
\echo 'O SALÃO B NÃO ALCANÇA NADA DO SALÃO A'

select set_config('request.jwt.claim.sub',
                  'b0000000-0000-0000-0000-00000000000b', false);
select t_verdade('agora logado como o dono do Salão B',
  auth.uid() = 'b0000000-0000-0000-0000-00000000000b');

/* `set role`, NÃO `set local role`.

   Fora de uma transação o `set local` volta atrás na hora, e as consultas
   seguintes rodariam como `postgres` — superusuário, que passa por cima do
   RLS. O teste inteiro de isolamento ficaria verde provando o contrário do
   que diz. A linha abaixo confere que a troca pegou, antes de qualquer
   asserção depender dela. */
set role authenticated;
select t_texto('o teste está rodando como authenticated, não como dono do banco',
  current_user, 'authenticated');

select t_igual('ele não LÊ a campanha do A',
  (select count(*) from public.campanhas
    where id = 'a0000000-3333-0000-0000-000000000001'), 0);

select t_igual('nem os destinatários dela — nenhum telefone alheio',
  (select count(*) from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'), 0);

/* ⚠ NENHUM AUXILIAR DE PERMISSÃO PODE DEVOLVER NULL

   `papel_no_salao()` é NULL para quem não tem vínculo, e `NULL in (...)` é
   NULL. Dentro de uma policy isso barra igual — policy só deixa passar TRUE.
   Dentro de uma função `security definer`, não: `if not e_gestor(x)` com NULL
   vira `not NULL` = NULL, o `if` não dispara, e a função segue como se a
   permissão existisse.

   Foi assim que `placar_campanha()` devolveu o placar da campanha de OUTRO
   salão para quem só tinha o uuid. As três linhas abaixo travam a classe
   inteira, não só aquele caso. */
select t_falso('e_equipe() de um salão alheio é false, não NULL',
  public.e_equipe('a0000000-1111-0000-0000-000000000001') is null);
select t_falso('e_gestor() de um salão alheio é false, não NULL',
  public.e_gestor('a0000000-1111-0000-0000-000000000001') is null);
select t_falso('tem_acesso() de um salão alheio é false, não NULL',
  public.tem_acesso('a0000000-1111-0000-0000-000000000001') is null);

-- IDOR: ele TEM o uuid da campanha do outro e chama a função direto.
select t_verdade('chamar o placar com o uuid do outro é RECUSADO',
  recusado($$select public.placar_campanha(
    'a0000000-3333-0000-0000-000000000001')$$));

select t_verdade('cancelar a campanha do outro é RECUSADO',
  recusado($$select public.cancelar_campanha(
    'a0000000-3333-0000-0000-000000000001')$$));

select t_verdade('iniciar a campanha do outro é RECUSADO',
  recusado($$select public.iniciar_campanha(
    'a0000000-3333-0000-0000-000000000001')$$));

select t_verdade('listar a clientela do outro é RECUSADO',
  recusado($$select * from public.publico_da_campanha(
    'a0000000-1111-0000-0000-000000000001', 'promocao')$$));

-- E o que ele NÃO PODE é criar campanha apontando para o salão alheio: seria
-- mandar mensagem em nome de outra casa, com a clientela de outra casa.
select t_verdade('criar campanha no salão do outro é RECUSADO',
  recusado($$insert into public.campanhas (salao_id, nome, corpo)
             values ('a0000000-1111-0000-0000-000000000001', 'Invasão', 'oi')$$));

-- A fila é do worker, não do dono de salão. Se `authenticated` alcançasse
-- isto, qualquer dono varreria telefone da plataforma inteira.
select t_verdade('a fila do worker é RECUSADA a quem só fez login',
  recusado($$select * from public.fila_proxima(5)$$));

select t_verdade('e registrar resultado também',
  recusado($$select public.fila_resultado(
    'a0000000-4444-0000-0000-000000000001'::uuid, true)$$));

reset role;

\echo ''
\echo 'A fila entrega cada pessoa UMA vez'

select set_config('request.jwt.claim.sub',
                  'a0000000-0000-0000-0000-00000000000a', false);
select public.iniciar_campanha('a0000000-3333-0000-0000-000000000001');

select t_texto('a campanha ficou processando',
  (select status from public.campanhas
    where id = 'a0000000-3333-0000-0000-000000000001'), 'processando');

-- O worker pega tudo. Uma segunda chamada não pode devolver ninguém: as
-- linhas já saíram de 'pendente' na mesma transação em que foram tomadas.
select t_igual('a primeira passada do worker leva os 2',
  (select count(*) from public.fila_proxima(10)), 2);
select t_igual('a segunda passada não leva NINGUÉM de novo',
  (select count(*) from public.fila_proxima(10)), 0);

\echo ''
\echo 'Resultado, retentativa e fim'

-- Um deu certo.
select public.fila_resultado(
  (select id from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
    order by criado_em limit 1),
  true, 'wamid.TESTE1');

select t_igual('uma enviada',
  (select (public.placar_campanha('a0000000-3333-0000-0000-000000000001')
             ->>'enviadas')::bigint), 1);

-- O outro falhou por erro temporário: volta para a fila, com espera.
select public.fila_resultado(
  (select id from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
      and status = 'processando' limit 1),
  false, null, '500', 'erro temporario');

select t_texto('erro temporário devolve para a fila',
  (select status from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
      and erro_codigo = '500'), 'pendente');

select t_verdade('com espera antes de tentar de novo',
  (select proxima_em > now() from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
      and erro_codigo = '500'));

select t_igual('e o worker não o pega enquanto a espera não vence',
  (select count(*) from public.fila_proxima(10)), 0);

-- Erro permanente (número inválido) não fica girando: falha na hora.
update public.campanha_destinatarios
   set proxima_em = null
 where campanha_id = 'a0000000-3333-0000-0000-000000000001' and status = 'pendente';
select public.fila_proxima(10);
select public.fila_resultado(
  (select id from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
      and status = 'processando' limit 1),
  false, null, '131026', 'telefone invalido', true);

select t_texto('erro permanente vira falha na primeira vez',
  (select status from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000001'
      and erro_codigo = '131026'), 'falhou');

select t_texto('e a campanha fecha dizendo que houve falha',
  (select status from public.campanhas
    where id = 'a0000000-3333-0000-0000-000000000001'), 'concluida_com_falhas');

\echo ''
\echo 'Cancelar'

insert into public.campanhas (id, salao_id, nome, corpo, criada_por)
values ('a0000000-3333-0000-0000-000000000002',
        'a0000000-1111-0000-0000-000000000001',
        'Para cancelar', 'Oi {{nome}}',
        'a0000000-0000-0000-0000-00000000000a');
select public.montar_fila('a0000000-3333-0000-0000-000000000002');
select public.iniciar_campanha('a0000000-3333-0000-0000-000000000002');

-- Uma já saiu; a outra ainda está pendente.
select public.fila_proxima(1);
select public.fila_resultado(
  (select id from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000002'
      and status = 'processando' limit 1),
  true, 'wamid.TESTE2');

select public.cancelar_campanha('a0000000-3333-0000-0000-000000000002');

select t_igual('a que já foi continua enviada',
  (select count(*) from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000002'
      and status = 'enviado'), 1);
select t_igual('a pendente virou cancelada',
  (select count(*) from public.campanha_destinatarios
    where campanha_id = 'a0000000-3333-0000-0000-000000000002'
      and status = 'cancelado'), 1);
select t_igual('e o worker não pega mais ninguém dela',
  (select count(*) from public.fila_proxima(10)), 0);

select set_config('request.jwt.claim.sub', '', false);
