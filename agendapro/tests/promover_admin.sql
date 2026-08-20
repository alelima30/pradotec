-- ===========================================================================
-- AgendaPro — promover alguém a dono da plataforma
--
--   Supabase → seu projeto → SQL Editor → cole isto → troque o e-mail → Run
--
-- ---------------------------------------------------------------------------
-- POR QUE ISTO SÓ EXISTE AQUI, E NÃO NUMA TELA
--
-- Uma conta `super_admin` lê a clientela, a agenda e o faturamento de TODOS
-- os salões da plataforma. É a única credencial do sistema cuja perda não tem
-- conserto parcial.
--
-- Se houvesse um caminho pela aplicação — um botão, uma rota, uma chamada de
-- API — esse caminho seria o alvo, e um dia alguém acharia a ponta solta. Não
-- havendo caminho nenhum, a única porta é o painel do Supabase, que já exige
-- a senha do projeto.
--
-- Isso não é teoria: o teste em tests/02_rls.test.sql tenta o caminho óbvio,
-- e ele fecha —
--
--     ✓ não consegue se tornar dona da plataforma
--     ✓ não consegue se dar o papel de dona do salão
--
-- ---------------------------------------------------------------------------
-- ANTES DE RODAR, DUAS DECISÕES
--
-- 1. USE UMA CONTA SEPARADA da que você usa como dono de salão.
--    Não é burocracia: é o tamanho do estrago quando algo dá errado. Sessão
--    esquecida aberta, tela emprestada para alguém ver, celular perdido — o
--    prejuízo é do tamanho da conta que estava logada. Com contas separadas,
--    o dia a dia acontece na conta pequena.
--
-- 2. LIGUE A VERIFICAÇÃO EM DOIS PASSOS nessa conta.
--    Supabase → Authentication → Providers → MFA. Senha sozinha protege
--    contra quem tenta; segundo fator protege contra quem já conseguiu a
--    senha, que é o caso que importa.
-- ===========================================================================

-- ── PASSO 1 ────────────────────────────────────────────────────────────────
-- Crie a conta com o e-mail que vai ser o seu de administrador. Ela nasce
-- como qualquer outra: sem poder nenhum além do próprio salão.
--
-- Dois caminhos, e o segundo é o mais rápido:
--
--   a) pela tela de cadastro do sistema — mas SÓ funciona se o config.js
--      estiver apontando para este projeto. Aberto no site em modo
--      demonstração, a conta vai para o navegador e o Supabase nunca a vê;
--   b) Supabase → Authentication → Users → Add user, com e-mail e senha.
--      Marque "Auto Confirm User" para não precisar do e-mail de confirmação.
--
-- Nos dois casos o perfil é criado sozinho pelo gatilho do 08_conta.sql.

-- ── PASSO 2 ────────────────────────────────────────────────────────────────
-- TROQUE O E-MAIL na linha do `v_email` logo abaixo. É a única edição que
-- este arquivo pede, e é a que mais se esquece — rodar sem trocar faz o
-- script procurar uma conta chamada TROQUE-PELO-SEU@EMAIL.COM.
--
-- Se preferir não editar nada, este comando sozinho faz o mesmo serviço:
--
--   insert into public.perfis (id, nome, email, super_admin)
--   select u.id, split_part(u.email, '@', 1), u.email, true
--     from auth.users u
--    where lower(u.email) = lower('SEU@EMAIL.COM')
--   on conflict (id) do update set super_admin = true;
--
-- O `where` casa pelo e-mail em auth.users, então não há chance de promover a
-- pessoa errada por engano de uuid copiado pela metade.

do $$
declare
  v_email text := 'TROQUE-PELO-SEU@EMAIL.COM';   -- ← só isto muda
  v_id    uuid;
  v_temQuantas int;
  v_lista text;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);

  -- ── QUANDO NÃO ACHA, MOSTRAR O QUE EXISTE ────────────────────────────────
  -- A primeira versão só dizia "não achei, crie a conta primeiro" — e mandava
  -- de volta para a tela de cadastro, que era exatamente onde o problema
  -- estava: aberta em modo demonstração, ela grava no navegador e o Supabase
  -- nunca vê nada. A pessoa cria a conta de novo, roda de novo, e lê a mesma
  -- frase. Duas vezes seguidas, no meu caso.
  --
  -- Erro que manda de volta para o lugar que causou o erro é pior que erro
  -- nenhum. Agora ele mostra o que HÁ em auth.users, e a lista responde
  -- sozinha qual é o caso:
  --
  --   · vazia          → nenhuma conta chegou aqui: a tela está em
  --                      demonstração, ou aponta para outro projeto;
  --   · com o e-mail   → é diferença de digitação (ponto, domínio, acento);
  --   · com outros     → a conta foi criada, mas com outro endereço.
  -- ── A ARMADILHA MAIS PROVÁVEL, CONFERIDA PRIMEIRO ───────────────────────
  -- O espaço reservado continuar aí não é "conta não encontrada": é o script
  -- rodado sem a única edição que ele pede. A versão anterior tratava os dois
  -- casos igual, e a mensagem dizia "a conta existe com outro endereço" —
  -- mandando procurar erro de digitação num e-mail que nunca foi digitado.
  --
  -- Diagnóstico que descreve o sintoma errado custa mais caro que diagnóstico
  -- nenhum: ele ocupa a pessoa procurando no lugar errado.
  if v_email = 'TROQUE-PELO-SEU@EMAIL.COM' then
    select string_agg('     ' || coalesce(u.email, '(sem e-mail)'), E'\n'
                      order by u.created_at desc)
      into v_lista
      from (select email, created_at from auth.users
             order by created_at desc limit 10) u;

    raise exception E'O e-mail não foi trocado: o script ainda está com\n'
      'TROQUE-PELO-SEU@EMAIL.COM na linha do `v_email`.\n\n'
      'Contas deste projeto — copie a sua para lá:\n%',
      coalesce(v_lista, '     (nenhuma conta ainda; crie em Authentication → Users)');
  end if;

  if v_id is null then
    select count(*) into v_temQuantas from auth.users;

    select string_agg('     ' || coalesce(u.email, '(sem e-mail)')
                      || '  ·  criada em ' || to_char(u.created_at, 'DD/MM HH24:MI'),
                      E'\n' order by u.created_at desc)
      into v_lista
      from (select email, created_at from auth.users
             order by created_at desc limit 10) u;

    raise exception E'Não achei conta com o e-mail %.\n\n'
      'Este projeto tem % conta(s) em auth.users:\n%\n\n'
      '%',
      v_email, v_temQuantas,
      coalesce(v_lista, '     (nenhuma)'),
      case when v_temQuantas = 0 then
        E'Nenhuma conta chegou até aqui. Quase sempre isso quer dizer que a\n'
        'tela de cadastro está em modo demonstração — com config.js vazio ela\n'
        'grava no navegador, e o Supabase nunca vê nada.\n\n'
        'Caminho curto: Authentication → Users → Add user, com e-mail e senha,\n'
        'marcando "Auto Confirm User". Depois rode isto de novo.'
      else
        E'A conta existe com outro endereço, ou o e-mail acima tem alguma\n'
        'diferença de digitação. Copie um da lista e rode de novo.'
      end;
  end if;

  -- O perfil nasce junto com a conta, pelo gatilho do 08_conta.sql. Este
  -- insert é a rede para o caso de a conta ser mais antiga que o gatilho —
  -- e aí ele vira um update, que é o caminho normal.
  --
  -- O telefone fica em branco de propósito: não é obrigatório, e inventar um
  -- número aqui criaria uma linha que um dia colidiria com a de uma cliente
  -- de verdade. Você completa depois, pela tela, se quiser.
  insert into public.perfis (id, nome, email, super_admin)
       values (v_id, split_part(v_email, '@', 1), v_email, true)
  on conflict (id) do update set super_admin = true;

  raise notice '✓ % agora é dono da plataforma (id %)', v_email, v_id;
end $$;

-- ── PASSO 3 ────────────────────────────────────────────────────────────────
-- Confira. Esta lista tem que ter exatamente as pessoas que você quer, e
-- nenhuma a mais — inclusive daqui a um ano, quando você não lembrar mais
-- quem promoveu.

select p.id,
       u.email,
       p.nome,
       p.criado_em as perfil_criado_em
  from public.perfis p
  join auth.users u on u.id = p.id
 where p.super_admin
 order by p.criado_em;

-- ---------------------------------------------------------------------------
-- PARA TIRAR O PODER DE ALGUÉM
--
--   update public.perfis set super_admin = false
--    where id = (select id from auth.users where lower(email) = lower('fulano@x.com'));
--
-- Tirar o super_admin NÃO apaga a conta nem os salões da pessoa: ela volta a
-- ser um dono de salão comum. É de propósito — a saída tem que ser tão barata
-- quanto a entrada, senão ninguém revoga acesso quando deveria.
-- ---------------------------------------------------------------------------
