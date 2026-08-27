#!/usr/bin/env bash
# ===========================================================================
# AgendaPro — carimba a versão do painel
#
#   bash versao.sh          # recarimba com o conteúdo atual
#   bash versao.sh v10      # sobe o número da release E recarimba
#
# ── POR QUE ISTO VIROU SCRIPT ──────────────────────────────────────────────
# O carimbo é o que a lateral do painel mostra, e serve para uma pergunta só,
# no suporte: "que versão você está usando?". Ele só responde essa pergunta se
# ANDAR quando o painel anda.
#
# Não andava. Ficou em `v8` por três publicações seguidas — relatórios,
# cobrança e o motor da agenda — e o teste continuou verde, porque ele conferia
# se os dois números batiam ENTRE SI, não se tinham subido. Dois números
# errados e iguais passam.
#
# E o momento em que isso passou a doer é agora: o banco começou a recusar
# horário fora da jornada. Um salão com o painel velho em cache pede a mesma
# marcação, não vê a confirmação de encaixe, e leva a recusa seca do banco. A
# primeira pergunta do suporte é qual painel ele está rodando — e "v8" seria a
# resposta tanto para quem atualizou quanto para quem não.
#
# Agora o carimbo tem duas partes: a release, que é decisão sua, e seis
# dígitos tirados do CONTEÚDO dos arquivos que o navegador baixa. A segunda
# metade muda sozinha a cada edição, e o `confere-grade.test.mjs` reprova
# quando o que está escrito não é o que os arquivos dizem. Esquecer deixou de
# ser possível.
# ===========================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Os arquivos que o navegador baixa e que mudam o comportamento do painel.
# `sw.js` fica de fora de propósito: ele carrega o próprio carimbo, e entraria
# num ciclo — muda o carimbo, muda o hash, que muda o carimbo.
ARQUIVOS=(app.html agendar.html criar.html entrar.html index.html
          nova-senha.html estilo.css dados.js demo.js icones.js
          imagens.js endereco.js)

RELEASE="${1:-}"
if [ -z "$RELEASE" ]; then
  RELEASE="$(grep -oP "const VERSAO_APP = 'v\K[0-9]+" app.html || echo 8)"
  RELEASE="v${RELEASE}"
fi

# A linha do carimbo sai do cálculo — senão escrever o resultado mudaria o
# resultado, e o hash nunca fecharia.
HASH="$(for f in "${ARQUIVOS[@]}"; do
          sed "s/const VERSAO_APP = '[^']*'/const VERSAO_APP = ''/" "$f"
        done | sha256sum | cut -c1-6)"

CARIMBO="${RELEASE}.${HASH}"

python3 - "$CARIMBO" <<'PY'
import re, sys
carimbo = sys.argv[1]
for arq, padrao, novo in [
    ('app.html', r"const VERSAO_APP = '[^']*'", f"const VERSAO_APP = '{carimbo}'"),
    ('sw.js',    r"const VERSAO = 'agendapro-[^']*'", f"const VERSAO = 'agendapro-{carimbo}'"),
]:
    s = open(arq, encoding='utf-8').read()
    novo_s, n = re.subn(padrao, novo, s, count=1)
    if n != 1:
        raise SystemExit(f'não achei o carimbo em {arq}')
    open(arq, 'w', encoding='utf-8').write(novo_s)
PY

echo "carimbo: ${CARIMBO}"
