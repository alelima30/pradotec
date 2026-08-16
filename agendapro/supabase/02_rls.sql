-- ===========================================================================
-- AgendaPro — 02_rls.sql
-- A segurança de verdade. Rodar DEPOIS do 01_schema.sql.
--
-- Mesma filosofia do AdminPro: quem protege o dado não é o JavaScript da
-- página, é a regra dentro do banco. O Supabase expõe uma API REST pública
-- sobre estas tabelas — qualquer pessoa com a chave anônima (que está no HTML,
-- e tudo bem) pode chamar direto do navegador, sem passar pela nossa tela.
-- Se o RLS deixar, o dado sai.
--
-- A mudança em relação ao AdminPro: lá a pergunta era "qual é o seu
-- condomínio?", uma coluna só. Aqui é "você tem vínculo com ESTE salão, e em
-- que papel?" — porque a mesma pessoa pode ser cliente em um e profissional
-- em outro.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) AS PERGUNTAS QUE AS POLICIES FAZEM
--
-- Todas são `security definer` porque precisam ler `vinculos` — e `vinculos`
-- também tem RLS. Sem definer, a função cairia na própria regra que ela existe
-- para responder (recursão infinita, erro na primeira consulta).
-- `set search_path = public` fecha a porta de sequestro de nome de tabela.
-- ---------------------------------------------------------------------------

create or replace function public.is_super() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select super_admin from public.perfis where id = auth.uid()), false)
$$;

-- Papel mais alto que a pessoa tem neste salão. Null = nenhum vínculo ativo.
create or replace function public.papel_no_salao(p_salao uuid) returns text
language sql stable security definer set search_path = public as $$
  select papel
    from public.vinculos
   where perfil_id = auth.uid()
     and salao_id  = p_salao
     and status    = 'ativo'
   order by array_position(
     array['dono','admin','recepcao','profissional','cliente'], papel)
   limit 1
$$;

create or replace function public.tem_acesso(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) is not null
$$;

-- Equipe = trabalha no salão. Cliente NÃO é equipe.
create or replace function public.e_equipe(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super()
      or papel_no_salao(p_salao) in ('dono','admin','recepcao','profissional')
$$;

-- Quem manda: mexe em serviço, preço, profissional e comissão.
create or replace function public.e_gestor(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) in ('dono','admin')
$$;

-- Recepção e gestão veem a agenda inteira; profissional vê a dele.
create or replace function public.ve_agenda_toda(p_salao uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_super() or papel_no_salao(p_salao) in ('dono','admin','recepcao')
$$;

-- A ficha DESTA pessoa NESTE salão. É o que amarra o cliente logado aos
-- próprios agendamentos, sem deixá-lo perto dos agendamentos dos outros.
create or replace function public.meu_cliente_id(p_salao uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.clientes
   where salao_id = p_salao and perfil_id = auth.uid()
   limit 1
$$;

-- O profissional logado, dentro deste salão.
create or replace function public.meu_profissional_id(p_salao uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.profissionais
   where salao_id = p_salao and perfil_id = auth.uid() and ativo
   limit 1
$$;

-- ── Três atalhos para a comanda, e o motivo de existirem ──────────────────
--
-- A policy de `comandas` precisa saber se o profissional tem item nela; a de
-- `comanda_itens` precisa saber de que salão é a comanda. Escritas como
-- subconsulta comum, uma dispara a policy da outra e o Postgres para com
-- "infinite recursion detected in policy" — foi o que aconteceu aqui.
--
-- Sendo `security definer`, estas funções não passam pelo RLS, e o ciclo se
-- rompe. São de leitura e devolvem um dado só, então não abrem porta nenhuma.
create or replace function public.salao_da_comanda(p_comanda uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select salao_id from public.comandas where id = p_comanda
$$;

create or replace function public.cliente_da_comanda(p_comanda uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select cliente_id from public.comandas where id = p_comanda
$$;

create or replace function public.tenho_item_na_comanda(p_comanda uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.comanda_itens i
      join public.comandas c on c.id = i.comanda_id
     where i.comanda_id = p_comanda
       and i.profissional_id = meu_profissional_id(c.salao_id))
$$;

-- ---------------------------------------------------------------------------
-- 2) LIGAR O RLS EM TUDO
--
-- Tabela sem RLS no Supabase é tabela aberta na internet. A lista abaixo tem
-- que cobrir TODA tabela do 01_schema.sql — se criar tabela nova, volte aqui.
-- ---------------------------------------------------------------------------

alter table public.saloes                 enable row level security;
alter table public.perfis                 enable row level security;
alter table public.vinculos               enable row level security;
alter table public.profissionais          enable row level security;
alter table public.servicos               enable row level security;
alter table public.servicos_profissionais enable row level security;
alter table public.jornadas               enable row level security;
alter table public.bloqueios              enable row level security;
alter table public.clientes               enable row level security;
alter table public.agendamentos           enable row level security;
alter table public.agendamento_servicos   enable row level security;
alter table public.lista_espera           enable row level security;
alter table public.produtos               enable row level security;
alter table public.comandas               enable row level security;
alter table public.comanda_itens          enable row level security;
alter table public.pagamentos             enable row level security;
alter table public.contadores             enable row level security;

-- ---------------------------------------------------------------------------
-- 3) SALÃO
-- ---------------------------------------------------------------------------

drop policy if exists salao_ler on public.saloes;
create policy salao_ler on public.saloes for select to authenticated
  using ( tem_acesso(id) );

drop policy if exists salao_gerir on public.saloes;
create policy salao_gerir on public.saloes for update to authenticated
  using ( e_gestor(id) ) with check ( e_gestor(id) );

-- Criar e apagar salão é ato da plataforma, não do salão.
drop policy if exists salao_criar on public.saloes;
create policy salao_criar on public.saloes for insert to authenticated
  with check ( is_super() );

-- ---------------------------------------------------------------------------
-- 4) PERFIL — a identidade global
--
-- Ninguém lê o perfil de ninguém. Nem a recepção: para ela existe a ficha do
-- cliente (`clientes`), que é a cópia daquele salão. Assim o telefone que a
-- pessoa deu na barbearia não aparece no salão do outro lado da rua.
-- ---------------------------------------------------------------------------

drop policy if exists perfil_meu on public.perfis;
create policy perfil_meu on public.perfis for select to authenticated
  using ( id = auth.uid() or is_super() );

drop policy if exists perfil_editar on public.perfis;
create policy perfil_editar on public.perfis for update to authenticated
  using ( id = auth.uid() )
  -- Ninguém se promove a dono da plataforma editando o próprio perfil.
  with check ( id = auth.uid()
               and super_admin = (select p.super_admin from public.perfis p
                                   where p.id = auth.uid()) );

-- O cadastro em si é feito pelo gatilho do 03 (a partir do auth.users),
-- não por INSERT vindo do navegador. Por isso não existe policy de insert.

-- ---------------------------------------------------------------------------
-- 5) VÍNCULOS — quem entra em qual salão
-- ---------------------------------------------------------------------------

drop policy if exists vinc_meus on public.vinculos;
create policy vinc_meus on public.vinculos for select to authenticated
  using ( perfil_id = auth.uid() or e_equipe(salao_id) );

-- Virar CLIENTE de um salão é livre: é o que acontece quando a pessoa abre o
-- link e agenda pela primeira vez. Virar equipe, não — o dono precisa liberar.
drop policy if exists vinc_virar_cliente on public.vinculos;
create policy vinc_virar_cliente on public.vinculos for insert to authenticated
  with check ( perfil_id = auth.uid() and papel = 'cliente' and status = 'ativo' );

drop policy if exists vinc_gerir on public.vinculos;
create policy vinc_gerir on public.vinculos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

-- ---------------------------------------------------------------------------
-- 6) CATÁLOGO — profissionais, serviços, jornada
--
-- Cliente logado LÊ (precisa escolher com quem e o quê), só a gestão ESCREVE.
-- ---------------------------------------------------------------------------

drop policy if exists prof_ler on public.profissionais;
create policy prof_ler on public.profissionais for select to authenticated
  using ( tem_acesso(salao_id) );
drop policy if exists prof_gerir on public.profissionais;
create policy prof_gerir on public.profissionais for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists serv_ler on public.servicos;
create policy serv_ler on public.servicos for select to authenticated
  using ( tem_acesso(salao_id) );
drop policy if exists serv_gerir on public.servicos;
create policy serv_gerir on public.servicos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists sp_ler on public.servicos_profissionais;
create policy sp_ler on public.servicos_profissionais for select to authenticated
  using ( exists (select 1 from public.servicos s
                   where s.id = servico_id and tem_acesso(s.salao_id)) );
drop policy if exists sp_gerir on public.servicos_profissionais;
create policy sp_gerir on public.servicos_profissionais for all to authenticated
  using ( exists (select 1 from public.servicos s
                   where s.id = servico_id and e_gestor(s.salao_id)) )
  with check ( exists (select 1 from public.servicos s
                        where s.id = servico_id and e_gestor(s.salao_id)) );

drop policy if exists jor_ler on public.jornadas;
create policy jor_ler on public.jornadas for select to authenticated
  using ( exists (select 1 from public.profissionais p
                   where p.id = profissional_id and tem_acesso(p.salao_id)) );
drop policy if exists jor_gerir on public.jornadas;
create policy jor_gerir on public.jornadas for all to authenticated
  using ( exists (select 1 from public.profissionais p
                   where p.id = profissional_id
                     and (e_gestor(p.salao_id) or p.perfil_id = auth.uid())) )
  with check ( exists (select 1 from public.profissionais p
                        where p.id = profissional_id
                          and (e_gestor(p.salao_id) or p.perfil_id = auth.uid())) );

-- Bloqueio é só da equipe: o motivo ("consulta médica") é assunto interno.
-- O cliente descobre que o horário sumiu pela função de horários livres, sem
-- saber por quê — que é exatamente o certo.
drop policy if exists bloq_equipe on public.bloqueios;
create policy bloq_equipe on public.bloqueios for select to authenticated
  using ( e_equipe(salao_id) );
drop policy if exists bloq_gerir on public.bloqueios;
create policy bloq_gerir on public.bloqueios for all to authenticated
  using ( e_gestor(salao_id)
          or profissional_id = meu_profissional_id(salao_id) )
  with check ( e_gestor(salao_id)
               or profissional_id = meu_profissional_id(salao_id) );

-- ---------------------------------------------------------------------------
-- 7) CLIENTE — a ficha
-- ---------------------------------------------------------------------------

drop policy if exists cli_equipe on public.clientes;
create policy cli_equipe on public.clientes for all to authenticated
  using ( e_equipe(salao_id) ) with check ( e_equipe(salao_id) );

-- O cliente vê e edita a PRÓPRIA ficha — e só os campos dele. Note que
-- `obs`, `alergias` e `ficha` ficam visíveis para ele: é dado dele, LGPD
-- manda deixar ver. Se um dia a equipe quiser anotação interna que o cliente
-- não lê, isso vira outra tabela — não um campo escondido nesta.
drop policy if exists cli_eu on public.clientes;
create policy cli_eu on public.clientes for select to authenticated
  using ( perfil_id = auth.uid() );

drop policy if exists cli_eu_editar on public.clientes;
create policy cli_eu_editar on public.clientes for update to authenticated
  using ( perfil_id = auth.uid() )
  with check ( perfil_id = auth.uid() );

-- ---------------------------------------------------------------------------
-- 8) AGENDA — a policy mais importante do sistema
--
-- Aqui é onde um erro custa caro. Uma policy generosa do tipo
--   using ( tem_acesso(salao_id) )
-- pareceria certa na tela (o app só mostra o que é do cliente), e vazaria
-- nome, telefone e histórico de TODA a clientela para qualquer pessoa
-- cadastrada — bastaria chamar a API REST direto do navegador.
--
-- Por isso o cliente enxerga exatamente os agendamentos cujo `cliente_id`
-- é a ficha dele, e nada mais. Horário livre ele obtém pela função do
-- 03_funcoes_agenda.sql, que devolve horários — não devolve linhas.
-- ---------------------------------------------------------------------------

drop policy if exists agenda_ler on public.agendamentos;
create policy agenda_ler on public.agendamentos for select to authenticated
  using (
       ve_agenda_toda(salao_id)                          -- dono, admin, recepção
    or profissional_id = meu_profissional_id(salao_id)   -- o profissional, a dele
    or cliente_id      = meu_cliente_id(salao_id)        -- o cliente, os dele
  );

-- ⚠ NUNCA use `for all` numa tabela onde a leitura é restrita.
--
-- `for all` vale também para SELECT, e o Postgres soma as policies permissivas
-- com OU. Uma policy de escrita `for all using (e_equipe(salao_id))` colocada
-- ao lado da `agenda_ler` acima ANULA a restrição de leitura: a profissional,
-- que é equipe, volta a enxergar a agenda das colegas.
--
-- Foi exatamente isso que aconteceu na primeira versão deste arquivo, e quem
-- pegou foi o caso 'a profissional vê a própria agenda' do 02_rls.test.sql.
-- Por isso escrita vai separada, verbo por verbo.
--
-- Cliente não escreve aqui: ele passa pela função `agendar()`, que confere
-- jornada, bloqueio e antecedência. Sem isso marcaria 3h da manhã de domingo,
-- com o preço que ele mesmo escolhesse.
drop policy if exists agenda_equipe on public.agendamentos;
drop policy if exists agenda_criar on public.agendamentos;
create policy agenda_criar on public.agendamentos for insert to authenticated
  with check ( e_equipe(salao_id) );

-- Remarcar o atendimento de outra pessoa é coisa da recepção. O profissional
-- mexe no que é dele.
drop policy if exists agenda_editar on public.agendamentos;
create policy agenda_editar on public.agendamentos for update to authenticated
  using ( ve_agenda_toda(salao_id)
          or profissional_id = meu_profissional_id(salao_id) )
  with check ( ve_agenda_toda(salao_id)
               or profissional_id = meu_profissional_id(salao_id) );

drop policy if exists agenda_apagar on public.agendamentos;
create policy agenda_apagar on public.agendamentos for delete to authenticated
  using ( ve_agenda_toda(salao_id) );

drop policy if exists ags_ler on public.agendamento_servicos;
create policy ags_ler on public.agendamento_servicos for select to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id
                     and ( ve_agenda_toda(a.salao_id)
                        or a.profissional_id = meu_profissional_id(a.salao_id)
                        or a.cliente_id      = meu_cliente_id(a.salao_id) )) );

-- Mesma armadilha da tabela de cima: escrita separada, para não reabrir a
-- leitura restrita da `ags_ler`.
drop policy if exists ags_equipe on public.agendamento_servicos;
drop policy if exists ags_criar on public.agendamento_servicos;
create policy ags_criar on public.agendamento_servicos for insert to authenticated
  with check ( exists (select 1 from public.agendamentos a
                        where a.id = agendamento_id and e_equipe(a.salao_id)) );

drop policy if exists ags_editar on public.agendamento_servicos;
create policy ags_editar on public.agendamento_servicos for update to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id and e_equipe(a.salao_id)) )
  with check ( exists (select 1 from public.agendamentos a
                        where a.id = agendamento_id and e_equipe(a.salao_id)) );

drop policy if exists ags_apagar on public.agendamento_servicos;
create policy ags_apagar on public.agendamento_servicos for delete to authenticated
  using ( exists (select 1 from public.agendamentos a
                   where a.id = agendamento_id and e_equipe(a.salao_id)) );

-- ---------------------------------------------------------------------------
-- 8b) LISTA DE ESPERA
--
-- Mesma regra da agenda: a equipe vê a fila inteira, o cliente vê só o lugar
-- dele. Uma fila aberta diria a todo mundo quem mais quer horário naquele
-- salão — e com nome e ficha junto, porque `cliente_id` leva a `clientes`.
-- ---------------------------------------------------------------------------

drop policy if exists espera_ler on public.lista_espera;
create policy espera_ler on public.lista_espera for select to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- Entrar na fila é ato do próprio cliente, ou da recepção por telefone.
drop policy if exists espera_entrar on public.lista_espera;
create policy espera_entrar on public.lista_espera for insert to authenticated
  with check ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- O cliente desiste; a equipe move o status conforme chama e atende.
drop policy if exists espera_mexer on public.lista_espera;
create policy espera_mexer on public.lista_espera for update to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) )
  with check ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

drop policy if exists espera_apagar on public.lista_espera;
create policy espera_apagar on public.lista_espera for delete to authenticated
  using ( e_equipe(salao_id) or cliente_id = meu_cliente_id(salao_id) );

-- ---------------------------------------------------------------------------
-- 9) DINHEIRO — comanda, itens, pagamento, produto
--
-- Profissional vê o que é dele (a comissão dele). Faturamento do salão é da
-- gestão. Cliente vê a própria conta, que é o recibo dele.
-- ---------------------------------------------------------------------------

drop policy if exists prod_ler on public.produtos;
create policy prod_ler on public.produtos for select to authenticated
  using ( e_equipe(salao_id) );
drop policy if exists prod_gerir on public.produtos;
create policy prod_gerir on public.produtos for all to authenticated
  using ( e_gestor(salao_id) ) with check ( e_gestor(salao_id) );

drop policy if exists com_ler on public.comandas;
create policy com_ler on public.comandas for select to authenticated
  using ( ve_agenda_toda(salao_id)
          or cliente_id = meu_cliente_id(salao_id)
          or tenho_item_na_comanda(id) );

drop policy if exists com_caixa on public.comandas;
create policy com_caixa on public.comandas for all to authenticated
  using ( ve_agenda_toda(salao_id) ) with check ( ve_agenda_toda(salao_id) );

drop policy if exists item_ler on public.comanda_itens;
create policy item_ler on public.comanda_itens for select to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id))
          or cliente_da_comanda(comanda_id)
               = meu_cliente_id(salao_da_comanda(comanda_id))
          or profissional_id
               = meu_profissional_id(salao_da_comanda(comanda_id)) );

-- Terceira ocorrência da mesma armadilha, e a de consequência mais
-- constrangedora: com `for all` aqui, um profissional leria a comissão de
-- todos os colegas — o item guarda `comissao_pct` e `comissao_valor`.
drop policy if exists item_caixa on public.comanda_itens;
drop policy if exists item_criar on public.comanda_itens;
create policy item_criar on public.comanda_itens for insert to authenticated
  with check ( e_equipe(salao_da_comanda(comanda_id)) );

drop policy if exists item_editar on public.comanda_itens;
create policy item_editar on public.comanda_itens for update to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) )
  with check ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

drop policy if exists item_apagar on public.comanda_itens;
create policy item_apagar on public.comanda_itens for delete to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

drop policy if exists pgto_ler on public.pagamentos;
create policy pgto_ler on public.pagamentos for select to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id))
          or cliente_da_comanda(comanda_id)
               = meu_cliente_id(salao_da_comanda(comanda_id)) );

drop policy if exists pgto_caixa on public.pagamentos;
create policy pgto_caixa on public.pagamentos for all to authenticated
  using ( ve_agenda_toda(salao_da_comanda(comanda_id)) )
  with check ( ve_agenda_toda(salao_da_comanda(comanda_id)) );

-- `contadores` fica com RLS ligado e SEM nenhuma policy: ninguém alcança pelo
-- navegador. Só a função `proximo_numero`, que é security definer, escreve
-- ali. Se alguém pudesse editar, daria para repetir número de comanda.

-- ---------------------------------------------------------------------------
-- 10) A VITRINE PÚBLICA (sem login)
--
-- A página de agendamento precisa mostrar o salão, os serviços e quem atende
-- ANTES de a pessoa se cadastrar. Isso sai por vistas de colunas escolhidas a
-- dedo — nunca liberando a tabela para `anon`.
--
-- Repare no que NÃO está aqui: preço de custo, comissão, telefone de cliente,
-- e nada de agendamento. O que é público é o cardápio, não a casa inteira.
-- ---------------------------------------------------------------------------

create or replace view public.saloes_publicos as
  select id, slug, nome, tipo, logo, whatsapp, endereco, fuso
    from public.saloes where status = 'ativo';

create or replace view public.servicos_publicos as
  select s.id, s.salao_id, s.nome, s.categoria, s.descricao,
         s.duracao_min, s.preco
    from public.servicos s
    join public.saloes sa on sa.id = s.salao_id
   where s.ativo and s.aceita_online and sa.status = 'ativo';

create or replace view public.profissionais_publicos as
  select p.id, p.salao_id, coalesce(p.apelido, p.nome) as nome, p.foto,
         array(select sp.servico_id from public.servicos_profissionais sp
                where sp.profissional_id = p.id) as servicos
    from public.profissionais p
    join public.saloes sa on sa.id = p.salao_id
   where p.ativo and p.aceita_online and sa.status = 'ativo';

grant select on public.saloes_publicos        to anon, authenticated;
grant select on public.servicos_publicos      to anon, authenticated;
grant select on public.profissionais_publicos to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 11) PERMISSÕES DE TABELA
--
-- O RLS filtra LINHA; o grant decide se a pessoa chega na TABELA. Precisa dos
-- dois. `anon` não recebe nada: quem não fez login só enxerga as vistas acima.
-- ---------------------------------------------------------------------------

grant usage on schema public to anon, authenticated;

grant select, insert, update, delete on
  public.saloes, public.perfis, public.vinculos, public.profissionais,
  public.servicos, public.servicos_profissionais, public.jornadas,
  public.bloqueios, public.clientes, public.agendamentos,
  public.agendamento_servicos, public.lista_espera, public.produtos,
  public.comandas, public.comanda_itens, public.pagamentos
  to authenticated;

grant select on public.comandas_totais to authenticated;

revoke all on public.contadores from anon, authenticated;
