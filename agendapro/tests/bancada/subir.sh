#!/usr/bin/env bash
# Sobe a bancada: um Postgres com o schema instalado + um PostgREST caseiro.
# Serve para testar dados.js sem precisar de um projeto Supabase no ar.
#
#   bash tests/bancada/subir.sh
#   node tests/nuvem.test.mjs
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$(dirname "$AQUI")")"
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5444}" PGUSER="${PGUSER:-postgres}"

echo "▸ Montando o banco 'app'"
psql -q -d postgres -c "drop database if exists app;" -c "create database app;" >/dev/null
psql -q -d app -v ON_ERROR_STOP=1 -f "$RAIZ/tests/00_stub_supabase.sql" >/dev/null
psql -q -d app -v ON_ERROR_STOP=1 -f "$RAIZ/supabase/00_tudo.sql" 2>&1 | grep -v skipping || true
psql -q -d app -c "grant usage on schema auth to anon, authenticated;" >/dev/null

command -v node >/dev/null || { echo "precisa de node"; exit 1; }
[ -d "$AQUI/node_modules/pg" ] || (cd "$AQUI" && npm i pg --silent)

echo "▸ Subindo o PostgREST caseiro em http://127.0.0.1:8123"
cd "$AQUI" && node postgrest.mjs
