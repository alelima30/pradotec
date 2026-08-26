-- ===========================================================================
-- AgendaPro — 14: o motor da disponibilidade
--
-- ── O PROBLEMA QUE ESTE ARQUIVO RESOLVE ────────────────────────────────────
-- Existiam DOIS caminhos de escrita em `agendamentos`, e eles não passavam
-- pela mesma porta:
--
--   a cliente   → agendar(), que revalida jornada, bloqueio, conflito
--   a recepção  → INSERT direto pelo PostgREST
--
-- O segundo passava por RLS, pela trava anti-choque e pelos gatilhos de
-- bloqueio — mas NÃO por jornada. Medido antes de escrever este arquivo: o
-- banco aceitou um agendamento às 03:00 num profissional com jornada das
-- 09:00 às 18:00.
--
-- A jornada era, na prática, um aviso de tela. E aviso de tela não é regra:
-- some quando alguém chama a API direto, quando o JavaScript falha, ou
-- quando a pessoa simplesmente clica em salvar depois de ler o aviso.
--
-- ── A SOLUÇÃO: UMA PERGUNTA, DUAS FORMAS ───────────────────────────────────
-- `horarios_livres()` já era quase o motor central. Mas ela responde só a
-- pergunta da CLIENTE:
--
--     "quais horários servem?"
--
-- A recepção faz a outra, e ninguém respondia:
--
--     "este intervalo exato serve — e se não serve, POR QUÊ?"
--
-- É `porque_nao_cabe()`. As duas passam a compartilhar os mesmos auxiliares,
-- então não existe como uma conhecer uma regra que a outra desconhece.
--
-- ── O ENCAIXE DEIXA DE SER UM BURACO E VIRA UMA COLUNA ─────────────────────
-- Encaixar fora da jornada é legítimo: é o que salva o dia num salão. O que
-- não pode é o encaixe deliberado e o erro de digitação entrarem no banco
-- exatamente iguais, sem ninguém saber qual foi qual.
--
-- Agora o gatilho recusa fora da jornada, A NÃO SER que a linha diga
-- explicitamente que é encaixe e quem autorizou. A exceção passou a ter nome,
-- dono e registro.
--
-- ⚠ E o encaixe NÃO fura bloqueio nem choque de horário. Ele afrouxa só a
-- jornada. Bloqueio continua sendo recusado pelo `tg_agend_vs_bloqueio`, e
-- dois atendimentos em cima um do outro continuam sendo recusados pela
-- `agenda_sem_choque` — que são gatilho e constraint separados, e continuam
-- valendo por cima disto aqui.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) A EXCEÇÃO COM NOME
-- ---------------------------------------------------------------------------
alter table public.agendamentos
  add column if not exists encaixe boolean not null default false;

-- Quem autorizou. Sem isto o encaixe seria anônimo, e "quem marcou fora da
-- jornada da Ana?" é exatamente a pergunta que se faz quando dá errado.
alter table public.agendamentos
  add column if not exists encaixe_por uuid references public.perfis(id)
    on delete set null;

comment on column public.agendamentos.encaixe is
  'Marcado fora da jornada, com confirmação explícita de quem tem acesso ao salão.';

-- ---------------------------------------------------------------------------
-- 2) OS AUXILIARES COMPARTILHADOS
--
-- Tudo o que decide disponibilidade mora aqui, e só aqui. `horarios_livres()`
-- e `porque_nao_cabe()` são duas leituras destes mesmos quatro auxiliares.
-- ---------------------------------------------------------------------------

/* A jornada do dia, já costurada e já em instante.

   ⚠ COSTURADA porque uma jornada pode estar cadastrada em faixas que se
   cruzam — 08:00–13:00 e 12:00–18:00 é erro de digitação comum, e o painel
   aceita. Percorrendo as faixas cruas, o trecho comum saía DUAS VEZES e a
   lista de horários voltava no tempo: ...12:15, 12:30, 12:00, 12:15...

   Faixas separadas de verdade — manhã e tarde, com almoço no meio —
   continuam separadas. É por isso que o horário do almoço simplesmente não
   existe na lista, em vez de aparecer e ser recusado depois.

   ⚠ E EM INSTANTE porque a hora da jornada é hora de parede ("09:00 de
   segunda"). Convertida no fuso do salão, a agenda continua certa na semana
   em que o horário de verão muda: o salão abre às 9 dos dois lados da
   virada, não "9 menos uma hora". */
create or replace function public.jornada_costurada(
  p_profissional uuid, p_data date)
returns table (inicio timestamptz, fim timestamptz)
language sql stable security definer set search_path = public as $$
  with fuso as (
    select coalesce(sa.fuso, 'America/Sao_Paulo') as z
      from public.profissionais p
      join public.saloes sa on sa.id = p.salao_id
     where p.id = p_profissional
  ),
  cruas as (
    select j.inicio, j.fim from public.jornadas j
     where j.profissional_id = p_profissional
       and j.dia_semana = extract(dow from p_data)::smallint
  ),
  marcadas as (
    select c.inicio, c.fim,
           case when c.inicio <= max(c.fim) over (
                  order by c.inicio, c.fim
                  rows between unbounded preceding and 1 preceding)
                then 0 else 1 end as nova
      from cruas c
  ),
  grupos as (
    select m.inicio, m.fim,
           sum(m.nova) over (order by m.inicio, m.fim
                             rows between unbounded preceding and current row) as g
      from marcadas m
  )
  select ((p_data + min(gr.inicio)) at time zone f.z),
         ((p_data + max(gr.fim))    at time zone f.z)
    from grupos gr cross join fuso f
   group by gr.g, f.z
   order by 1;
$$;

/* O intervalo inteiro cabe DENTRO de uma faixa da jornada?

   Repare no `<=` do fim: a última vaga é a que ainda TERMINA dentro da
   jornada. Com jornada até 19:00 e serviço de 40 minutos, 18:20 cabe e 18:30
   não. Conferir só o início deixaria o serviço terminar depois de fechar —
   que é o TESTE 2 da especificação, e o erro mais comum deste tipo de
   sistema.

   ── ⚠ SEM JORNADA NENHUMA CADASTRADA, A REGRA NÃO SE APLICA ────────────────
   A primeira versão desta função recusava tudo quando não havia jornada — e
   quem pegou foi um teste que já existia, na primeira execução.

   Recusar parece o lado seguro e é o errado. Um salão que acabou de se
   cadastrar tem profissional e não tem jornada: a tela de jornada é outro
   passo. Com a regra estrita, ele não conseguiria marcar NADA no primeiro
   dia — e leria isso como "o sistema não me deixa trabalhar", que é o
   momento exato em que se desiste de um produto novo.

   A distinção que importa não é "tem faixa hoje?", é "esta pessoa tem jornada
   configurada em ALGUM dia?":

     nenhuma linha em lugar nenhum  →  não configurado, a regra não vale
     linhas em outros dias, hoje não  →  hoje é FOLGA, e folga se respeita

   E o buraco que isso deixa é pequeno de propósito: o link público continua
   não oferecendo horário nenhum para quem não tem jornada (é
   `horarios_livres()` devolvendo vazio), então a pressão para preencher
   continua existindo — do lado certo, que é o da cliente que não consegue
   marcar sozinha. */
create or replace function public.cabe_na_jornada(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.jornadas
                      where profissional_id = p_profissional)
      or exists (
    select 1 from public.jornada_costurada(
                    p_profissional,
                    (p_inicio at time zone coalesce(
                       (select sa.fuso from public.profissionais p
                          join public.saloes sa on sa.id = p.salao_id
                         where p.id = p_profissional), 'America/Sao_Paulo'))::date) j
     where p_inicio >= j.inicio and p_fim <= j.fim);
$$;

create or replace function public.ha_bloqueio(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz)
returns text
language sql stable security definer set search_path = public as $$
  select coalesce(b.motivo, 'bloqueado')
    from public.bloqueios b
    join public.profissionais p on p.id = p_profissional
   where b.salao_id = p.salao_id
     -- profissional_id nulo = bloqueio do salão inteiro (feriado, reforma)
     and (b.profissional_id = p_profissional or b.profissional_id is null)
     and tstzrange(b.inicio, b.fim, '[)') && tstzrange(p_inicio, p_fim, '[)')
   limit 1;
$$;

/* Devolve o agendamento que atrapalha, ou null.

   `p_ignorar` é o id de quem está sendo remarcado — senão o atendimento
   conflitaria consigo mesmo e nunca daria para mudar a observação de um
   horário sem mudar o horário.

   Os mesmos quatro estados da trava `agenda_sem_choque`, e pelo mesmo
   motivo: cancelado e faltou liberam a cadeira, arquivado também. */
create or replace function public.ha_choque(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns uuid
language sql stable security definer set search_path = public as $$
  select a.id from public.agendamentos a
   where a.profissional_id = p_profissional
     and a.status in ('pendente','confirmado','em_atendimento','concluido')
     and a.arquivado_em is null
     and (p_ignorar is null or a.id <> p_ignorar)
     and tstzrange(a.inicio, a.fim, '[)') && tstzrange(p_inicio, p_fim, '[)')
   limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 3) A PERGUNTA DA RECEPÇÃO
--
-- Devolve o MOTIVO, em português, ou null quando cabe. O motivo é o produto
-- desta função: "não deu" manda a pessoa adivinhar, e adivinhar no balcão com
-- a cliente esperando é o que faz o salão desistir do sistema.
--
-- A ordem das conferências não é aleatória — é da mais barata para a mais
-- cara, e da mais provável para a menos provável.
-- ---------------------------------------------------------------------------
create or replace function public.porque_nao_cabe(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_prof   record;
  v_motivo text;
  v_outro  uuid;
  v_fuso   text;
begin
  if p_inicio is null or p_fim is null or p_fim <= p_inicio then
    return 'Confira o horário: o fim tem que ser depois do início.';
  end if;

  select p.id, p.nome, p.ativo, sa.fuso, sa.status as status_salao
    into v_prof
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;

  if v_prof.id is null then
    return 'Profissional não encontrado.';
  end if;
  if not v_prof.ativo then
    return format('%s está desativado(a) na equipe.', v_prof.nome);
  end if;
  if v_prof.status_salao <> 'ativo' then
    return 'Este salão está suspenso.';
  end if;

  v_fuso := coalesce(v_prof.fuso, 'America/Sao_Paulo');

  -- Choque primeiro: é o mais provável no dia a dia e o mais fácil de
  -- entender, e a mensagem consegue dizer COM QUEM está o horário.
  v_outro := public.ha_choque(p_profissional, p_inicio, p_fim, p_ignorar);
  if v_outro is not null then
    return (select format('%s já tem %s das %s às %s.',
              v_prof.nome,
              coalesce(c.nome, 'um atendimento'),
              to_char(a.inicio at time zone v_fuso, 'HH24:MI'),
              to_char(a.fim    at time zone v_fuso, 'HH24:MI'))
              from public.agendamentos a
              left join public.clientes c on c.id = a.cliente_id
             where a.id = v_outro);
  end if;

  v_motivo := public.ha_bloqueio(p_profissional, p_inicio, p_fim);
  if v_motivo is not null then
    return format('Horário bloqueado na agenda de %s: %s.', v_prof.nome, v_motivo);
  end if;

  -- Por último a jornada, que é a única que o encaixe pode afrouxar. Vem no
  -- fim de propósito: assim, quando a tela oferecer o encaixe, ela já sabe
  -- que não há choque nem bloqueio por baixo.
  if not public.cabe_na_jornada(p_profissional, p_inicio, p_fim) then
    return format('Fora da jornada de %s neste dia.', v_prof.nome);
  end if;

  return null;
end $$;

/* O mesmo, mas dizendo se dá para encaixar.

   A tela precisa das duas informações juntas: o motivo, e se aquele motivo é
   contornável. Fora da jornada, sim — é encaixe. Choque e bloqueio, não:
   nesses a resposta é "escolha outro horário", e oferecer um botão de
   encaixe ali seria oferecer um botão que o banco vai recusar. */
create or replace function public.avaliar_horario(
  p_profissional uuid, p_inicio timestamptz, p_fim timestamptz,
  p_ignorar uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_motivo text;
begin
  v_motivo := public.porque_nao_cabe(p_profissional, p_inicio, p_fim, p_ignorar);
  if v_motivo is null then
    return jsonb_build_object('cabe', true);
  end if;
  return jsonb_build_object(
    'cabe', false,
    'motivo', v_motivo,
    -- Só a jornada é contornável. As outras duas o encaixe não fura.
    'encaixavel',
      public.ha_choque(p_profissional, p_inicio, p_fim, p_ignorar) is null
      and public.ha_bloqueio(p_profissional, p_inicio, p_fim) is null);
end $$;

-- ---------------------------------------------------------------------------
-- 4) O GATILHO — ONDE A REGRA DEIXA DE SER SUGESTÃO
--
-- ⚠ TRÊS DECISÕES QUE PARECEM DETALHE E NÃO SÃO:
--
-- 1. Em UPDATE, só revalida quando o INTERVALO ou a PESSOA mudam.
--    Sem isto, todo agendamento que hoje está fora da jornada — e existem,
--    porque até agora nada impedia — ficaria impossível de concluir, cancelar
--    ou marcar como falta. A recepção não conseguiria fechar o dia. A regra
--    nova vale para marcação nova e para remarcação, não para o passado.
--
-- 2. `encaixe` pula a conferência, mas não pula os outros dois guardas.
--    Bloqueio (`tg_agend_vs_bloqueio`) e choque (`agenda_sem_choque`) são
--    gatilho e constraint separados: continuam valendo por cima.
--
-- 3. Estado que não ocupa a cadeira sai fora.
--    Cancelado, faltou e arquivado não precisam caber em jornada nenhuma —
--    são exatamente os estados que LIBERAM o horário.
-- ---------------------------------------------------------------------------
create or replace function public.checar_cabe_agendamento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_motivo text;
begin
  if new.status not in ('pendente','confirmado','em_atendimento','concluido')
     or new.arquivado_em is not null then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.inicio = old.inicio
     and new.fim = old.fim
     and new.profissional_id = old.profissional_id then
    return new;
  end if;

  if new.encaixe then
    return new;
  end if;

  v_motivo := public.porque_nao_cabe(
    new.profissional_id, new.inicio, new.fim, new.id);

  if v_motivo is not null then
    raise exception '%', v_motivo using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists tg_agend_cabe on public.agendamentos;
create trigger tg_agend_cabe
  before insert or update of inicio, fim, profissional_id, status, encaixe
  on public.agendamentos
  for each row execute function public.checar_cabe_agendamento();

-- ---------------------------------------------------------------------------
-- 5) horarios_livres(), REESCRITA SOBRE OS MESMOS AUXILIARES
--
-- O corpo encolheu porque a costura da jornada saiu daqui e virou
-- `jornada_costurada()`. O comportamento é o mesmo, de propósito: esta função
-- já estava certa. O que mudou é que agora ela e `porque_nao_cabe()` leem a
-- MESMA jornada, o MESMO bloqueio e o MESMO choque.
--
-- Passo de 15 minutos, e a última vaga é a que ainda termina dentro da
-- jornada.
-- ---------------------------------------------------------------------------
create or replace function public.horarios_livres(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns setof timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_duracao int;
  v_passo   constant interval := '15 minutes';
  -- Ninguém quer receber "disponível: daqui a 4 minutos". Meia hora é o
  -- mínimo para a pessoa conseguir sair de casa.
  v_cedo_demais constant interval := '30 minutes';
  j         record;
  v_ini     timestamptz;
  v_fim     timestamptz;
begin
  -- As regras de POLÍTICA da agenda online (aceita online, cota do plano,
  -- dias liberados, serviço deste salão) continuam onde estavam. Elas são
  -- diferentes das regras FÍSICAS de disponibilidade, e misturar as duas faria
  -- a recepção herdar limites que são do link público.
  if public.porque_nao_agenda(p_profissional, p_data, p_servicos) is not null then
    return;
  end if;

  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  if v_duracao <= 0 then return; end if;

  for j in select * from public.jornada_costurada(p_profissional, p_data) loop
    v_ini := j.inicio;
    while v_ini + make_interval(mins => v_duracao) <= j.fim loop
      v_fim := v_ini + make_interval(mins => v_duracao);

      if v_ini >= now() + v_cedo_demais
         and public.ha_choque(p_profissional, v_ini, v_fim) is null
         and public.ha_bloqueio(p_profissional, v_ini, v_fim) is null
      then
        return next v_ini;
      end if;

      v_ini := v_ini + v_passo;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6) Quem pode chamar
--
-- Os auxiliares são `security definer` e leem jornada e bloqueio, que são
-- assunto interno do salão. Ficam fechados: quem os alcança são as duas
-- funções de cima.
--
-- `avaliar_horario` e `porque_nao_cabe` vão para `authenticated` — é o painel
-- perguntando antes de gravar. Não para `anon`: a jornada de trabalho e a
-- folga médica da equipe não são assunto de quem só abriu o link.
-- ---------------------------------------------------------------------------
revoke all on function public.jornada_costurada(uuid, date) from public, anon, authenticated;
revoke all on function public.cabe_na_jornada(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ha_bloqueio(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ha_choque(uuid, timestamptz, timestamptz, uuid) from public, anon, authenticated;

revoke all on function public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid) from public;
revoke all on function public.avaliar_horario(uuid, timestamptz, timestamptz, uuid) from public;
grant execute on function public.porque_nao_cabe(uuid, timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.avaliar_horario(uuid, timestamptz, timestamptz, uuid) to authenticated;
