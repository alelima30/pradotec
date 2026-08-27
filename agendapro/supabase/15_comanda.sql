-- ===========================================================================
-- AgendaPro — 15: as travas do dinheiro (Fase 2A)
--
-- ── O QUE A AUDITORIA MEDIU, E QUE ESTE ARQUIVO FECHA ──────────────────────
-- Três sondagens rodadas no banco antes de escrever qualquer coisa aqui, e as
-- três confirmaram o defeito:
--
--   · dois `insert` de comanda com o MESMO agendamento → aceitos
--   · R$ 500,00 de pagamento numa comanda de R$ 100,00 → aceito
--   · desconto de R$ 300,00 num subtotal de R$ 100,00 → total de −R$ 200,00
--
-- Os três já estavam conferidos na tela. Nenhum estava conferido no banco.
--
-- ── POR QUE GATILHO, E NÃO FUNÇÃO ─────────────────────────────────────────
-- O painel escreve DIRETO em `comandas`, `comanda_itens` e `pagamentos` pelo
-- PostgREST — `Dados.subir()` manda INSERT e PATCH, sem função no meio.
--
-- Regra de dinheiro escrita como função seria regra que o painel não chama, e
-- portanto regra que não existe. É a mesma lição da Fase 1, quando a jornada
-- de trabalho vivia só num aviso de tela: o que não está no gatilho não vale.
--
-- ── O QUE ESTE ARQUIVO NÃO FAZ ────────────────────────────────────────────
-- Não cria caixa, não cria estorno, não muda a regra de comissão. Caixa e
-- estorno são a 2B; a comissão sobre líquido é a 2D, e ela mexe em dinheiro
-- já apurado — precisa de data de corte, não de um `update`.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0) DINHEIRO ESCRITO EM PORTUGUÊS
--
-- ⚠ ISTO NÃO É ENFEITE, E CUSTOU UMA VOLTA PARA DESCOBRIR.
-- A primeira versão usava `to_char(v, 'FM999G999D00')`. O `G` (separador de
-- milhar) e o `D` (separador decimal) seguem o `lc_numeric` DO SERVIDOR — e
-- num Postgres com locale C eles saem como `1,234.56`, à americana. A
-- recepção leria "o desconto (300.00)" e o teste, que esperava vírgula,
-- reprovou.
--
-- O `.` e o `,` escritos direto no molde são literais, e não olham locale
-- nenhum. Daí a troca em três passos: o resultado é o mesmo em qualquer
-- instalação, esteja ela configurada como estiver.
-- ---------------------------------------------------------------------------
create or replace function public.reais(v numeric)
returns text language sql immutable set search_path = public as $$
  select 'R$ ' || replace(replace(replace(
           to_char(coalesce(v, 0), 'FM999,999,990.00'),
           '.', '|'), ',', '.'), '|', ',')
$$;

-- ---------------------------------------------------------------------------
-- 1) UM ATENDIMENTO POR AGENDAMENTO
--
-- A tela já procurava a comanda existente antes de criar. Só que procurar em
-- `bd.comandas` é procurar na memória de UM navegador: duplo clique, duas
-- abas, ou a recepção e o profissional ao mesmo tempo, e nascem duas comandas
-- para a mesma cliente — com o atendimento cobrado duas vezes.
--
-- O índice é PARCIAL de propósito, em duas dimensões:
--
--   `agendamento_id is not null`  a comanda de balcão, sem agendamento, não
--                                 disputa com ninguém — e pode haver quantas
--                                 o dia tiver
--   `status <> 'cancelada'`       cancelar uma comanda aberta por engano tem
--                                 que liberar o agendamento para abrir outra;
--                                 sem isto, o engano trancaria a cliente para
--                                 sempre
-- ---------------------------------------------------------------------------
/* ⚠ ANTES DO ÍNDICE, DESEMPATAR O QUE JÁ ESTÁ GRAVADO.

   Índice único não nasce em cima de dado que já o viola: o `create` falha
   com "could not create unique index", e num arquivo colado de uma vez isso
   é pior do que parece. Tudo que vem ANTES desta linha já rodou e ficou; o
   que vem DEPOIS — a vista nova, as travas do desconto, o gatilho que
   impede pagar mais do que se deve — não roda. O salão fica com meia
   instalação e uma mensagem em inglês sobre índice.

   E não é hipótese: enquanto o painel criava item e pagamento sem `id`, o
   `Dados.subir()` apagava e reinseria a comanda a cada gravação, e a tela
   abria outra quando não achava a do atendimento. Duas comandas no mesmo
   atendimento é exatamente o rastro que aquele defeito deixava.

   ── POR QUE DESLIGAR, E NÃO APAGAR NEM CANCELAR ──────────────────────────
   Estas linhas têm dinheiro dentro. Apagar tira faturamento do mês que já
   foi fechado e conferido. Cancelar é quase tão ruim: comanda cancelada sai
   do relatório, então o mês encolhe sozinho e ninguém sabe por quê.

   Desligar do atendimento (`agendamento_id = null`) não perde nada: a
   comanda continua existindo, com os itens, os pagamentos e o valor, e
   continua contando no relatório. Só deixa de estar amarrada àquele
   atendimento — que é a única coisa que o índice exige.

   Fica a do meio: a que tem mais pagamento, depois a que tem mais item,
   depois a mais antiga. A ordem é determinística de propósito — colar duas
   vezes tem que dar no mesmo, e `ties` resolvidos por `id` garantem isso. */
update public.comandas c
   set agendamento_id = null
 where c.agendamento_id is not null
   and c.status <> 'cancelada'
   and c.id <> (
     select d.id from public.comandas d
      where d.agendamento_id = c.agendamento_id
        and d.status <> 'cancelada'
      order by (select count(*) from public.pagamentos p
                 where p.comanda_id = d.id) desc,
               (select count(*) from public.comanda_itens i
                 where i.comanda_id = d.id) desc,
               d.aberta_em asc,
               d.id asc
      limit 1);

create unique index if not exists ux_comanda_agendamento
  on public.comandas(agendamento_id)
  where (agendamento_id is not null and status <> 'cancelada');

-- ---------------------------------------------------------------------------
-- 2) O ACRÉSCIMO
--
-- Existia desconto e não existia o contrário. Taxa de urgência, domingo,
-- atendimento em casa: o salão cobra a mais e não tinha onde lançar — ia como
-- item inventado, e aí entrava na comissão de alguém sem ser serviço.
-- ---------------------------------------------------------------------------
alter table public.comandas
  add column if not exists acrescimo numeric(10,2) not null default 0
    check (acrescimo >= 0);

comment on column public.comandas.acrescimo is
  'Taxa de urgência, domingo, deslocamento. Entra no total e NÃO gera comissão.';

-- ---------------------------------------------------------------------------
-- 3) A VISTA, REFEITA COM ACRÉSCIMO E COM A SITUAÇÃO DO PAGAMENTO
--
-- ⚠ SITUAÇÃO DE PAGAMENTO É DERIVADA, NÃO GUARDADA.
-- Uma coluna `status_pagamento` gravada precisaria ser atualizada a cada
-- pagamento inserido, removido, e a cada item que entra ou sai da comanda.
-- Toda coluna que precisa ser lembrada é uma coluna que um dia fica velha —
-- e "pago" gravado numa comanda que ninguém pagou é o pior tipo de mentira
-- que este sistema pode contar.
--
-- Calculada na vista, ela não tem como divergir: é sempre a soma de agora.
--
-- `security_invoker = true` continua OBRIGATÓRIO. Sem isso a vista roda com
-- os poderes de quem a criou e passa por cima do RLS das tabelas de baixo —
-- qualquer pessoa logada leria o faturamento de todos os salões.
-- ---------------------------------------------------------------------------
drop view if exists public.comandas_totais;

create view public.comandas_totais
with (security_invoker = true) as
  select c.id,
         c.salao_id,
         c.numero,
         c.status,
         coalesce(sum(i.total), 0)                                as subtotal,
         c.desconto,
         c.acrescimo,
         coalesce(sum(i.total), 0) - c.desconto + c.acrescimo     as total,
         coalesce(sum(i.comissao_valor), 0)                       as comissao_total,
         coalesce((select sum(p.valor) from public.pagamentos p
                    where p.comanda_id = c.id), 0)                as pago,
         -- O que ainda falta receber. Negativo significa troco a devolver.
         (coalesce(sum(i.total), 0) - c.desconto + c.acrescimo)
           - coalesce((select sum(p.valor) from public.pagamentos p
                        where p.comanda_id = c.id), 0)            as falta,
         case
           when c.status = 'cancelada' then 'cancelado'
           when coalesce((select sum(p.valor) from public.pagamentos p
                           where p.comanda_id = c.id), 0) = 0 then 'pendente'
           when coalesce((select sum(p.valor) from public.pagamentos p
                           where p.comanda_id = c.id), 0)
                >= (coalesce(sum(i.total), 0) - c.desconto + c.acrescimo)
             then 'pago'
           else 'parcial'
         end                                                      as situacao
    from public.comandas c
    left join public.comanda_itens i on i.comanda_id = c.id
   group by c.id;

grant select on public.comandas_totais to authenticated;

-- ---------------------------------------------------------------------------
-- 4) O TOTAL NUNCA É NEGATIVO
--
-- Medido: subtotal de R$ 100,00 com desconto de R$ 300,00 dava −R$ 200,00 — e
-- entrava SOMANDO no faturamento do mês, porque o relatório soma o total.
--
-- ⚠ A CONFERÊNCIA VALE NOS DOIS SENTIDOS, E É POR ISSO QUE SÃO DOIS GATILHOS.
-- Conferir só ao mudar o desconto deixaria o caminho de trás aberto: põe
-- R$ 100 de desconto numa comanda de R$ 100, depois APAGA o item — e o
-- subtotal cai para zero com o desconto de pé. O mesmo buraco, entrando pela
-- porta dos fundos.
-- ---------------------------------------------------------------------------
create or replace function public.conferir_desconto(p_comanda uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_sub  numeric(10,2);
  v_desc numeric(10,2);
begin
  select coalesce(sum(i.total), 0) into v_sub
    from public.comanda_itens i where i.comanda_id = p_comanda;
  select c.desconto into v_desc
    from public.comandas c where c.id = p_comanda;

  if v_desc > v_sub then
    raise exception
      'O desconto de % não pode ser maior que o valor dos itens (%).',
      public.reais(v_desc), public.reais(v_sub)
      using errcode = 'check_violation';
  end if;
end $$;

create or replace function public.tg_comanda_desconto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.conferir_desconto(new.id);
  return new;
end $$;

create or replace function public.tg_item_desconto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- No DELETE o que interessa é a comanda de onde o item SAIU.
  perform public.conferir_desconto(coalesce(new.comanda_id, old.comanda_id));
  return coalesce(new, old);
end $$;

/* ⚠ `deferrable INITIALLY IMMEDIATE`, e a diferença entre as duas palavras
   custou uma volta.

   A primeira versão era `initially deferred`: a conferência só rodava no
   COMMIT. Parecia mais seguro — deixaria uma transação inserir a comanda com
   desconto e os itens em qualquer ordem. Só que o painel não faz isso: o
   `Dados.subir()` grava a comanda com desconto ZERO e os itens depois, e o
   desconto só é alterado num PATCH sozinho, quando os itens já existem.

   O que `deferred` trouxe de concreto foi o erro aparecendo longe da causa —
   no fim da transação, sem dizer qual comando o provocou. E o teste nem
   conseguia enxergá-lo, porque `recusado()` retorna antes do commit.

   `deferrable` fica: quem precisar de uma ordem diferente pede
   `set constraints tg_comanda_desconto deferred` dentro da própria
   transação. O padrão é conferir na hora, junto do comando que errou. */
/* ⚠ E SÓ NO UPDATE, NÃO NO INSERT.
   No instante em que a comanda nasce, os itens dela ainda não existem — a
   chave estrangeira aponta do item para a comanda, então é impossível que
   existam. Conferir ali seria recusar toda comanda criada já com desconto,
   que é exatamente o que aconteceu com o fixture dos relatórios.

   O buraco que isso deixaria — nascer com desconto de R$ 300 e subtotal zero
   — é fechado pelo gatilho do ITEM logo abaixo: no momento em que o primeiro
   item entra, a conta é refeita e o desconto grande é recusado ali. E uma
   comanda sem item nenhum não fecha (seção 7), então nunca vira faturamento. */
drop trigger if exists tg_comanda_desconto on public.comandas;
create constraint trigger tg_comanda_desconto
  after update of desconto on public.comandas
  deferrable initially immediate
  for each row execute function public.tg_comanda_desconto();

drop trigger if exists tg_item_desconto on public.comanda_itens;
create constraint trigger tg_item_desconto
  after insert or update or delete on public.comanda_itens
  deferrable initially immediate
  for each row execute function public.tg_item_desconto();

-- ---------------------------------------------------------------------------
-- 5) NÃO SE RECEBE MAIS DO QUE A CONTA
--
-- Medido: R$ 500,00 lançados numa comanda de R$ 100,00, aceitos sem reclamar.
-- Um zero a mais na digitação vira R$ 400,00 de faturamento que nunca entrou
-- — e o dono só descobre fechando o caixa e não batendo.
--
-- ⚠ E POR QUE ISTO SÓ VALE NA DIREÇÃO DO PAGAMENTO.
-- O caminho contrário — receber R$ 100 e depois tirar um item, deixando a
-- conta em R$ 50 — é TROCO, uma situação de balcão de verdade. Recusar
-- prenderia a recepção: ela não conseguiria corrigir um item lançado errado
-- numa comanda já paga. Então isso passa, e a vista mostra `falta` negativo,
-- que é o troco a devolver.
-- ---------------------------------------------------------------------------
create or replace function public.tg_pagamento_cabe()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_total numeric(10,2);
  v_pago  numeric(10,2);
begin
  select t.total into v_total from public.comandas_totais t where t.id = new.comanda_id;
  select coalesce(sum(p.valor), 0) into v_pago
    from public.pagamentos p
   where p.comanda_id = new.comanda_id
     and (tg_op = 'INSERT' or p.id <> new.id);

  if v_total is null then
    raise exception 'Comanda não encontrada.' using errcode = 'check_violation';
  end if;

  -- Um centavo de folga: dinheiro tem arredondamento, e recusar por
  -- 0,001 seria recusar o pagamento certo.
  if v_pago + new.valor > v_total + 0.005 then
    raise exception
      'Pagamento de % excede o que falta nesta comanda: %.',
      public.reais(new.valor), public.reais(greatest(v_total - v_pago, 0))
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists tg_pagamento_cabe on public.pagamentos;
create trigger tg_pagamento_cabe
  before insert or update of valor, comanda_id on public.pagamentos
  for each row execute function public.tg_pagamento_cabe();

-- ---------------------------------------------------------------------------
-- 6) COMANDA FECHADA NÃO SE MEXE
--
-- Fechar é o que transforma atendimento em faturamento — é a data de
-- fechamento que diz de que mês é o dinheiro. Deixar item entrar depois faz o
-- mês mudar de valor sozinho, dias depois de o dono ter conferido.
--
-- O caminho para corrigir existe e é explícito: reabrir. A tela já faz isso,
-- e já restringe reabrir comanda de outro dia a quem administra o salão.
-- ---------------------------------------------------------------------------
create or replace function public.tg_comanda_travada()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_status text;
  v_com    uuid;
begin
  v_com := coalesce(
    case tg_table_name
      when 'comanda_itens' then coalesce(new.comanda_id, old.comanda_id)
      when 'pagamentos'    then coalesce(new.comanda_id, old.comanda_id)
    end);

  select c.status into v_status from public.comandas c where c.id = v_com;

  if v_status = 'fechada' then
    raise exception 'Esta comanda está fechada. Reabra antes de alterar.'
      using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end $$;

drop trigger if exists tg_item_travado on public.comanda_itens;
create trigger tg_item_travado
  before insert or update or delete on public.comanda_itens
  for each row execute function public.tg_comanda_travada();

drop trigger if exists tg_pagamento_travado on public.pagamentos;
create trigger tg_pagamento_travado
  before insert or update or delete on public.pagamentos
  for each row execute function public.tg_comanda_travada();

/* E o desconto e o acréscimo da própria comanda fechada.

   ⚠ Repare que a trava olha o status ANTIGO e o NOVO. Bloquear por
   `old.status = 'fechada'` sozinho impediria de REABRIR — que é justamente o
   caminho legítimo de correção. O que não pode é mudar valor com ela fechada
   dos dois lados. */
create or replace function public.tg_comanda_valor_travado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'fechada' and new.status = 'fechada'
     and (new.desconto is distinct from old.desconto
       or new.acrescimo is distinct from old.acrescimo) then
    raise exception 'Esta comanda está fechada. Reabra antes de alterar.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists tg_comanda_valor_travado on public.comandas;
create trigger tg_comanda_valor_travado
  before update of desconto, acrescimo on public.comandas
  for each row execute function public.tg_comanda_valor_travado();

-- ---------------------------------------------------------------------------
-- 7) FECHAR EXIGE A CONTA PAGA
--
-- A tela já pedia isso — foi o botão que nasceu junto com os relatórios. Mas
-- pedir na tela é pedir por favor: quem chama a API direto fecha do mesmo
-- jeito, e a comanda entra no faturamento do mês sem o dinheiro ter entrado.
--
-- Zero item também não fecha: comanda vazia fechada é atendimento que sumiu
-- do relatório sem ninguém notar.
-- ---------------------------------------------------------------------------
create or replace function public.tg_fechar_comanda()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t record;
begin
  if new.status <> 'fechada' or old.status = 'fechada' then
    return new;
  end if;

  select * into t from public.comandas_totais where id = new.id;

  if t.subtotal <= 0 then
    raise exception 'Comanda sem itens não pode ser fechada.'
      using errcode = 'check_violation';
  end if;
  if t.falta > 0.005 then
    raise exception 'Ainda faltam % para fechar esta comanda.',
      public.reais(t.falta) using errcode = 'check_violation';
  end if;

  -- A hora do fechamento é o que decide de que mês é o dinheiro. Se a tela
  -- esqueceu de mandar, o banco carimba.
  if new.fechada_em is null then new.fechada_em := now(); end if;

  return new;
end $$;

drop trigger if exists tg_fechar_comanda on public.comandas;
create trigger tg_fechar_comanda
  before update of status on public.comandas
  for each row execute function public.tg_fechar_comanda();

-- ---------------------------------------------------------------------------
-- 8) Quem pode chamar
--
-- Os auxiliares das travas rodam DENTRO dos gatilhos, com os poderes de quem
-- os criou. Ninguém precisa alcançá-los de fora, e deixar aberto seria dar a
-- qualquer sessão uma porta para ler valor de comanda alheia pelo id.
--
-- `reais()` fica aberta: ela só formata um número, e a tela usa a mesma
-- grafia nas mensagens que monta.
-- ---------------------------------------------------------------------------
revoke all on function public.conferir_desconto(uuid) from public, anon, authenticated;
revoke all on function public.reais(numeric) from public;
grant execute on function public.reais(numeric) to anon, authenticated;
