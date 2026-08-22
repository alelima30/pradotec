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

echo ""
if [ "$falhou" -eq 0 ]; then
  echo "✓ Tudo passou."
else
  echo "✗ Algum teste falhou — nada deve ser publicado assim."
  exit 1
fi
