#!/usr/bin/env bash
# Junta 01 + 02 + 03 + 04 no 00_tudo.sql, que é o arquivo para colar de uma vez
# no SQL Editor do Supabase. Rode isto sempre que mexer em algum deles.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAIDA="$AQUI/00_tudo.sql"

cat > "$SAIDA" <<'CAB'
-- ===========================================================================
-- AgendaPro — INSTALAÇÃO COMPLETA
--
-- Cole ESTE arquivo inteiro no SQL Editor do Supabase e clique em Run.
-- É a junção de 01_schema.sql + 02_rls.sql + 03_onboarding.sql + 04_imagens.sql,
-- nesta ordem.
--
-- Pode rodar mais de uma vez sem medo: tudo aqui é 'create if not exists',
-- 'create or replace' ou 'drop policy if exists' antes de criar.
--
-- Gerado por supabase/montar.sh — não edite à mão; edite os arquivos de origem.
--
-- Depois de rodar, cole tests/conferir_instalacao.sql para checar.
-- ===========================================================================

CAB

for f in 01_schema.sql 02_rls.sql 03_onboarding.sql 04_imagens.sql; do
  {
    echo ''
    echo '-- ###########################################################################'
    echo "-- ## $f"
    echo '-- ###########################################################################'
    echo ''
    cat "$AQUI/$f"
  } >> "$SAIDA"
done
echo "00_tudo.sql: $(wc -l < "$SAIDA") linhas"
