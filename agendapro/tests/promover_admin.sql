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
-- Troque o e-mail abaixo pelo seu e rode. O `where` casa pelo e-mail em
-- auth.users, então não há chance de promover a pessoa errada por engano de
-- uuid copiado pela metade.

do $$
declare
  v_email text := 'TROQUE-PELO-SEU@EMAIL.COM';   -- ← só isto muda
  v_id    uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);

  if v_id is null then
    raise exception E'Não achei conta com o e-mail %.\n'
      '  Crie a conta primeiro pela tela de cadastro do sistema,\n'
      '  depois rode isto de novo.', v_email;
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
