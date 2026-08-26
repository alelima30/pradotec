-- ===========================================================================
-- AgendaPro — 05: a agenda pública
--
-- Este arquivo existe por um motivo só: hoje quem calcula horário livre é o
-- JavaScript de `agendar.html`, contra o localStorage. Isso funciona para
-- conhecer o sistema e não funciona para nada além disso — o link que o dono
-- copia no fim do cadastro abre vazio no celular da cliente, porque o dado
-- mora no navegador dele.
--
-- Aqui a conta passa a ser do banco. Duas funções:
--
--   horarios_livres()  — que horas cabem, para este profissional, neste dia
--   agendar()          — marca, ou explica por que não deu
--
-- ── POR QUE `security definer` ─────────────────────────────────────────────
-- Quem abre o link é `anon`: não fez login, e o RLS não deixa ele chegar em
-- `agendamentos`, `jornadas` nem `bloqueios` — e está certo, porque a lista de
-- clientes do salão não é pública. Mas o horário vago é. Estas funções rodam
-- com o dono delas, olham o que precisam, e devolvem SÓ o horário.
--
-- Toda função aqui leva `set search_path = public`. Sem isso, quem consegue
-- criar uma tabela num schema que venha antes no caminho consegue fazer a
-- função `security definer` ler a tabela dele em vez da nossa.
--
-- ── A REGRA QUE NÃO SE NEGOCIA ─────────────────────────────────────────────
-- A duração e o preço NUNCA vêm do navegador. `agendar()` recebe a LISTA DE
-- SERVIÇOS e soma a duração aqui dentro. Se recebesse `duracao_min`, qualquer
-- pessoa com o console aberto marcaria uma escova de 3 horas ocupando 15
-- minutos da agenda — e a cadeira estaria vendida em dobro no dia seguinte.
-- Mesma coisa com o preço: chega do banco, não do formulário.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Peças pequenas
-- ---------------------------------------------------------------------------

-- Telefone só serve para achar a mesma pessoa de novo se for guardado sempre
-- do mesmo jeito. Existe um índice único em (salao_id, telefone): sem
-- normalizar, "(51) 99887-6655" e "51998876655" viram duas fichas da mesma
-- cliente, e o histórico dela racha no meio.
create or replace function public.so_digitos(p_texto text)
returns text language sql immutable set search_path = public as $$
  select nullif(regexp_replace(coalesce(p_texto, ''), '[^0-9]', '', 'g'), '')
$$;

-- Até quando o salão aceita marcação. Serve para dois problemas reais: quem
-- marca para daqui a seis meses quase sempre falta, e agenda aberta até o
-- infinito tira do dono a liberdade de mudar jornada, preço ou equipe.
create or replace function public.dias_liberados(p_salao uuid)
returns int language sql stable set search_path = public as $$
  select greatest(1, least(365,
    coalesce((select (cfg->>'diasLiberados')::int from public.saloes
               where id = p_salao and cfg->>'diasLiberados' ~ '^[0-9]+$'), 30)))
$$;

-- Hoje NO FUSO DO SALÃO, que não é o fuso de quem está olhando. Uma cliente
-- em Portugal abrindo o link de um salão de Porto Alegre às 3h da manhã dela
-- tem que ver o dia que é lá, não o dela.
create or replace function public.hoje_no_salao(p_salao uuid)
returns date language sql stable set search_path = public as $$
  select (now() at time zone coalesce(
           (select fuso from public.saloes where id = p_salao),
           'America/Sao_Paulo'))::date
$$;

-- ---------------------------------------------------------------------------
-- 2) Quanto tempo leva, quanto custa
--
-- A duração é a soma de `duracao_min + intervalo_min` de cada serviço. O
-- intervalo (arrumar a estação, lavar pincel) conta na agenda mas não aparece
-- para o cliente como parte do serviço — se não contasse, o profissional
-- chegaria atrasado no próximo por construção.
--
-- `servicos_profissionais` pode sobrescrever duração e preço: a Ana faz mecha
-- em 2h, a Bia em 3h. Quando há linha para aquele par, ela manda.
-- ---------------------------------------------------------------------------
create or replace function public.duracao_dos_servicos(
  p_profissional uuid, p_servicos uuid[])
returns int language sql stable set search_path = public as $$
  select coalesce(sum(
           coalesce(sp.duracao_min, s.duracao_min) + s.intervalo_min), 0)::int
    from public.servicos s
    left join public.servicos_profissionais sp
           on sp.servico_id = s.id and sp.profissional_id = p_profissional
   where s.id = any(p_servicos)
$$;

create or replace function public.preco_dos_servicos(
  p_profissional uuid, p_servicos uuid[])
returns numeric language sql stable set search_path = public as $$
  select coalesce(sum(coalesce(sp.preco, s.preco)), 0)::numeric(10,2)
    from public.servicos s
    left join public.servicos_profissionais sp
           on sp.servico_id = s.id and sp.profissional_id = p_profissional
   where s.id = any(p_servicos)
$$;

-- Este profissional faz TODOS estes serviços?
--
-- Sem nenhuma linha em `servicos_profissionais`, considera-se que ele faz
-- tudo. É como um salão pequeno começa — um profissional, cinco serviços,
-- nenhum cruzamento cadastrado — e exigir o cadastro antes de usar é o tipo
-- de exigência que faz o dono desistir na primeira tarde.
create or replace function public.profissional_faz(
  p_profissional uuid, p_servicos uuid[])
returns boolean language sql stable set search_path = public as $$
  select case
    when not exists (select 1 from public.servicos_profissionais
                      where profissional_id = p_profissional) then true
    else not exists (
      select 1 from unnest(p_servicos) as pedido(id)
       where not exists (
         select 1 from public.servicos_profissionais sp
          where sp.profissional_id = p_profissional and sp.servico_id = pedido.id))
  end
$$;

-- ---------------------------------------------------------------------------
-- 3) O salão aceita marcação online agora?
--
-- Uma função só, porque as duas pontas precisam da MESMA resposta.
-- `horarios_livres()` usa para não oferecer, e `agendar()` usa para não
-- aceitar. Se cada uma tivesse a sua cópia da regra, um dia elas discordariam
-- — e o jeito de descobrir seria uma cliente vendo "13:00 disponível" e
-- levando "esse horário não está mais livre" ao clicar.
--
-- Devolve null quando está tudo certo, ou o motivo em português.
-- ---------------------------------------------------------------------------
create or replace function public.porque_nao_agenda(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_salao uuid;
  v_hoje  date;
begin
  if p_servicos is null or cardinality(p_servicos) = 0 then
    return 'Escolha pelo menos um serviço.';
  end if;

  select p.salao_id into v_salao
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional
     and p.ativo and p.aceita_online
     and sa.status = 'ativo';

  if v_salao is null then
    return 'Este profissional não está atendendo pela agenda online.';
  end if;

  -- O profissional existe e está ativo, mas o salão caiu para um plano que
  -- não comporta a equipe inteira. O gatilho de cota recusaria a marcação lá
  -- na frente; melhor não oferecer o horário do que oferecer e voltar atrás.
  if not public.profissional_na_cota(p_profissional) then
    return 'Este profissional não está atendendo pela agenda online.';
  end if;

  if not public.recurso_bool(v_salao, 'agenda_online') then
    return 'Este salão não está aceitando marcação pela internet.';
  end if;

  -- Todo serviço pedido tem que ser deste salão, estar ativo e aceitar
  -- online. Sem esta conferência, dá para marcar um serviço de OUTRO salão
  -- colando o id na chamada — e o preço que entraria na comanda seria o de lá.
  if exists (
    select 1 from unnest(p_servicos) as pedido(id)
     where not exists (
       select 1 from public.servicos s
        where s.id = pedido.id and s.salao_id = v_salao
          and s.ativo and s.aceita_online))
  then
    return 'Um dos serviços escolhidos não está disponível.';
  end if;

  if not public.profissional_faz(p_profissional, p_servicos) then
    return 'Este profissional não faz todos os serviços escolhidos.';
  end if;

  v_hoje := public.hoje_no_salao(v_salao);

  if p_data < v_hoje then
    return 'Essa data já passou.';
  end if;

  if p_data > v_hoje + public.dias_liberados(v_salao) then
    return format('A agenda está liberada até %s.',
                  to_char(v_hoje + public.dias_liberados(v_salao), 'DD/MM/YYYY'));
  end if;

  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 4) horarios_livres()
--
-- Devolve os inícios possíveis, em timestamptz. A tela formata no fuso do
-- salão (que vem em `saloes_publicos.fuso`), não no fuso do aparelho.
--
-- O passo é de 15 minutos e a última vaga é a que ainda TERMINA dentro da
-- jornada: com jornada até 19:00 e serviço de 40 minutos, 18:20 é oferecido e
-- 18:30 não. Duas linhas de jornada no mesmo dia significam almoço no meio, e
-- o laço trata cada uma por vez — por isso o horário do almoço simplesmente
-- não existe na lista, em vez de aparecer e ser recusado depois.
-- ---------------------------------------------------------------------------
create or replace function public.horarios_livres(
  p_profissional uuid, p_data date, p_servicos uuid[])
returns setof timestamptz
language plpgsql stable security definer set search_path = public as $$
declare
  v_salao   uuid;
  v_fuso    text;
  v_duracao int;
  v_passo   constant interval := '15 minutes';
  -- Ninguém quer receber "disponível: daqui a 4 minutos". Meia hora é o
  -- mínimo para a pessoa conseguir sair de casa.
  v_cedo_demais constant interval := '30 minutes';
  j         record;
  v_ini     timestamptz;
  v_fim     timestamptz;
  v_ate     timestamptz;
begin
  if public.porque_nao_agenda(p_profissional, p_data, p_servicos) is not null then
    return;
  end if;

  select p.salao_id, sa.fuso into v_salao, v_fuso
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;

  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  if v_duracao <= 0 then return; end if;

  /* ⚠ AS FAIXAS SÃO COSTURADAS ANTES DE VIRAREM HORÁRIO

     Uma jornada pode estar cadastrada em duas faixas que se cruzam — 08:00
     às 13:00 e 12:00 às 18:00 é erro de digitação comum, e o painel aceita.
     Percorrendo as faixas cruas, o trecho comum saía DUAS VEZES, e a lista
     ainda voltava no tempo: ...12:15, 12:30, 12:00, 12:15... A cliente via
     o mesmo horário repetido e o relógio andando para trás no meio da tela.

     `costurar` funde o que encosta ou se sobrepõe, em ordem. Faixas
     separadas de verdade — manhã e tarde com almoço no meio — continuam
     separadas, que é o certo. */
  for j in
    with cruas as (
      select inicio, fim from public.jornadas
       where profissional_id = p_profissional
         and dia_semana = extract(dow from p_data)::smallint
    ),
    marcadas as (
      select inicio, fim,
             case when inicio <= max(fim) over (
                    order by inicio, fim
                    rows between unbounded preceding and 1 preceding)
                  then 0 else 1 end as nova
        from cruas
    ),
    grupos as (
      select inicio, fim,
             sum(nova) over (order by inicio, fim
                             rows between unbounded preceding and current row) as g
        from marcadas
    )
    select min(inicio) as inicio, max(fim) as fim
      from grupos group by g order by 1
  loop
    -- A hora da jornada é hora de parede ("09:00 de segunda"). Vira instante
    -- no fuso do salão — e é isso que faz a agenda continuar certa na semana
    -- em que o horário de verão muda, porque o salão abre às 9 dos dois lados
    -- da virada, não "9 menos uma hora".
    v_ini := ((p_data + j.inicio) at time zone v_fuso);
    v_ate := ((p_data + j.fim)    at time zone v_fuso);

    while v_ini + make_interval(mins => v_duracao) <= v_ate loop
      v_fim := v_ini + make_interval(mins => v_duracao);

      if v_ini >= now() + v_cedo_demais
         and not exists (
           select 1 from public.agendamentos a
            where a.profissional_id = p_profissional
              and a.status in ('pendente','confirmado','em_atendimento','concluido')
              and tstzrange(a.inicio, a.fim, '[)') && tstzrange(v_ini, v_fim, '[)'))
         and not exists (
           select 1 from public.bloqueios b
            where b.salao_id = v_salao
              and (b.profissional_id = p_profissional or b.profissional_id is null)
              and tstzrange(b.inicio, b.fim, '[)') && tstzrange(v_ini, v_fim, '[)'))
      then
        return next v_ini;
      end if;

      v_ini := v_ini + v_passo;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4.4) O TELEFONE DA FICHA, SÓ EM DÍGITOS
--
-- O painel gravava o telefone do jeito que era digitado — "(11) 98888-7777"
-- — e o caminho da cliente grava por `so_digitos()`. Duas escritas, dois
-- formatos, e dois estragos medidos:
--
--   · A MESMA PESSOA VIRAVA DUAS FICHAS. A ficha é reencontrada pelo
--     telefone, e "(11) 98888-7777" nunca é igual a "11988887777". O
--     histórico da cliente ficava partido em duas.
--
--   · O SEGUNDO CLIENTE SEM TELEFONE NÃO GRAVAVA. Campo vazio virava string
--     vazia, que não é nula, e a trava `ux_cli_tel` é `where telefone is not
--     null`. A recepção recebia "duplicate key value violates unique
--     constraint ux_cli_tel", em inglês, ao cadastrar a segunda pessoa que
--     passou sem deixar número.
--
-- A tela já foi corrigida. Isto arruma o que ficou gravado antes, e a regra
-- passa a valer no banco — que é onde ela não depende de ninguém lembrar.
-- ---------------------------------------------------------------------------

-- String vazia nunca deveria ter entrado: some.
update public.clientes
   set telefone = null
 where telefone is not null
   and public.so_digitos(telefone) is null;

-- A máscara vira dígitos, mas só onde isso não cria choque.
--
-- Dois casos de choque, e os dois são a mesma pessoa em fichas separadas:
-- uma ficha que já tem os dígitos, ou duas mascaradas que limpam para o mesmo
-- número. Juntar fichas é mover agendamento, comanda e histórico de uma para
-- outra, e isso NAO se faz por migração automática — some dinheiro ou some
-- atendimento, e ninguém fica sabendo qual. As que colidem ficam como estão,
-- à espera de o salão decidir qual é qual.
with alvo as (
  select c.id,
         public.so_digitos(c.telefone) as limpo,
         row_number() over (partition by c.salao_id, public.so_digitos(c.telefone)
                            order by c.criado_em, c.id) as ordem
    from public.clientes c
   where c.telefone is not null
     and public.so_digitos(c.telefone) is not null
     and c.telefone <> public.so_digitos(c.telefone)
)
update public.clientes c
   set telefone = a.limpo
  from alvo a
 where c.id = a.id
   and a.ordem = 1
   and not exists (select 1 from public.clientes o
                    where o.salao_id = c.salao_id
                      and o.id <> c.id
                      and o.telefone = a.limpo);

-- E a regra passa a ser do banco.
--
-- `not valid` de propósito: as fichas que colidiram acima continuam com
-- máscara, e validá-las agora derrubaria a instalação inteira por causa de um
-- cadastro antigo. `not valid` recusa toda escrita NOVA fora do formato, que
-- é o que impede o defeito de voltar, e deixa o passado em paz.
do $trava$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'cli_tel_so_digitos'
                    and conrelid = 'public.clientes'::regclass) then
    alter table public.clientes
      add constraint cli_tel_so_digitos
      check (telefone is null or telefone ~ '^[0-9]+$') not valid;
  end if;
end $trava$;

/* ---------------------------------------------------------------------------
   4.5) ficha_do_cliente() — acha a ficha, ou cria

   ⚠ ESTA FUNÇÃO EXISTE PORQUE A MESMA BUSCA ESTAVA ESCRITA TRÊS VEZES

   `agendar()` aqui, `agendar()` de novo no 09_cliente.sql (que substitui
   esta) e `entrar_na_fila()`. Três cópias, e a regra estava errada nas três
   do mesmo jeito — procurava-se a ficha SÓ pelo telefone.

   O estrago: quem já tinha ficha no salão e marcava digitando um número
   diferente do que estava lá (trocou de chip, digitou o do marido, corrigiu
   o DDD) não era encontrado, caía no insert, e o insert batia na trava
   `ux_cli_perfil` — que existe justamente para a mesma pessoa não ter duas
   fichas no mesmo salão. O que a cliente via, no fim de um agendamento
   inteiro preenchido:

       Não consegui marcar.
       duplicate key value violates unique constraint "ux_cli_perfil"

   Erro de banco em inglês na cara de quem só queria marcar horário, e sem
   saída nenhuma: tentar de novo dava o mesmo. O salão perde a marcação e nem
   fica sabendo que perdeu.

   Agora quem está logado é procurado PELO PERFIL primeiro — é a identidade
   que a trava protege. O telefone é o segundo caminho, para quem não tem
   conta. E, corrigido num lugar só, fica corrigido nos três.
   --------------------------------------------------------------------------- */
create or replace function public.ficha_do_cliente(
  p_salao uuid, p_nome text, p_tel text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_perfil  uuid := auth.uid();
  v_cliente uuid;
begin
  if v_perfil is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.perfil_id = v_perfil;
  end if;

  if v_cliente is null and p_tel is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.telefone = p_tel;
  end if;

  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (p_salao, v_perfil, p_nome, p_tel)
      returning clientes.id into v_cliente;
    return v_cliente;
  end if;

  /* Reencontrou a ficha. Só preenche o que falta: sobrescrever o nome
     apagaria a correção que a recepção fez na ficha.

     O telefone novo entra apenas se ninguém mais o tiver neste salão — a
     outra trava, `ux_cli_tel`, derrubaria a marcação inteira, e a pessoa
     está aqui para marcar horário, não para arrumar cadastro. Na dúvida fica
     o que já estava, e o salão conserta pelo painel. */
  update public.clientes c
     set perfil_id = coalesce(c.perfil_id, v_perfil),
         telefone  = case
           when p_tel is null or p_tel = c.telefone then c.telefone
           when exists (select 1 from public.clientes o
                         where o.salao_id = p_salao
                           and o.telefone = p_tel
                           and o.id <> c.id) then c.telefone
           else p_tel end
   where c.id = v_cliente;

  return v_cliente;
end $$;

-- ---------------------------------------------------------------------------
-- 5) agendar()
--
-- Marca de verdade. Recebe a lista de serviços, nunca a duração nem o preço.
--
-- Quem chama é `anon` (cliente sem login) ou `authenticated` (cliente com
-- conta). Nos dois casos a ficha do cliente sai de `ficha_do_cliente()`, que
-- procura pelo perfil de quem está logado antes de procurar pelo telefone.
-- ---------------------------------------------------------------------------
/* ⚠ O DROP É O QUE FAZ ESTE ARQUIVO PODER RODAR DUAS VEZES

   O 09_cliente.sql substitui esta função por uma que devolve o `token` de
   gerenciamento — uma coluna a mais no retorno. E `create or replace` NÃO
   muda tipo de retorno: ele recusa com

       cannot change return type of existing function

   Então, num banco que já foi instalado, a SEGUNDA passada do 00_tudo.sql
   morria aqui — no 05, tentando rebaixar a função de volta à versão sem
   token. O arquivo que promete "pode rodar quantas vezes quiser" quebrava na
   segunda, e a mensagem falava de tipo de retorno, que não diz nada para
   quem só colou o arquivo de novo.

   Com o drop, a segunda passada derruba a versão do 09, recria esta, e o 09
   logo em seguida põe a dele de volta. Ordem preservada, resultado idêntico. */
drop function if exists public.agendar(uuid, timestamptz, uuid[], text, text, text, text);
create or replace function public.agendar(
  p_profissional  uuid,
  p_inicio        timestamptz,
  p_servicos      uuid[],
  p_nome          text,
  p_telefone      text,
  p_atendido_nome text default null,
  p_obs           text default null)
returns table (id uuid, inicio timestamptz, fim timestamptz, valor numeric)
language plpgsql security definer set search_path = public as $$
declare
  v_salao    uuid;
  v_fuso     text;
  v_data     date;
  v_motivo   text;
  v_duracao  int;
  v_tel      text;
  v_nome     text;
  v_cliente  uuid;
  v_perfil   uuid;
  v_agend    uuid;
  v_fim      timestamptz;
  v_valor    numeric(10,2);
  v_abertos  int;
  v_ordem    smallint := 1;
  s          record;
begin
  v_nome := nullif(btrim(coalesce(p_nome, '')), '');
  v_tel  := public.so_digitos(p_telefone);

  if v_nome is null then
    raise exception 'Diga seu nome para a gente saber quem esperar.'
      using errcode = 'check_violation';
  end if;

  -- 10 dígitos = fixo com DDD, 11 = celular. Abaixo disso é engano de
  -- digitação, e telefone errado é agendamento que vira falta: ninguém
  -- consegue avisar a pessoa de nada.
  if v_tel is null or length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'Confira o telefone: precisa do DDD.'
      using errcode = 'check_violation';
  end if;

  select p.salao_id, sa.fuso into v_salao, v_fuso
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.id = p_profissional;

  if v_salao is null then
    raise exception 'Este profissional não está atendendo pela agenda online.'
      using errcode = 'check_violation';
  end if;

  v_data := (p_inicio at time zone v_fuso)::date;

  -- A MESMA função que decidiu o que mostrar decide o que aceitar. Ninguém
  -- passa por aqui só porque montou a chamada na mão.
  v_motivo := public.porque_nao_agenda(p_profissional, v_data, p_servicos);
  if v_motivo is not null then
    raise exception '%', v_motivo using errcode = 'check_violation';
  end if;

  -- E o horário pedido tem que ser um dos que a função oferece. Isto fecha de
  -- uma vez o encaixe fora da jornada, o horário no meio do almoço, o que já
  -- está ocupado, o que cai em bloqueio e o "daqui a 4 minutos" — sem repetir
  -- nenhuma dessas regras aqui, que é como elas acabariam divergindo.
  if not exists (
    select 1 from public.horarios_livres(p_profissional, v_data, p_servicos) h
     where h = p_inicio)
  then
    raise exception 'Esse horário não está mais livre. Escolha outro, por favor.'
      using errcode = 'check_violation';
  end if;

  v_duracao := public.duracao_dos_servicos(p_profissional, p_servicos);
  v_valor   := public.preco_dos_servicos(p_profissional, p_servicos);
  v_fim     := p_inicio + make_interval(mins => v_duracao);

  -- A ficha do cliente. A regra inteira mora em `ficha_do_cliente()` — as
  -- três funções que precisam dela chamam a mesma, e é por isso que ela
  -- existe (ver o comentário lá em cima).
  v_cliente := public.ficha_do_cliente(v_salao, v_nome, v_tel);

  -- ── Freio de spam ────────────────────────────────────────────────────────
  -- Marcação online sem senha é um formulário aberto na internet. Sem limite,
  -- um número só entope a agenda inteira de um salão em dois minutos — e o
  -- prejuízo é do dono, que passa o dia ligando para horários fantasma.
  --
  -- Três marcações futuras em aberto atende a cliente de verdade (o corte
  -- desta semana, a escova do casamento, a manutenção do mês) e trava quem
  -- está brincando. Cancelou ou foi atendida, libera vaga na conta.
  select count(*) into v_abertos from public.agendamentos a
   where a.cliente_id = v_cliente
     and a.status in ('pendente','confirmado')
     and a.inicio > now();

  if v_abertos >= 3 then
    raise exception 'Você já tem 3 horários marcados aqui. Cancele um antes de marcar outro.'
      using errcode = 'check_violation';
  end if;

  -- ── A marcação ───────────────────────────────────────────────────────────
  begin
    insert into public.agendamentos
      (salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
       valor_previsto, atendido_nome, obs, criado_por)
    values
      (v_salao, v_cliente, p_profissional, p_inicio, v_fim, 'confirmado', 'online',
       v_valor, nullif(btrim(coalesce(p_atendido_nome, '')), ''),
       nullif(btrim(coalesce(p_obs, '')), ''), v_perfil)
    returning agendamentos.id into v_agend;
  exception
    -- Duas pessoas clicando no mesmo horário no mesmo segundo. A função de
    -- horários livres viu vago para as duas; quem separa é a trava do banco,
    -- e a segunda chega aqui. O erro cru do Postgres fala em "conflicting key
    -- value violates exclusion constraint" — a cliente merece outra frase.
    when exclusion_violation then
      raise exception 'Alguém acabou de marcar esse horário. Escolha outro, por favor.'
        using errcode = 'check_violation';
  end;

  -- Duração, preço e comissão são COPIADOS agora. Se o salão reajustar a
  -- tabela amanhã, o que foi combinado com a cliente hoje continua valendo —
  -- e a comissão do profissional é calculada sobre o combinado, não sobre o
  -- preço novo.
  for s in
    select sv.id, coalesce(sp.duracao_min, sv.duracao_min) + sv.intervalo_min as dur,
           coalesce(sp.preco, sv.preco) as preco,
           coalesce(sv.comissao_pct, pr.comissao_pct, 0) as com
      from unnest(p_servicos) with ordinality as pedido(id, pos)
      join public.servicos sv on sv.id = pedido.id
      join public.profissionais pr on pr.id = p_profissional
      left join public.servicos_profissionais sp
             on sp.servico_id = sv.id and sp.profissional_id = p_profissional
     order by pedido.pos
  loop
    insert into public.agendamento_servicos
      (agendamento_id, servico_id, ordem, duracao_min, preco, comissao_pct)
    values (v_agend, s.id, v_ordem, s.dur, s.preco, s.com);
    v_ordem := v_ordem + 1;
  end loop;

  return query select v_agend, p_inicio, v_fim, v_valor;
end $$;

-- ---------------------------------------------------------------------------
-- 5b) horarios_livres_periodo() — a mesma resposta, para a tela inteira
--
-- ── POR QUE UMA SEGUNDA FUNÇÃO EM VEZ DE CHAMAR A PRIMEIRA VÁRIAS VEZES ────
-- A tela da cliente não mostra um dia: mostra a faixa de dias com "12 vagas",
-- "3 vagas", "cheio" embaixo de cada um, e ainda o cartão "próximo horário
-- disponível". Para desenhar isso ela precisa saber de TODOS os dias da
-- janela, para TODOS os profissionais que fazem os serviços escolhidos.
--
-- Rodando na memória do navegador, como era antes, isso é um laço bobo. Vindo
-- do banco, cada volta desse laço é uma viagem até o servidor: 28 dias × 3
-- profissionais = 84 requisições para pintar uma tela. No 3G da cliente, com
-- 300 ms cada, são 25 segundos olhando para uma tela cinza — e ela fecha
-- antes, que é o único desfecho que interessa medir.
--
-- Então o banco responde a pergunta inteira de uma vez. Por dentro é a mesma
-- `horarios_livres()`, chamada em laço aqui, onde o laço custa microssegundos:
-- uma única fonte da verdade sobre o que é um horário livre. Se um dia a regra
-- mudar — passo de 20 minutos, antecedência de uma hora — muda num lugar só, e
-- as duas mudam juntas. Duplicar a lógica aqui seria pedir para as duas
-- discordarem justamente no dia em que alguém marcasse em cima de outro.
--
-- A duração continua saindo dos SERVIÇOS, nunca do navegador: quem chama
-- manda a lista de ids, e a soma acontece lá dentro.
-- ---------------------------------------------------------------------------
create or replace function public.horarios_livres_periodo(
  p_profissionais uuid[], p_de date, p_ate date, p_servicos uuid[])
returns table (profissional_id uuid, inicio timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  v_dia   date;
  v_prof  uuid;
  -- Teto de segurança. A janela que a tela pede é de 28 dias; 62 dá folga
  -- para relatório e para o dia em que alguém aumentar a janela do salão,
  -- sem deixar uma chamada de fora pedir dois anos de agenda de uma vez.
  v_ate   date := least(p_ate, p_de + 62);
begin
  if p_de is null or p_ate is null or v_ate < p_de then return; end if;

  foreach v_prof in array coalesce(p_profissionais, '{}'::uuid[]) loop
    v_dia := p_de;
    while v_dia <= v_ate loop
      return query
        select v_prof, h
          from public.horarios_livres(v_prof, v_dia, p_servicos) h;
      v_dia := v_dia + 1;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6) Quem pode chamar
--
-- `anon` precisa das duas: a cliente que abre o link não fez login, e obrigar
-- cadastro antes de marcar é o jeito mais rápido de perder a marcação.
--
-- Note que `anon` continua SEM chegar em `agendamentos`, `clientes`,
-- `jornadas` e `bloqueios` — o grant é da função, não das tabelas. Ele
-- consegue marcar e consegue ver horário vago; não consegue ler a agenda do
-- salão nem a lista de clientes.
-- ---------------------------------------------------------------------------
/* ⚠ `ficha_do_cliente()` NÃO é para ser chamada de fora. Ela é `security
   definer` e escreve em `clientes`: solta, deixaria qualquer visitante criar
   e alterar ficha em QUALQUER salão, inclusive tomar um telefone de outra
   pessoa. Postgres dá execute ao público em toda função nova, então tirar é
   obrigatório — ela existe só para `agendar()` e `entrar_na_fila()`, que já
   conferem tudo antes de chegar nela. */
revoke all on function public.ficha_do_cliente(uuid, text, text) from public;

revoke all on function public.horarios_livres(uuid, date, uuid[]) from public;
revoke all on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  from public;
revoke all on function public.porque_nao_agenda(uuid, date, uuid[]) from public;

revoke all on function public.horarios_livres_periodo(uuid[], date, date, uuid[])
  from public;

grant execute on function public.horarios_livres(uuid, date, uuid[])
  to anon, authenticated;
grant execute on function public.horarios_livres_periodo(uuid[], date, date, uuid[])
  to anon, authenticated;
grant execute on function public.agendar(uuid, timestamptz, uuid[], text, text, text, text)
  to anon, authenticated;
grant execute on function public.porque_nao_agenda(uuid, date, uuid[])
  to anon, authenticated;
grant execute on function public.dias_liberados(uuid)   to anon, authenticated;
grant execute on function public.hoje_no_salao(uuid)    to anon, authenticated;
grant execute on function public.so_digitos(text)       to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7) Conserto na vitrine pública
--
-- `profissionais_publicos` mostrava todo profissional ativo que aceita
-- online, sem olhar a cota do plano. O salão que caiu do plano de 5 para o
-- gratuito continuava com os 5 na tela: a cliente escolhia a Bia, e o gatilho
-- de cota recusava na hora de marcar. Erro do lado errado do funil.
-- ---------------------------------------------------------------------------
create or replace view public.profissionais_publicos as
  select p.id, p.salao_id, coalesce(p.apelido, p.nome) as nome, p.foto,
         array(select sp.servico_id from public.servicos_profissionais sp
                where sp.profissional_id = p.id) as servicos
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.ativo and p.aceita_online and sa.status = 'ativo'
     and public.profissional_na_cota(p.id);

-- ---------------------------------------------------------------------------
-- E ESTA VISTA NÃO RECEBE PERMISSÃO AQUI
--
-- Havia, nesta linha, um `grant select on public.profissionais_publicos to
-- anon, authenticated`. O 06_vitrine.sql revoga a mesma coisa, então na
-- instalação completa o resultado saía certo — 06 roda depois de 05 — e a
-- contradição passava despercebida.
--
-- Só que "certo porque roda na ordem" não sobrevive a reaplicar só este
-- arquivo, que é o que se faz ao mexer numa função da agenda. Medido: `anon`
-- volta a ler a vista, e uma requisição sem filtro devolve TODOS os
-- profissionais de TODOS os salões, com o salao_id de cada um. É a mesma
-- enumeração da carteira de clientes que o 06 existe para fechar, entrando
-- por outra porta.
--
-- É o gêmeo do defeito que o 02_rls.sql tinha. Quem manda nas três vistas
-- públicas é o 06, sozinho — inclusive nesta.
-- ---------------------------------------------------------------------------
