#!/usr/bin/env bash
# ===========================================================================
# QUEM ATUALIZA TEM QUE TERMINAR COM O MESMO BANCO DE QUEM INSTALA DO ZERO
#
#   bash tests/atualizar.test.sh
#
# ── O DEFEITO QUE ISTO EXISTE PARA PEGAR ───────────────────────────────────
# O painel na loja está sempre à frente do banco do cliente. Ele atualiza
# sozinho (é uma página); o banco só muda quando alguém cola SQL no Supabase.
# Então todo salão vive, por algumas horas ou algumas semanas, num estado que
# a suíte inteira nunca testava: banco de uma versão velha, tela da nova.
#
# `tests/rodar.sh` instala tudo do zero antes de cada arquivo. É o certo para
# testar as regras — e é exatamente por isso que ele é CEGO para esta classe
# de defeito: num banco recém-criado, `create table if not exists` cria a
# tabela completa e ninguém percebe que, num banco que já tem a tabela, esse
# mesmo comando não acrescenta coluna nenhuma.
#
# Foi assim que `convites_equipe.profissional_id` sumiu. A coluna estava
# escrita dentro do `create table if not exists`, e só ali. Quem instalou o
# módulo de equipe antes de a coluna existir colou a versão nova por cima e
# não ganhou coluna nenhuma: a tabela "já existe", o `create` passa batido.
#
# O estrago aparecia longe da causa. A função de quatro argumentos era criada
# sem reclamar — corpo plpgsql não é conferido contra o schema no `create` —
# o PostgREST passava a enxergá-la, o erro "Could not find the function"
# sumia da tela, e só no clique do dono, no salão de verdade, estourava
# `column "profissional_id" does not exist`. Instalação bem-sucedida,
# convite quebrado.
#
# ── COMO ISTO TESTA ────────────────────────────────────────────────────────
# Monta dois bancos e compara o retrato dos dois:
#
#   A) VELHO + REMENDO   o 00_tudo.sql de um commit antigo, e por cima o
#                        98_modulos.sql de hoje — o caminho de quem atualiza
#   B) NOVO              o 00_tudo.sql de hoje, do zero
#
# Se A e B não forem idênticos em coluna, função, gatilho, policy, índice,
# permissão e vista, alguma alteração deste projeto só chega para quem
# instala pela primeira vez. Quem já é cliente fica com o banco pela metade.
#
# O retrato compara ESTRUTURA, não dado: `planos`, por exemplo, tem preço
# diferente nos dois (o cliente rodou o UPDATE, o banco novo já nasce com o
# valor novo), e isso não é defeito.
#
# ── E A TERCEIRA COLAGEM ───────────────────────────────────────────────────
# O mesmo 98_modulos.sql também é colado NUMA LINHA SÓ, porque é assim que
# ele às vezes chega: selecionado com o mouse, colado no celular, quebras de
# linha perdidas pelo caminho. Um `--` sobrevivente engoliria o resto do
# arquivo e o Supabase responderia "Success. No rows returned" — verdade,
# um arquivo inteiramente comentado de fato não faz nada.
# ===========================================================================
set -uo pipefail

PGHOST="${PGHOST:-/tmp}"; PGPORT="${PGPORT:-5444}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"
TMP="$(mktemp -d)"

# O commit do 00_tudo.sql "velho": o último antes de o convite ganhar a ficha
# da agenda. É o estado real de quem instalou o sistema naquela semana.
#
# Não é para virar "o commit mais recente": um remendo que só é testado
# contra ontem não testa nada. Este ponto sobe quando um cliente de verdade
# passar dele — não antes.
VELHO="${VELHO:-7235617}"

sair(){
  psql -q -d postgres -c "drop database if exists atu_velho;" >/dev/null 2>&1
  psql -q -d postgres -c "drop database if exists atu_novo;"  >/dev/null 2>&1
  psql -q -d postgres -c "drop database if exists atu_linha;" >/dev/null 2>&1
  psql -q -d postgres -c "drop database if exists atu_sujo;"  >/dev/null 2>&1
  rm -rf "$TMP"
}
trap sair EXIT

nascer(){
  psql -q -d postgres -c "drop database if exists $1;" >/dev/null 2>&1
  psql -q -d postgres -c "create database $1;"         >/dev/null
  psql -q -v ON_ERROR_STOP=1 -d "$1" -f "$AQUI/00_stub_supabase.sql" >/dev/null 2>&1
  # O Supabase liga "Automatically expose new tables" por padrão. O banco de
  # teste tem que nascer com esse balcão aberto, senão testa um mundo mais
  # limpo que o real.
  psql -q -d "$1" -c "alter default privileges in schema public \
    grant all on tables to anon, authenticated;" >/dev/null
}

# Estrutura, não conteúdo. Ordenado, para o diff ser sobre diferença de
# verdade e não sobre a ordem em que o Postgres devolveu as linhas.
retrato(){
  psql -At -d "$1" <<'SQL'
select 'COL '||table_name||'.'||column_name||' '||data_type||' '||is_nullable
       ||' '||coalesce(column_default,'-')
  from information_schema.columns where table_schema='public' order by 1;
select 'FUN '||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') '
       ||p.prosecdef||' '||p.provolatile::text
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' order by 1;
select 'TRG '||c.relname||' '||pg_get_triggerdef(t.oid)
  from pg_trigger t
  join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and not t.tgisinternal order by 1;
select 'POL '||tablename||'.'||policyname||' '||cmd||' '
       ||coalesce(qual,'-')||' '||coalesce(with_check,'-')
  from pg_policies where schemaname='public' order by 1;
select 'IDX '||indexdef from pg_indexes where schemaname='public' order by 1;
select 'CHK '||rel.relname||' '||con.conname||' '||pg_get_constraintdef(con.oid)
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace
 where n.nspname='public' order by 1;
select 'GRT '||grantee||' '||privilege_type||' '||table_name
  from information_schema.role_table_grants where table_schema='public'
   and grantee in ('anon','authenticated','service_role') order by 1;
select 'EXE '||coalesce(r.grantee,'-')||' '||p.proname
       ||'('||pg_get_function_identity_arguments(p.oid)||')'
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  left join information_schema.role_routine_grants r
         on r.specific_name = p.proname||'_'||p.oid
        and r.grantee in ('anon','authenticated','service_role')
 where n.nspname='public' order by 1;
select 'VIW '||viewname||' '||md5(definition) from pg_views
 where schemaname='public' order by 1;
SQL
}

falhou=0
reprovar(){ echo "✗ $1"; falhou=1; }

echo ""
echo "▸ atualizar — quem já é cliente recebe o mesmo banco de quem chega hoje"

git -C "$RAIZ" show "$VELHO:./supabase/00_tudo.sql" > "$TMP/velho.sql" 2>/dev/null \
  || { echo "✗ não achei o 00_tudo.sql do commit $VELHO"; exit 1; }

# ── A) o caminho de quem atualiza ─────────────────────────────────────────
nascer atu_velho
psql -q -v ON_ERROR_STOP=1 -d atu_velho -f "$TMP/velho.sql" >/dev/null 2>&1 \
  || reprovar "o 00_tudo.sql de $VELHO não instala mais"

# O cliente rodou o UPDATE do preço à mão, sem o resto do arquivo. O remendo
# tem que dar conta a partir daí.
psql -q -d atu_velho -c \
  "update public.planos set preco_mes=57.00 where codigo='individual';" >/dev/null 2>&1

erro="$(psql -v ON_ERROR_STOP=1 -q -d atu_velho -f "$RAIZ/supabase/98_modulos.sql" 2>&1 \
        | grep -viE "skipping" || true)"
[ -n "$erro" ] && reprovar "98_modulos.sql não passa por cima do banco velho: $erro"

# Colar duas vezes é o normal, não a exceção: na dúvida o dono cola de novo.
erro="$(psql -v ON_ERROR_STOP=1 -q -d atu_velho -f "$RAIZ/supabase/98_modulos.sql" 2>&1 \
        | grep -viE "skipping" || true)"
[ -n "$erro" ] && reprovar "98_modulos.sql não aguenta a segunda colagem: $erro"

# ── B) o caminho de quem instala hoje ─────────────────────────────────────
nascer atu_novo
erro="$(psql -v ON_ERROR_STOP=1 -q -d atu_novo -f "$RAIZ/supabase/00_tudo.sql" 2>&1 \
        | grep -viE "skipping" || true)"
[ -n "$erro" ] && reprovar "00_tudo.sql não instala do zero: $erro"

# ── C) o mesmo remendo, numa linha só ─────────────────────────────────────
nascer atu_linha
psql -q -v ON_ERROR_STOP=1 -d atu_linha -f "$TMP/velho.sql" >/dev/null 2>&1
python3 -c "
import sys
sys.stdout.write(' '.join(
    open('$RAIZ/supabase/98_modulos.sql', encoding='utf-8').read().split()))
" > "$TMP/linha.sql"
erro="$(psql -v ON_ERROR_STOP=1 -q -d atu_linha -f "$TMP/linha.sql" 2>&1 \
        | grep -viE "skipping" || true)"
[ -n "$erro" ] && reprovar "98_modulos.sql morre quando chega numa linha só: $erro"

# ── a comparação ──────────────────────────────────────────────────────────
# ── D) o banco de quem JÁ TEM DADO, e dado que fere as regras novas ───────
#
# Um banco vazio aceita qualquer índice único. Um banco com movimento, não:
# `create unique index` não nasce em cima de linha que já o viola, e num
# arquivo colado de uma vez a falha parte a instalação ao meio — o que veio
# antes ficou, o que vem depois não roda. O salão fica com meia instalação e
# uma mensagem em inglês sobre índice.
#
# Duas comandas no mesmo atendimento não é hipótese: é o rastro que o defeito
# do `id` deixava, quando o `Dados.subir()` apagava e reinseria a comanda a
# cada gravação e a tela abria outra por não achar a do atendimento.
nascer atu_sujo
psql -q -v ON_ERROR_STOP=1 -d atu_sujo -f "$TMP/velho.sql" >/dev/null 2>&1
psql -q -v ON_ERROR_STOP=1 -d atu_sujo >/dev/null 2>&1 <<'SQL'
insert into public.saloes (id,slug,nome,tipo) values
  ('cc000000-1111-0000-0000-00000000000a','s-sujo','Salao Sujo','salao');
insert into public.assinaturas (salao_id,plano,status) values
  ('cc000000-1111-0000-0000-00000000000a','time','ativa');
insert into public.profissionais (id,salao_id,nome) values
  ('cc000000-5555-0000-0000-00000000000a','cc000000-1111-0000-0000-00000000000a','Paula');
insert into public.clientes (id,salao_id,nome,telefone) values
  ('cc000000-7777-0000-0000-00000000000a','cc000000-1111-0000-0000-00000000000a','Clara','5511900000901');
insert into public.agendamentos (id,salao_id,profissional_id,cliente_id,inicio,fim,status) values
  ('cc000000-9999-0000-0000-00000000000a','cc000000-1111-0000-0000-00000000000a',
   'cc000000-5555-0000-0000-00000000000a','cc000000-7777-0000-0000-00000000000a',
   now(), now()+interval '1 hour','concluido');
-- A VAZIA nasce primeiro, de propósito: se o desempate fosse "a mais
-- antiga", ela ganharia e o dinheiro sairia do atendimento.
insert into public.comandas (id,salao_id,agendamento_id,cliente_id,status) values
  ('cc000000-aaaa-0000-0000-00000000000a','cc000000-1111-0000-0000-00000000000a',
   'cc000000-9999-0000-0000-00000000000a','cc000000-7777-0000-0000-00000000000a','aberta'),
  ('cc000000-aaaa-0000-0000-00000000000b','cc000000-1111-0000-0000-00000000000a',
   'cc000000-9999-0000-0000-00000000000a','cc000000-7777-0000-0000-00000000000a','aberta');
insert into public.pagamentos (comanda_id, forma, valor) values
  ('cc000000-aaaa-0000-0000-00000000000b','dinheiro',150.00);
SQL

n="$(psql -At -d atu_sujo -c "select count(*) from public.comandas
      where agendamento_id='cc000000-9999-0000-0000-00000000000a';")"
[ "$n" = "2" ] || reprovar "o cenário sujo não montou (esperava 2 comandas, veio $n)"

erro="$(psql -v ON_ERROR_STOP=1 -q -d atu_sujo -f "$RAIZ/supabase/98_modulos.sql" 2>&1 \
        | grep -viE "skipping" || true)"
if [ -n "$erro" ]; then
  reprovar "o remendo morre num banco com movimento: $erro"
else
  # Nada some. Dinheiro gravado não se apaga para um índice caber.
  n="$(psql -At -d atu_sujo -c "select count(*) from public.comandas;")"
  [ "$n" = "2" ] || reprovar "o remendo APAGOU comanda (sobraram $n de 2)"

  n="$(psql -At -d atu_sujo -c "select count(*) from public.pagamentos;")"
  [ "$n" = "1" ] || reprovar "o remendo apagou pagamento (sobraram $n de 1)"

  # Cancelar seria quase tão ruim quanto apagar: comanda cancelada sai do
  # relatório, e o mês encolhe sozinho sem ninguém saber por quê.
  n="$(psql -At -d atu_sujo -c "select count(*) from public.comandas
        where status='cancelada';")"
  [ "$n" = "0" ] || reprovar "o remendo cancelou comanda para o índice caber"

  # A que fica amarrada ao atendimento é a que tem o dinheiro.
  q="$(psql -At -d atu_sujo -c "select id from public.comandas
        where agendamento_id='cc000000-9999-0000-0000-00000000000a';")"
  [ "$q" = "cc000000-aaaa-0000-0000-00000000000b" ] \
    || reprovar "ficou no atendimento a comanda errada: $q"

  # E a outra continua existindo, só desligada — e continua contando.
  n="$(psql -At -d atu_sujo -c "select count(*) from public.comandas
        where id='cc000000-aaaa-0000-0000-00000000000a'
          and agendamento_id is null;")"
  [ "$n" = "1" ] || reprovar "a comanda repetida não foi apenas desligada"

  # Colar de novo não pode mexer em mais nada: já está resolvido.
  psql -q -v ON_ERROR_STOP=1 -d atu_sujo -f "$RAIZ/supabase/98_modulos.sql" >/dev/null 2>&1
  n="$(psql -At -d atu_sujo -c "select count(*) from public.comandas
        where agendamento_id is not null;")"
  [ "$n" = "1" ] || reprovar "a segunda colagem desligou mais comandas ($n)"

  echo "✓ banco com movimento: nada apagado, nada cancelado, o dinheiro ficou."
fi

retrato atu_velho > "$TMP/a.txt"
retrato atu_novo  > "$TMP/b.txt"
retrato atu_linha > "$TMP/c.txt"

[ -s "$TMP/b.txt" ] || reprovar "o retrato do banco novo saiu vazio"

if ! diff -q "$TMP/a.txt" "$TMP/b.txt" >/dev/null; then
  reprovar "atualizar não dá no mesmo banco que instalar do zero:"
  diff "$TMP/a.txt" "$TMP/b.txt" | sed 's/^/    /' | head -40
  echo "    (< só quem atualiza tem   > só quem instala do zero tem)"
fi

if ! diff -q "$TMP/c.txt" "$TMP/b.txt" >/dev/null; then
  reprovar "colado numa linha só o remendo dá um banco diferente:"
  diff "$TMP/c.txt" "$TMP/b.txt" | sed 's/^/    /' | head -20
fi

# ── e o que a tela chama tem que existir, com a assinatura certa ──────────
#
# Não basta a função existir: o PostgREST casa pelo NOME DOS ARGUMENTOS. Uma
# `criar_convite` de três argumentos, no banco onde a tela chama com quatro,
# dá "Could not find the function" mesmo com a função lá. Foi o erro que o
# dono viu na tela do convite.
#
# Os dois padrões, porque são dois lados do sistema: o painel escreve
# `Dados.chamar('fn', ...)`, e as telas da cliente chamam métodos do
# `dados.js`, onde está o `rest('rpc/fn', ...)`. Só o primeiro deixaria de
# fora `vitrine`, `meus_agendamentos` e `minha_fila` — as que a cliente
# alcança sem login.
faltando=0
for f in $({ grep -rohE "chamar\('[a-z_0-9]+"   "$RAIZ"/*.html "$RAIZ"/*.js
             grep -rohE "rest\('rpc/[a-z_0-9]+" "$RAIZ"/*.html "$RAIZ"/*.js
           } | sed -E "s/^chamar\('//; s|^rest\('rpc/||" | sort -u); do
  n="$(psql -At -d atu_velho -c "select count(*) from pg_proc p
        join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname='$f';")"
  if [ "$n" = "0" ]; then
    reprovar "a tela chama $f(), e quem atualiza não fica com essa função"
    faltando=1
  elif [ "$n" != "1" ]; then
    # Duas com o mesmo nome é pior que nenhuma: a chamada cai na antiga em
    # silêncio, sem erro nenhum na tela.
    reprovar "$f() ficou com $n versões no banco de quem atualiza"
    faltando=1
  fi
done
[ "$faltando" = "0" ] && echo "✓ toda função que a tela chama existe, e só uma vez."

if [ "$falhou" = "0" ]; then
  n=$(wc -l < "$TMP/b.txt")
  echo "✓ $n itens de schema conferem entre atualizar e instalar do zero."
  echo "✓ o remendo aguenta arquivo, uma linha só, e colagem repetida."
else
  echo ""
  echo "Reprovou."
fi
exit "$falhou"
