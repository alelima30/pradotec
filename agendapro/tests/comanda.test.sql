-- ===========================================================================
-- AgendaPro — as travas do dinheiro (Fase 2A)
--
-- Este arquivo guarda as TRÊS SONDAGENS da auditoria da Fase 2. Elas foram
-- rodadas neste mesmo banco, antes de uma linha de correção existir, e as três
-- confirmaram o defeito:
--
--   · duas comandas no mesmo agendamento          → aceitas
--   · R$ 500,00 numa comanda de R$ 100,00         → aceito
--   · desconto de R$ 300 num subtotal de R$ 100   → total de −R$ 200,00
--
-- ⚠ E A SEÇÃO 0 AS REPRODUZ COM AS TRAVAS DESLIGADAS.
-- Sem isso, tudo abaixo ficaria verde com gatilhos que não fazem nada — o
-- banco de teste nasce já corrigido. A seção 0 prova que a suíte SABE ver o
-- defeito; só então as travas voltam e o resto roda.
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values ('d0000000-0000-0000-0000-00000000000a','d@t.com');
insert into public.perfis (id, nome, telefone) values
  ('d0000000-0000-0000-0000-00000000000a','Dona D','+5511900000601')
on conflict (id) do update set nome = excluded.nome;

insert into public.saloes (id, slug, nome, tipo, fuso) values
  ('d0000000-1111-0000-0000-00000000000a','salao-d','Salão D','salao','America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status) values
  ('d0000000-1111-0000-0000-00000000000a','time','ativa');
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('d0000000-0000-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a','dono','ativo');
insert into public.profissionais (id, salao_id, nome, comissao_pct) values
  ('d0000000-2222-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a','Ana',40);
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select 'd0000000-2222-0000-0000-00000000000a', g,'09:00','18:00' from generate_series(0,6) g;
insert into public.clientes (id, salao_id, nome, telefone) values
  ('d0000000-3333-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a','Cliente D','11944440001');
insert into public.agendamentos (id, salao_id, cliente_id, profissional_id, inicio, fim, status, valor_previsto)
values ('d0000000-4444-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a',
        'd0000000-3333-0000-0000-00000000000a','d0000000-2222-0000-0000-00000000000a',
        ((current_date+1)+time '10:00') at time zone 'America/Sao_Paulo',
        ((current_date+1)+time '11:00') at time zone 'America/Sao_Paulo','confirmado',100);

/* Abre uma comanda e devolve a mensagem do banco (null quando passou). */
create or replace function abrir(p_agend uuid) returns text
language plpgsql as $$
begin
  insert into public.comandas (salao_id, agendamento_id, cliente_id)
  values ('d0000000-1111-0000-0000-00000000000a', p_agend,
          'd0000000-3333-0000-0000-00000000000a');
  return null;
exception when others then return sqlerrm; end $$;

\echo ''
\echo '0. A SUÍTE SABE VER OS TRÊS DEFEITOS'

/* ⚠ As travas saem, os defeitos são reproduzidos, e as travas voltam.
   É a diferença entre "o teste está verde" e "a regra existe". */
drop index if exists public.ux_comanda_agendamento;
drop trigger if exists tg_comanda_desconto on public.comandas;
drop trigger if exists tg_item_desconto on public.comanda_itens;
drop trigger if exists tg_pagamento_cabe on public.pagamentos;

select t_texto('sem a trava, o MESMO agendamento aceita duas comandas',
  abrir('d0000000-4444-0000-0000-00000000000a'), null);
select t_texto('  (e a segunda também)',
  abrir('d0000000-4444-0000-0000-00000000000a'), null);
select t_igual('  duas comandas gravadas',
  (select count(*) from public.comandas
    where agendamento_id = 'd0000000-4444-0000-0000-00000000000a'), 2);

select id as velha from public.comandas limit 1 \gset
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct)
values (:'velha','servico','Corte',1,100,'d0000000-2222-0000-0000-00000000000a',40);
insert into public.pagamentos (comanda_id, forma, valor) values (:'velha','pix',500);
select t_verdade('sem a trava, R$ 500 entram numa comanda de R$ 100',
  (select pago from public.comandas_totais where id = :'velha') = 500);

update public.comandas set desconto = 300 where id = :'velha';
select t_verdade('sem a trava, o total fica NEGATIVO',
  (select total from public.comandas_totais where id = :'velha') < 0);

-- Limpa e recoloca as travas.
delete from public.pagamentos where comanda_id = :'velha';
delete from public.comanda_itens where comanda_id = :'velha';
delete from public.comandas where agendamento_id = 'd0000000-4444-0000-0000-00000000000a';

create unique index ux_comanda_agendamento on public.comandas(agendamento_id)
  where (agendamento_id is not null and status <> 'cancelada');
create constraint trigger tg_comanda_desconto after update of desconto
  on public.comandas deferrable initially immediate
  for each row execute function public.tg_comanda_desconto();
create constraint trigger tg_item_desconto after insert or update or delete
  on public.comanda_itens deferrable initially immediate
  for each row execute function public.tg_item_desconto();
create trigger tg_pagamento_cabe before insert or update of valor, comanda_id
  on public.pagamentos for each row execute function public.tg_pagamento_cabe();

\echo ''
\echo '1. UM ATENDIMENTO POR AGENDAMENTO'

select t_texto('a primeira comanda abre', abrir('d0000000-4444-0000-0000-00000000000a'), null);
select t_verdade('a segunda é RECUSADA',
  abrir('d0000000-4444-0000-0000-00000000000a') is not null);
select t_igual('e continua havendo uma só',
  (select count(*) from public.comandas
    where agendamento_id = 'd0000000-4444-0000-0000-00000000000a'), 1);

/* Comanda de balcão, sem agendamento, não disputa com ninguém — o salão
   atende quem chega sem ter marcado, e podem ser muitas no mesmo dia. */
select t_texto('comanda avulsa abre', abrir(null), null);
select t_texto('e outra avulsa também', abrir(null), null);

/* Cancelar tem que LIBERAR o agendamento. Sem isto, cancelar por engano
   trancaria a cliente para sempre. */
select id as com1 from public.comandas
 where agendamento_id = 'd0000000-4444-0000-0000-00000000000a' \gset
update public.comandas set status = 'cancelada' where id = :'com1';
select t_texto('cancelada, o agendamento aceita uma comanda nova',
  abrir('d0000000-4444-0000-0000-00000000000a'), null);
update public.comandas set status = 'cancelada'
 where agendamento_id = 'd0000000-4444-0000-0000-00000000000a';

\echo ''
\echo '2. O TOTAL NUNCA É NEGATIVO'

select (select id from public.comandas where agendamento_id is null limit 1) as com \gset
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct)
values (:'com','servico','Corte',1,100,'d0000000-2222-0000-0000-00000000000a',40);

select t_verdade('desconto maior que os itens é RECUSADO',
  recusado(format($$update public.comandas set desconto = 300 where id = %L$$, :'com'::uuid)));
/* A mensagem é lida pela recepção, com a cliente esperando: tem que dizer os
   DOIS valores, e em português. `to_char` com G/D segue o locale do servidor
   e saía à americana — por isso existe o `reais()`. */
select t_verdade('e a mensagem diz os dois valores, em português',
  erro_de(format($$update public.comandas set desconto = 300 where id = %L$$, :'com'::uuid))
    like '%R$ 300,00%R$ 100,00%');
select t_texto('desconto igual ao subtotal passa — é a cortesia inteira',
  erro_de(format($$update public.comandas set desconto = 100 where id = %L$$, :'com'::uuid)), null);
update public.comandas set desconto = 20 where id = :'com';
select t_texto('e o total fica certo',
  (select total::text from public.comandas_totais where id = :'com'), '80.00');

/* ⚠ O CAMINHO DE TRÁS, que é o que uma trava só não pegaria: pôr desconto
   válido e depois APAGAR o item, deixando o subtotal abaixo do desconto. */
select t_verdade('apagar o item por baixo do desconto é RECUSADO',
  recusado(format($$delete from public.comanda_itens where comanda_id = %L$$, :'com'::uuid)));
select t_texto('e o item continua lá',
  (select count(*)::text from public.comanda_itens where comanda_id = :'com'), '1');

/* ⚠ NASCER COM DESCONTO É PERMITIDO — E O BURACO É FECHADO PELO ITEM.
   No INSERT da comanda os itens não existem (a chave estrangeira aponta do
   item para ela), então conferir ali recusaria toda comanda criada já com
   desconto. Quem fecha é o gatilho do item: no momento em que o primeiro
   entra, a conta é refeita. */
insert into public.comandas (id, salao_id, cliente_id, desconto) values
  ('d0000000-6666-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a',
   'd0000000-3333-0000-0000-00000000000a', 300);
select t_texto('comanda nasce com desconto de 300 e nenhum item',
  (select desconto::text from public.comandas
    where id = 'd0000000-6666-0000-0000-00000000000a'), '300.00');
select t_verdade('mas o primeiro item de R$ 100 é RECUSADO — a conta é refeita ali',
  recusado($$insert into public.comanda_itens
    (comanda_id, tipo, descricao, qtd, preco_unit, profissional_id, comissao_pct)
    values ('d0000000-6666-0000-0000-00000000000a','servico','Corte',1,100,
            'd0000000-2222-0000-0000-00000000000a',40)$$));
select t_verdade('e ela não fecha, porque não tem item nenhum',
  recusado($$update public.comandas set status='fechada'
             where id = 'd0000000-6666-0000-0000-00000000000a'$$));

\echo ''
\echo '3. O ACRÉSCIMO'

update public.comandas set acrescimo = 15 where id = :'com';
select t_texto('subtotal 100, desconto 20, acréscimo 15 → total 95',
  (select total::text from public.comandas_totais where id = :'com'), '95.00');
select t_verdade('acréscimo negativo é recusado',
  recusado(format($$update public.comandas set acrescimo = -5 where id = %L$$, :'com'::uuid)));
update public.comandas set acrescimo = 0 where id = :'com';

\echo ''
\echo '4. NÃO SE RECEBE MAIS DO QUE A CONTA'

-- Total agora: 100 − 20 = 80.
select t_verdade('R$ 500 numa conta de R$ 80 é RECUSADO',
  recusado(format($$insert into public.pagamentos (comanda_id, forma, valor)
                    values (%L,'pix',500)$$, :'com'::uuid)));
select t_verdade('e a mensagem diz quanto ainda falta',
  erro_de(format($$insert into public.pagamentos (comanda_id, forma, valor)
                   values (%L,'pix',500)$$, :'com'::uuid)) like '%R$ 80,00%');

select t_texto('pagamento parcial de R$ 30 entra',
  erro_de(format($$insert into public.pagamentos (comanda_id, forma, valor)
                   values (%L,'pix',30)$$, :'com'::uuid)), null);
select t_texto('a situação vira parcial',
  (select situacao from public.comandas_totais where id = :'com'), 'parcial');
select t_texto('e faltam 50',
  (select falta::text from public.comandas_totais where id = :'com'), '50.00');

select t_verdade('mais R$ 60 seria demais, e é RECUSADO',
  recusado(format($$insert into public.pagamentos (comanda_id, forma, valor)
                    values (%L,'dinheiro',60)$$, :'com'::uuid)));

-- Pagamento DIVIDIDO: duas formas na mesma comanda, somando o total.
select t_texto('os R$ 50 que faltam, em dinheiro, entram',
  erro_de(format($$insert into public.pagamentos (comanda_id, forma, valor)
                   values (%L,'dinheiro',50)$$, :'com'::uuid)), null);
select t_texto('a situação vira paga',
  (select situacao from public.comandas_totais where id = :'com'), 'pago');
select t_igual('com duas formas de pagamento na mesma comanda',
  (select count(*) from public.pagamentos where comanda_id = :'com'), 2);
select t_texto('e não falta nada',
  (select falta::text from public.comandas_totais where id = :'com'), '0.00');

\echo ''
\echo '5. FECHAR EXIGE A CONTA PAGA'

update public.comandas set status = 'fechada' where id = :'com';
select t_texto('a comanda paga fecha',
  (select status from public.comandas where id = :'com'), 'fechada');
select t_verdade('e o banco carimbou a hora do fechamento',
  (select fechada_em from public.comandas where id = :'com') is not null);

-- Uma comanda com itens e sem pagamento não fecha.
select (select id from public.comandas
         where agendamento_id is null and id <> :'com'::uuid limit 1) as com2 \gset
insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit,
                                  profissional_id, comissao_pct)
values (:'com2','servico','Escova',1,70,'d0000000-2222-0000-0000-00000000000a',40);
select t_verdade('sem pagamento, NÃO fecha',
  recusado(format($$update public.comandas set status='fechada' where id = %L$$, :'com2'::uuid)));
select t_verdade('e a mensagem diz quanto falta',
  erro_de(format($$update public.comandas set status='fechada' where id = %L$$, :'com2'::uuid))
    like '%R$ 70,00%');

-- Comanda vazia também não: seria atendimento sumindo do relatório.
insert into public.comandas (id, salao_id, cliente_id) values
  ('d0000000-5555-0000-0000-00000000000a','d0000000-1111-0000-0000-00000000000a',
   'd0000000-3333-0000-0000-00000000000a');
select t_verdade('comanda sem item nenhum NÃO fecha',
  recusado($$update public.comandas set status='fechada'
             where id = 'd0000000-5555-0000-0000-00000000000a'$$));

\echo ''
\echo '6. COMANDA FECHADA NÃO SE MEXE'

select t_verdade('não entra item novo',
  recusado(format($$insert into public.comanda_itens
    (comanda_id, tipo, descricao, qtd, preco_unit, profissional_id, comissao_pct)
    values (%L,'servico','Barba',1,40,'d0000000-2222-0000-0000-00000000000a',40)$$,
    :'com'::uuid)));
select t_verdade('nem sai o que já estava',
  recusado(format($$delete from public.comanda_itens where comanda_id = %L$$, :'com'::uuid)));
select t_verdade('não entra pagamento novo',
  recusado(format($$insert into public.pagamentos (comanda_id, forma, valor)
                    values (%L,'pix',10)$$, :'com'::uuid)));
select t_verdade('nem se apaga um pagamento',
  recusado(format($$delete from public.pagamentos where comanda_id = %L$$, :'com'::uuid)));
select t_verdade('e o desconto não muda',
  recusado(format($$update public.comandas set desconto = 50 where id = %L$$, :'com'::uuid)));

/* ⚠ MAS REABRIR TEM QUE FUNCIONAR — é o caminho legítimo de correção, e uma
   trava que olhasse só o status antigo o teria fechado junto. */
select t_texto('reabrir passa',
  erro_de(format($$update public.comandas set status='aberta', fechada_em=null
                   where id = %L$$, :'com'::uuid)), null);
select t_texto('e aí o item entra',
  erro_de(format($$insert into public.comanda_itens
    (comanda_id, tipo, descricao, qtd, preco_unit, profissional_id, comissao_pct)
    values (%L,'servico','Barba',1,40,'d0000000-2222-0000-0000-00000000000a',40)$$,
    :'com'::uuid)), null);

\echo ''
\echo '7. O TROCO — a direção que NÃO se bloqueia'

/* Receber R$ 80 e depois tirar um item, deixando a conta menor, é troco: uma
   situação de balcão de verdade. Recusar prenderia a recepção numa comanda
   que ela não conseguiria corrigir. Passa, e a vista mostra `falta` negativo. */
/* ⚠ A PRIMEIRA VERSÃO DESTE BLOCO NÃO PROVAVA NADA.
   Ela tirava a barba e afirmava "troco a devolver" — mas a conta caía
   exatamente para o valor já pago, e `falta` dava 0,00. O teste passaria
   verde sem nunca ter chegado ao número negativo que ele diz testar.

   Para haver troco de verdade, a conta precisa cair ABAIXO do que entrou. */
select t_texto('a conta subiu para 120 com a barba, e o pago continua 80',
  (select falta::text from public.comandas_totais where id = :'com'), '40.00');
select t_texto('a cliente paga os 40 que faltavam',
  erro_de(format($$insert into public.pagamentos (comanda_id, forma, valor)
                   values (%L,'debito',40)$$, :'com'::uuid)), null);
select t_texto('agora está tudo pago',
  (select situacao from public.comandas_totais where id = :'com'), 'pago');

select t_texto('e a barba lançada por engano SAI, mesmo já paga',
  erro_de(format($$delete from public.comanda_itens
                   where comanda_id = %L and descricao = 'Barba'$$, :'com'::uuid)), null);
select t_texto('a vista mostra o troco a devolver, como número negativo',
  (select falta::text from public.comandas_totais where id = :'com'), '-40.00');
select t_texto('e a situação continua paga — o que falta é devolver, não receber',
  (select situacao from public.comandas_totais where id = :'com'), 'pago');

\echo ''
\echo '8. O QUE O NAVEGADOR ALCANÇA'

/* ⚠ O agendamento teve todas as comandas canceladas na seção 1, e comanda
   cancelada LIBERA o agendamento — é a regra, e está certa. Sem reativar uma,
   a asserção abaixo passaria por não haver o que duplicar, e não por a trava
   estar de pé. */
update public.comandas set status = 'aberta'
 where id = (select id from public.comandas
              where agendamento_id = 'd0000000-4444-0000-0000-00000000000a' limit 1);
select t_igual('há uma comanda ATIVA no agendamento, para haver o que duplicar',
  (select count(*) from public.comandas
    where agendamento_id = 'd0000000-4444-0000-0000-00000000000a'
      and status <> 'cancelada'), 1);

select set_config('request.jwt.claim.sub','d0000000-0000-0000-0000-00000000000a',false);
set role authenticated;
select t_texto('rodando como authenticated', current_user, 'authenticated');

/* As travas são gatilho, não função: valem para quem escreve DIRETO na
   tabela, que é exatamente como o painel escreve. */
select t_verdade('a dona também não paga mais que a conta',
  recusado(format($$insert into public.pagamentos (comanda_id, forma, valor)
                    values (%L,'pix',9999)$$, :'com'::uuid)));
select t_verdade('nem abre uma segunda comanda no mesmo agendamento',
  recusado($$insert into public.comandas (salao_id, agendamento_id, cliente_id)
             values ('d0000000-1111-0000-0000-00000000000a',
                     'd0000000-4444-0000-0000-00000000000a',
                     'd0000000-3333-0000-0000-00000000000a')$$));

-- E os auxiliares das travas não são de ninguém que esteja num navegador.
select t_falso('conferir_desconto não é alcançável',
  has_function_privilege('authenticated', 'public.conferir_desconto(uuid)', 'execute'));
-- `reais()` só formata número; a tela usa a mesma grafia nas mensagens dela.
select t_texto('e reais() escreve dinheiro em português, em qualquer locale',
  public.reais(1234.5), 'R$ 1.234,50');

reset role;
select set_config('request.jwt.claim.sub','',false);

drop function if exists abrir(uuid);
