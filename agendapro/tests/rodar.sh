#!/usr/bin/env bash
# Roda os testes do banco num Postgres descartável.
#
#   bash tests/rodar.sh
#
# Precisa de um Postgres alcançável. Por padrão tenta o socket local na porta
# 5444; dá para apontar para outro com as variáveis abaixo:
#
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres bash tests/rodar.sh
#
# O banco é criado do zero e apagado no fim: nenhum teste enxerga a sujeira do
# anterior, e a ordem entre eles não muda o resultado.

set -euo pipefail

PGHOST="${PGHOST:-/tmp}"
PGPORT="${PGPORT:-5444}"
PGUSER="${PGUSER:-postgres}"
BANCO="${BANCO:-agendapro_test}"
export PGHOST PGPORT PGUSER

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"

trap 'psql -q -d postgres -c "drop database if exists ${BANCO};" >/dev/null 2>&1 || true' EXIT

carregar() {
  # NOTICE de "does not exist, skipping" é esperado no banco novo (os arquivos
  # são idempotentes, com drop antes de create). Só o resto interessa.
  psql -v ON_ERROR_STOP=1 -q -d "$BANCO" -f "$1" 2>&1 \
    | grep -v "does not exist, skipping" || true
}

# Cada arquivo de teste ganha um banco recém-criado.
#
# Não é exagero: enquanto os dois arquivos dividiam o mesmo banco, o teste da
# vitrine pública contava 4 salões em vez de 2 — os 2 dele mais os 2 que o
# arquivo anterior tinha deixado. O teste falhou por sujeira, não por defeito,
# e a leitura do erro apontava para o lugar errado.
preparar() {
  psql -q -d postgres -c "drop database if exists ${BANCO};" >/dev/null
  psql -q -d postgres -c "create database ${BANCO};" >/dev/null
  carregar "$AQUI/00_stub_supabase.sql"

  # O Supabase liga por padrão "Automatically expose new tables", que dá ALL
  # para anon e authenticated em toda tabela nova do schema public. O banco de
  # teste precisa nascer assim, senão os testes rodam num mundo mais limpo que
  # o real e aprovam um schema que lá fora está com o balcão aberto — foi
  # exatamente o que aconteceu: a instalação num projeto de verdade acusou as
  # 20 tabelas liberadas para anon, e a suíte inteira estava verde.
  psql -q -d "$BANCO" -c "alter default privileges in schema public \
    grant all on tables to anon, authenticated;" >/dev/null

  carregar "$RAIZ/supabase/01_schema.sql"
  carregar "$RAIZ/supabase/02_rls.sql"
  carregar "$RAIZ/supabase/03_onboarding.sql"
  carregar "$RAIZ/supabase/04_imagens.sql"
  carregar "$RAIZ/supabase/05_agenda.sql"
  carregar "$RAIZ/supabase/06_vitrine.sql"
  carregar "$RAIZ/supabase/07_plataforma.sql"
  carregar "$RAIZ/supabase/08_conta.sql"
  carregar "$RAIZ/supabase/09_cliente.sql"
  carregar "$RAIZ/supabase/10_campanhas.sql"
  carregar "$RAIZ/supabase/11_equipe.sql"
  carregar "$RAIZ/supabase/12_relatorios.sql"
  carregar "$RAIZ/supabase/13_cobranca.sql"
  carregar "$AQUI/00_ajuda.sql"
}

falhou=0
for teste in "$AQUI"/*.test.sql; do
  nome="$(basename "$teste")"
  echo ""
  echo "▸ $nome"
  preparar
  psql -v ON_ERROR_STOP=1 -q -d "$BANCO" -f "$teste" 2>&1 \
    | sed "s|^psql:${teste}:[0-9]*: NOTICE:  ||"
  # psql sai por um pipe; PIPESTATUS guarda o código real dele
  [ "${PIPESTATUS[0]}" -eq 0 ] || falhou=1
done

# ═══════════════════════════════════════════════════════════════════════════
# O 00_tudo.sql TEM QUE SOBREVIVER À SEGUNDA COLAGEM
#
# O cabeçalho dele promete: "pode rodar mais de uma vez sem medo". E não podia.
#
# O 09_cliente.sql substitui `agendar()` por uma versão que devolve o token de
# gerenciamento — uma coluna a mais no retorno. `create or replace` não muda
# tipo de retorno, então, num banco já instalado, a segunda passada morria no
# 05 tentando rebaixar a função de volta:
#
#     ERROR: cannot change return type of existing function
#
# Quem cola o arquivo de novo — o que a gente pede a cada correção — leva essa
# mensagem, que fala de tipo de retorno e não diz nada sobre o que fazer.
#
# Os testes acima nunca pegaram porque instalam arquivo por arquivo, uma vez
# só. Aqui o arquivo é colado DUAS VEZES, que é o que acontece de verdade.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "▸ 00_tudo.sql colado duas vezes"
psql -q -d postgres -c "drop database if exists ${BANCO}_2x;" \
                    -c "create database ${BANCO}_2x;" >/dev/null
for vez in 1 2; do
  saida=$(psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_2x" \
            $( [ "$vez" = 1 ] && printf -- '-f %s' "$AQUI/00_stub_supabase.sql" ) \
            -f "$RAIZ/supabase/00_tudo.sql" 2>&1 | grep -E "^psql.*ERROR|^ERROR" || true)
  if [ -n "$saida" ]; then
    echo "  ✗ ${vez}ª passada falhou:"
    echo "      $saida"
    falhou=1
  else
    echo "  ✓ ${vez}ª passada, sem erro"
  fi
done
psql -q -d postgres -c "drop database if exists ${BANCO}_2x;" >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
# O 99_remendo.sql TEM QUE CONSERTAR UM BANCO JÁ SUJO
#
# O remendo é gerado por recorte do 05/06/09, e o recortador só sabia achar
# FUNÇÃO — procurava um cabeçalho e cortava até o `$$;`. A correção do
# telefone da ficha não é função: é UPDATE mais a trava `cli_tel_so_digitos`.
# Ficou de fora sem ninguém notar, e o remendo levava a tela corrigida com o
# cadastro sujo do mesmo jeito. A mesma pessoa continuava em duas fichas.
#
# Nada acusava: o 00_tudo.sql tem a correção, então o banco de teste nascia
# limpo e qualquer conferência passaria mesmo com o remendo vazio. Aqui a
# correção é DESFEITA e o cadastro é sujado antes de colar o remendo.
#
# E o remendo é colado DAS DUAS FORMAS. Numa linha só é como ele chega quando
# alguém copia pelo celular — é para isso que ele nasceu sem comentário.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "▸ 99_remendo.sql num banco já instalado e sujo"
for forma in arquivo "uma linha só"; do
  psql -q -d postgres -c "drop database if exists ${BANCO}_rem;" \
                      -c "create database ${BANCO}_rem;" >/dev/null
  if ! psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_rem" \
         -f "$AQUI/00_stub_supabase.sql" -f "$RAIZ/supabase/00_tudo.sql" \
         >/dev/null 2>&1 \
     || ! psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_rem" \
            -f "$AQUI/00_ajuda.sql" -f "$AQUI/remendo_sujar.sql" >/dev/null
  then
    echo "  ✗ não consegui montar o banco sujo — o remendo nem foi testado"
    falhou=1
    continue
  fi

  echo "  ── colado como $forma ──"
  if [ "$forma" = arquivo ]; then
    colar() { psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_rem" \
                -f "$RAIZ/supabase/99_remendo.sql"; }
  else
    colar() { tr '\n' ' ' < "$RAIZ/supabase/99_remendo.sql" \
                | psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_rem" -f -; }
  fi

  if ! saida=$(colar 2>&1); then
    echo "  ✗ o remendo não passou:"
    echo "$saida" | grep -E "ERROR" | head -3
    falhou=1
  else
    # psql sai por um pipe: sem PIPESTATUS quem responde é o `sed`, que nunca
    # falha — e a conferência inteira viraria enfeite.
    psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_rem" \
      -f "$AQUI/remendo_conferir.sql" 2>&1 \
      | sed "s|^psql:${AQUI}/remendo_conferir.sql:[0-9]*: NOTICE:  ||"
    [ "${PIPESTATUS[0]}" -eq 0 ] || falhou=1
  fi
  # Colar de novo é o que a gente pede a cada correção: tem que ser inofensivo.
  if ! saida=$(colar 2>&1); then
    echo "  ✗ a segunda colagem falhou:"
    echo "$saida" | grep -E "ERROR" | head -3
    falhou=1
  else
    echo "  ✓ colado duas vezes, sem erro"
  fi
done
psql -q -d postgres -c "drop database if exists ${BANCO}_rem;" >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
# O 98_modulos.sql INSTALA OS MÓDULOS NUM BANCO QUE NÃO OS TEM
#
# É o arquivo que o dono cola no Supabase para ganhar as campanhas. Mesma
# regra do remendo: sem comentário, e colado DAS DUAS FORMAS, porque numa
# linha só é como ele chega quando alguém copia pelo celular.
#
# O banco de teste nasce com o módulo já instalado (vem no 00_tudo.sql), então
# um teste que só colasse o arquivo aprovaria um arquivo VAZIO. Aqui o módulo
# é DESFEITO antes — inclusive os auxiliares de permissão, que voltam à versão
# que devolve NULL.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "▸ 98_modulos.sql num banco sem os módulos"
for forma in arquivo "uma linha só"; do
  psql -q -d postgres -c "drop database if exists ${BANCO}_camp;" \
                      -c "create database ${BANCO}_camp;" >/dev/null
  if ! psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_camp" \
         -f "$AQUI/00_stub_supabase.sql" -f "$RAIZ/supabase/00_tudo.sql" \
         >/dev/null 2>&1 \
     || ! psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_camp" \
            -f "$AQUI/00_ajuda.sql" -f "$AQUI/campanhas_sujar.sql" >/dev/null 2>&1
  then
    echo "  ✗ não consegui desfazer o módulo — o arquivo nem foi testado"
    falhou=1
    continue
  fi

  echo "  ── colado como $forma ──"
  if [ "$forma" = arquivo ]; then
    colarc() { psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_camp" \
                 -f "$RAIZ/supabase/98_modulos.sql"; }
  else
    colarc() { tr '\n' ' ' < "$RAIZ/supabase/98_modulos.sql" \
                 | psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_camp" -f -; }
  fi

  if ! saida=$(colarc 2>&1); then
    echo "  ✗ o arquivo não passou:"
    echo "$saida" | grep -E "ERROR" | head -3
    falhou=1
  else
    psql -v ON_ERROR_STOP=1 -q -d "${BANCO}_camp" \
      -f "$AQUI/campanhas_conferir.sql" 2>&1 \
      | sed "s|^psql:${AQUI}/campanhas_conferir.sql:[0-9]*: NOTICE:  ||"
    [ "${PIPESTATUS[0]}" -eq 0 ] || falhou=1
  fi
  if ! saida=$(colarc 2>&1); then
    echo "  ✗ a segunda colagem falhou:"
    echo "$saida" | grep -E "ERROR" | head -3
    falhou=1
  else
    echo "  ✓ colado duas vezes, sem erro"
  fi
done
psql -q -d postgres -c "drop database if exists ${BANCO}_camp;" >/dev/null 2>&1 || true

echo ""
if [ "$falhou" -eq 0 ]; then
  echo "✓ Tudo passou."
else
  echo "✗ Algum teste falhou — nada deve ser publicado assim."
  exit 1
fi
