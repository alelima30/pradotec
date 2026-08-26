-- ===========================================================================
-- AgendaPro — 12: os relatórios
--
-- O salão já tinha todo o dado e nenhuma resposta. Comanda, item, pagamento e
-- comissão estão gravados desde o começo; o que não existia era a pergunta
-- "quanto eu faturei em outubro e quanto eu devo para a Ana".
--
-- ── POR QUE NO BANCO, E NÃO NO NAVEGADOR ───────────────────────────────────
-- O painel já baixa perto de vinte tabelas ao abrir. Somar o mês no
-- JavaScript exigiria baixar TODO o histórico de comandas do salão — que
-- cresce para sempre — só para mostrar quatro números. Um salão com dois anos
-- de casa passaria minutos carregando para ver o fechamento de um mês.
--
-- Aqui a conta é feita onde o dado mora, e volta um jsonb pequeno.
--
-- ── A REGRA QUE DECIDE TUDO: O QUE CONTA COMO FATURAMENTO ──────────────────
-- Comanda FECHADA, e pela data em que fechou. Não pela data em que abriu.
--
-- Não é detalhe. A comanda abre quando a cliente senta e fecha quando ela
-- paga; abrindo dia 31 e fechando dia 1º, o dinheiro entrou no mês novo. Usar
-- `aberta_em` jogaria a receita para o mês errado, e o dono só descobriria
-- fechando o caixa e não batendo.
--
-- Comanda ABERTA não entra: é atendimento em andamento, não é dinheiro.
-- Comanda CANCELADA também não.
-- ===========================================================================

/* Uma função só, e devolve tudo de uma vez.

   Quatro chamadas separadas — faturamento, comissão, serviços, faltas —
   seriam quatro idas ao servidor para montar UMA tela, e quatro chances de a
   tela mostrar um pedaço do mês e outro pedaço de outro se o dono trocasse o
   período no meio. */
create or replace function public.relatorio(
  p_salao uuid, p_de date, p_ate date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_fuso  text;
  v_ini   timestamptz;
  v_fim   timestamptz;
  v_dias  int;
  v_ini_a timestamptz;   -- o período ANTERIOR, do mesmo tamanho
  v_fim_a timestamptz;
begin
  /* A permissão é de GESTÃO, não de equipe. Faturamento e comissão da casa
     inteira não são assunto da recepção nem de quem atende — e é a mesma
     linha que impede o dono do salão B de ler o mês do salão A trocando o
     uuid na chamada. */
  if not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste salão.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Confira as datas do período.' using errcode = 'check_violation';
  end if;

  select fuso into v_fuso from public.saloes where id = p_salao;
  v_fuso := coalesce(v_fuso, 'America/Sao_Paulo');

  /* O dia do salão, não o dia de quem está olhando. Um dono viajando lê o
     relatório do fuso dele e veria o dia 1º começar às 20h do dia 31. */
  v_ini := (p_de::timestamp) at time zone v_fuso;
  v_fim := ((p_ate + 1)::timestamp) at time zone v_fuso;   -- fim exclusivo

  v_dias  := (p_ate - p_de) + 1;
  v_fim_a := v_ini;
  v_ini_a := v_ini - make_interval(days => v_dias);

  return jsonb_build_object(
    'de',  p_de,
    'ate', p_ate,
    'dias', v_dias,

    -- ── O DINHEIRO ────────────────────────────────────────────────────────
    'faturamento', coalesce((
      select round(sum(t.total), 2) from public.comandas_totais t
        join public.comandas c on c.id = t.id
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim), 0),

    'atendimentos', (
      select count(*) from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim),

    'descontos', coalesce((
      select round(sum(c.desconto), 2) from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim), 0),

    -- O MESMO período, imediatamente antes. É o que transforma "R$ 8.400" em
    -- "R$ 8.400, 12% acima do mês passado" — o número sozinho não diz se o
    -- salão está melhorando.
    'faturamentoAntes', coalesce((
      select round(sum(t.total), 2) from public.comandas_totais t
        join public.comandas c on c.id = t.id
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini_a and c.fechada_em < v_fim_a), 0),

    -- ── COMO ENTROU ───────────────────────────────────────────────────────
    -- A taxa da maquininha vem junto: o salão recebe menos do que a cliente
    -- pagou, e sem isso o "faturamento" mente sobre o que entra na conta.
    'formas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'forma', f.forma, 'valor', f.valor, 'taxa', f.taxa)
             order by f.valor desc)
        from (select pg.forma,
                     round(sum(pg.valor), 2) as valor,
                     round(sum(pg.taxa), 2)  as taxa
                from public.pagamentos pg
                join public.comandas c on c.id = pg.comanda_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by pg.forma) f), '[]'::jsonb),

    -- ── A COMISSÃO, POR PESSOA ────────────────────────────────────────────
    -- O relatório mais pedido de salão, e o que hoje se faz na calculadora
    -- no fim do mês. Sai do item, não da comanda: o corte é do João e a
    -- escova é da Ana, na mesma cliente.
    'comissoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'profissionalId', x.pid, 'nome', x.nome,
               'vendido', x.vendido, 'comissao', x.comissao,
               'itens', x.itens)
             order by x.comissao desc)
        from (select i.profissional_id as pid,
                     coalesce(pr.apelido, pr.nome, 'sem profissional') as nome,
                     round(sum(i.total), 2)          as vendido,
                     round(sum(i.comissao_valor), 2) as comissao,
                     count(*)                        as itens
                from public.comanda_itens i
                join public.comandas c on c.id = i.comanda_id
                left join public.profissionais pr on pr.id = i.profissional_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by i.profissional_id, coalesce(pr.apelido, pr.nome, 'sem profissional')) x),
      '[]'::jsonb),

    -- ── O QUE MAIS SAI ────────────────────────────────────────────────────
    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nome', y.nome, 'qtd', y.qtd, 'valor', y.valor)
             order by y.valor desc)
        from (select i.descricao as nome,
                     round(sum(i.qtd), 2)   as qtd,
                     round(sum(i.total), 2) as valor
                from public.comanda_itens i
                join public.comandas c on c.id = i.comanda_id
               where c.salao_id = p_salao and c.status = 'fechada'
                 and c.fechada_em >= v_ini and c.fechada_em < v_fim
               group by i.descricao
               order by 3 desc limit 12) y), '[]'::jsonb),

    -- ── A AGENDA ──────────────────────────────────────────────────────────
    -- Aqui a data é a do ATENDIMENTO (`inicio`), não a do pagamento: falta é
    -- do dia em que a cadeira ficou parada.
    'agenda', (
      select jsonb_build_object(
        'concluidos', count(*) filter (where a.status = 'concluido'),
        'faltas',     count(*) filter (where a.status = 'faltou'),
        'cancelados', count(*) filter (where a.status = 'cancelado'),
        'marcados',   count(*),
        -- Quanto ficou na mesa: o preço previsto do que faltou e do que
        -- cancelou. É o número que faz o dono decidir se pede sinal.
        'perdido', coalesce(round(sum(a.valor_previsto)
                     filter (where a.status in ('faltou','cancelado')), 2), 0))
        from public.agendamentos a
       where a.salao_id = p_salao
         and a.arquivado_em is null
         and a.inicio >= v_ini and a.inicio < v_fim),

    -- ── QUEM VOLTOU ───────────────────────────────────────────────────────
    -- Cliente nova é a que não tinha atendimento concluído ANTES do período.
    -- É a diferença entre um salão que cresce e um que troca de clientela.
    'clientes', (
      select jsonb_build_object(
        'atendidas', count(distinct c.cliente_id),
        'novas', count(distinct c.cliente_id) filter (
          where not exists (
            select 1 from public.comandas c2
             where c2.cliente_id = c.cliente_id
               and c2.salao_id = p_salao
               and c2.status = 'fechada'
               and c2.fechada_em < v_ini)))
        from public.comandas c
       where c.salao_id = p_salao and c.status = 'fechada'
         and c.fechada_em >= v_ini and c.fechada_em < v_fim)
  );
end $$;

revoke all on function public.relatorio(uuid, date, date) from public;
grant execute on function public.relatorio(uuid, date, date) to authenticated;
