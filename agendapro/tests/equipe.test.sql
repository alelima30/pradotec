-- ===========================================================================
-- AgendaPro — convite de equipe: um uso, um salão, uma pessoa
--
-- Um convite é uma cadeira dentro de um salão. As perguntas que este arquivo
-- responde são as que, erradas, entregam essa cadeira a quem não devia:
--
--   1. O link serve mais de uma vez? (dois cliques, dois aparelhos)
--   2. O link de um salão dá acesso a outro?
--   3. Quem não administra consegue criar convite?
--   4. Um convite vencido ou revogado ainda entra?
--   5. Dá para um salão ficar sem dono?
--   6. `ver_convite` — que `anon` alcança — vaza mais do que precisa?
-- ===========================================================================

\set ON_ERROR_STOP on

insert into auth.users (id, email) values
  ('e0000000-0000-0000-0000-00000000000d', 'dona@teste.com'),
  ('e0000000-0000-0000-0000-00000000000e', 'recepcao@teste.com'),
  ('e0000000-0000-0000-0000-00000000000f', 'estranho@teste.com');

insert into public.perfis (id, nome, telefone) values
  ('e0000000-0000-0000-0000-00000000000d', 'Dona Ju',   '+5511900000101'),
  ('e0000000-0000-0000-0000-00000000000e', 'Rita Recep','+5511900000102'),
  ('e0000000-0000-0000-0000-00000000000f', 'Estranho',  '+5511900000103')
on conflict (id) do nothing;

insert into public.saloes (id, slug, nome, tipo) values
  ('e0000000-1111-0000-0000-00000000000a', 'salao-da-ju', 'Salão da Ju', 'salao'),
  ('e0000000-1111-0000-0000-00000000000b', 'outro-salao', 'Outro Salão', 'salao');
insert into public.assinaturas (salao_id, plano, status) values
  ('e0000000-1111-0000-0000-00000000000a', 'time', 'ativa'),
  ('e0000000-1111-0000-0000-00000000000b', 'time', 'ativa');

insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('e0000000-0000-0000-0000-00000000000d',
   'e0000000-1111-0000-0000-00000000000a', 'dono', 'ativo');

\echo ''
\echo 'A dona cria um convite'

select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000d', false);
select t_verdade('logada como a dona',
  auth.uid() = 'e0000000-0000-0000-0000-00000000000d');

select (public.criar_convite('e0000000-1111-0000-0000-00000000000a',
                             'recepcao', 'Rita')->>'token') as tk \gset

select t_verdade('o convite nasceu com um segredo', :'tk' is not null);

select t_verdade('e ele vale',
  (public.ver_convite(:'tk'::uuid)->>'valido')::boolean);
select t_texto('dizendo de que salão é',
  public.ver_convite(:'tk'::uuid)->>'salao', 'Salão da Ju');
select t_texto('e com que papel', public.ver_convite(:'tk'::uuid)->>'papel', 'recepcao');

-- `ver_convite` é a ÚNICA função deste módulo que `anon` alcança: a página do
-- convite precisa dizer de que salão se trata antes de a pessoa ter conta.
-- Então ela não pode devolver nada além disso.
select t_falso('ver_convite NÃO devolve quem convidou',
  (public.ver_convite(:'tk'::uuid)) ? 'criadoPor');
select t_falso('nem o id do salão',
  (public.ver_convite(:'tk'::uuid)) ? 'salaoId');
select t_falso('nem quem já é da equipe',
  (public.ver_convite(:'tk'::uuid)) ? 'equipe');

\echo ''
\echo 'QUEM NÃO ADMINISTRA NÃO CONVIDA'

select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000f', false);
set role authenticated;
select t_texto('rodando como authenticated', current_user, 'authenticated');

select t_verdade('um estranho não cria convite no salão dos outros',
  recusado($$select public.criar_convite(
    'e0000000-1111-0000-0000-00000000000a', 'recepcao', 'eu mesmo')$$));

select t_verdade('nem lê a lista de quem tem acesso',
  recusado($$select public.equipe_com_acesso(
    'e0000000-1111-0000-0000-00000000000a')$$));

select t_igual('nem enxerga a tabela de convites — que guarda os segredos',
  (select count(*) from public.convites_equipe), 0);

select t_verdade('nem tira o acesso de ninguém',
  recusado($$select public.remover_acesso(
    'e0000000-1111-0000-0000-00000000000a',
    'e0000000-0000-0000-0000-00000000000d', 'dono')$$));

-- E o caminho óbvio: entrar direto na tabela de vínculos como equipe.
select t_verdade('e não se promove escrevendo direto em vinculos',
  recusado($$insert into public.vinculos (perfil_id, salao_id, papel, status)
             values ('e0000000-0000-0000-0000-00000000000f',
                     'e0000000-1111-0000-0000-00000000000a', 'dono', 'ativo')$$));

reset role;

\echo ''
\echo 'ACEITAR — e só uma vez'

select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000e', false);

select t_verdade('a Rita aceita',
  (public.aceitar_convite(:'tk'::uuid)->>'ok')::boolean);

select t_igual('e passa a ter vínculo de recepção',
  (select count(*) from public.vinculos
    where perfil_id = 'e0000000-0000-0000-0000-00000000000e'
      and salao_id = 'e0000000-1111-0000-0000-00000000000a'
      and papel = 'recepcao' and status = 'ativo'), 1);

select t_verdade('o papel dela no salão é recepção',
  public.papel_no_salao('e0000000-1111-0000-0000-00000000000a') = 'recepcao');

-- É o ponto do desenho: o link circula pelo WhatsApp e pode ser encaminhado.
select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000f', false);
select t_texto('o MESMO link não serve para uma segunda pessoa,
                e a recusa explica o que houve',
  erro_de(format($$select public.aceitar_convite(%L::uuid)$$, :'tk')),
  'Este convite não vale mais. Peça outro ao salão.');

select t_igual('o estranho continua sem vínculo nenhum',
  (select count(*) from public.vinculos
    where perfil_id = 'e0000000-0000-0000-0000-00000000000f'), 0);

select t_falso('e o convite já não vale para mais ninguém',
  (public.ver_convite(:'tk'::uuid)->>'valido')::boolean);

\echo ''
\echo 'VENCIDO E REVOGADO NÃO ENTRAM'

select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000d', false);

select (public.criar_convite('e0000000-1111-0000-0000-00000000000a',
                             'profissional', 'Vencido')->>'token') as tv \gset
update public.convites_equipe set expira_em = now() - interval '1 day'
 where token = :'tv';
select t_falso('convite vencido não vale',
  (public.ver_convite(:'tv'::uuid)->>'valido')::boolean);

select (public.criar_convite('e0000000-1111-0000-0000-00000000000a',
                             'profissional', 'Revogado')->>'token') as tr \gset
select id as idr from public.convites_equipe where token = :'tr' \gset
select public.revogar_convite(:'idr'::uuid);
select t_falso('convite revogado não vale',
  (public.ver_convite(:'tr'::uuid)->>'valido')::boolean);

set role authenticated;
select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000f', false);
select t_verdade('e nenhum dos dois deixa entrar',
  recusado(format($$select public.aceitar_convite(%L::uuid)$$, :'tv'))
  and recusado(format($$select public.aceitar_convite(%L::uuid)$$, :'tr')));
reset role;

\echo ''
\echo 'O SALÃO NÃO PODE FICAR SEM DONO'

select set_config('request.jwt.claim.sub',
                  'e0000000-0000-0000-0000-00000000000d', false);

select t_texto('a dona não tira o próprio acesso de dona',
  erro_de(format($$select public.remover_acesso(
    'e0000000-1111-0000-0000-00000000000a'::uuid, %L::uuid, 'dono')$$,
    'e0000000-0000-0000-0000-00000000000d')),
  'Você não pode tirar o próprio acesso de dono.');

select t_igual('ela continua sendo dona',
  (select count(*) from public.vinculos
    where salao_id = 'e0000000-1111-0000-0000-00000000000a'
      and papel = 'dono' and status = 'ativo'), 1);

-- Tirar quem NÃO é o último dono continua funcionando.
select t_verdade('mas tirar o acesso da recepção funciona',
  (public.remover_acesso('e0000000-1111-0000-0000-00000000000a',
                         'e0000000-0000-0000-0000-00000000000e',
                         'recepcao')->>'ok')::boolean);
select t_igual('e ela sai da lista',
  (select count(*) from public.vinculos
    where perfil_id = 'e0000000-0000-0000-0000-00000000000e'
      and salao_id = 'e0000000-1111-0000-0000-00000000000a'), 0);

\echo ''
\echo 'A LISTA DE QUEM TEM ACESSO'

select t_igual('a dona vê uma pessoa com acesso',
  jsonb_array_length(public.equipe_com_acesso(
    'e0000000-1111-0000-0000-00000000000a')), 1);

-- O e-mail é a chave de login da pessoa, e não é preciso para administrar.
select t_falso('e a lista NÃO traz o e-mail de ninguém',
  (public.equipe_com_acesso('e0000000-1111-0000-0000-00000000000a')->0) ? 'email');

select set_config('request.jwt.claim.sub', '', false);
