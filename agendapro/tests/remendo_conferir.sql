-- ===========================================================================
-- O que o 99_remendo.sql tinha que ter feito com o cadastro sujo.
-- Carregado por tests/rodar.sh depois de colar o remendo.
-- ===========================================================================

\set ON_ERROR_STOP on

select t_texto('string vazia virou nulo',
  (select telefone from public.clientes
    where id = 'dddddddd-9999-0000-0000-00000000000a'),
  null);

select t_texto('máscara virou dígitos',
  (select telefone from public.clientes
    where id = 'dddddddd-9999-0000-0000-00000000000b'),
  '11988887777');

select t_texto('a ficha que já estava limpa não foi mexida',
  (select telefone from public.clientes
    where id = 'dddddddd-9999-0000-0000-00000000000c'),
  '51999990000');

-- A que colide fica como está, de propósito. Juntar as duas fichas é mover
-- agendamento e comanda de uma para a outra: some dinheiro ou some
-- atendimento, e ninguém fica sabendo qual. Fica para o salão decidir.
select t_texto('a ficha que colidia ficou intacta',
  (select telefone from public.clientes
    where id = 'dddddddd-9999-0000-0000-00000000000d'),
  '(51) 99999-0000');

select t_verdade('a trava cli_tel_so_digitos existe',
  exists (select 1 from pg_constraint
           where conname = 'cli_tel_so_digitos'
             and conrelid = 'public.clientes'::regclass));

-- A trava é o que impede o defeito de voltar por outro caminho: um painel
-- antigo em cache, um import de planilha, uma inserção pelo painel do
-- Supabase. Conferir que ela EXISTE não basta — `not valid` também existe e
-- não recusaria nada se estivesse escrita errada.
select t_verdade('telefone novo com máscara é recusado',
  recusado($$insert into public.clientes (salao_id, nome, telefone)
             values ('aaaaaaaa-9999-0000-0000-000000000001',
                     'Nova', '(31) 97777-6666')$$));

select t_verdade('telefone novo em dígitos passa',
  not recusado($$insert into public.clientes (salao_id, nome, telefone)
                 values ('aaaaaaaa-9999-0000-0000-000000000001',
                         'Nova', '31977776666')$$));

-- Duas fichas sem número no mesmo salão: era o "duplicate key value violates
-- unique constraint ux_cli_tel" que a recepção levava ao cadastrar a segunda
-- pessoa que passou sem deixar telefone.
select t_verdade('dá para cadastrar duas fichas sem telefone',
  not recusado($$insert into public.clientes (salao_id, nome, telefone) values
                 ('aaaaaaaa-9999-0000-0000-000000000001', 'Sem número 2', null),
                 ('aaaaaaaa-9999-0000-0000-000000000001', 'Sem número 3', null)$$));
