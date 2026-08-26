#!/usr/bin/env bash
# Junta 01 a 08 no 00_tudo.sql, que é o arquivo para colar de uma vez
# no SQL Editor do Supabase. Rode isto sempre que mexer em algum deles.
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAIDA="$AQUI/00_tudo.sql"

cat > "$SAIDA" <<'CAB'
-- ===========================================================================
-- AgendaPro — INSTALAÇÃO COMPLETA
--
-- Cole ESTE arquivo inteiro no SQL Editor do Supabase e clique em Run.
--
-- É a junção, nesta ordem, de:
--   01_schema.sql      as tabelas
--   02_rls.sql         quem enxerga o quê
--   03_onboarding.sql  criar_salao(), o cadastro em uma transação
--   04_imagens.sql     as pastas de foto, uma por salão
--   05_agenda.sql      horarios_livres() e agendar(), o lado da cliente
--   06_vitrine.sql     vitrine(), e o catálogo fechado para quem não tem o link
--   07_plataforma.sql  o painel de quem é dono do AgendaPro
--   08_conta.sql       o perfil que nasce junto com a conta
--   09_cliente.sql     a cliente vê, cancela e entra na fila com um segredo
--   10_campanhas.sql   campanhas de WhatsApp: tabelas, RLS e a fila
--   11_equipe.sql      convite: dar login para recepção e profissional
--   12_relatorios.sql  faturamento, comissão e faltas por período
--   13_cobranca.sql    Pix e boleto pelo Mercado Pago, e a renovação
--   14_motor.sql       o motor da disponibilidade: uma regra, um lugar
--
-- A ORDEM IMPORTA, e não é só arrumação: o 02 fecha o balcão que o Supabase
-- abre sozinho em toda tabela e vista nova, e só consegue fechar o que o 01
-- já criou. Rodar os arquivos avulsos e fora de ordem monta um banco
-- diferente deste. Na dúvida, cole este aqui inteiro.
--
-- Pode rodar mais de uma vez sem medo: tudo aqui é 'create if not exists',
-- 'create or replace' ou 'drop policy if exists' antes de criar.
--
-- Gerado por supabase/montar.sh — não edite à mão; edite os arquivos de origem.
--
-- Depois de rodar, cole tests/conferir_instalacao.sql para checar.
-- ===========================================================================

CAB

for f in 01_schema.sql 02_rls.sql 03_onboarding.sql 04_imagens.sql 05_agenda.sql 06_vitrine.sql 07_plataforma.sql 08_conta.sql 09_cliente.sql 10_campanhas.sql 11_equipe.sql 12_relatorios.sql 13_cobranca.sql 14_motor.sql; do
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
