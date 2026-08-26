#!/usr/bin/env bash
# ===========================================================================
# AgendaPro — roda TUDO, de uma vez
#
#   bash tests/tudo.sh
#
# ── POR QUE ISTO EXISTE ────────────────────────────────────────────────────
# Antes eram nove comandos diferentes, um por suíte, e cinco deles pediam uma
# variável `PLAYWRIGHT=` cujo valor certo não estava escrito em lugar nenhum —
# o cabeçalho dos arquivos diz `.../node_modules/playwright`, que é reticência,
# não caminho.
#
# Com o caminho errado o Node não avisa que a suíte não rodou: ele cospe um
# rastro de pilha e sai. Rodando as suítes em sequência e batendo o olho, o que
# se vê é uma tela sem nenhum ✗ — que é exatamente a cara de tudo passando.
# Aconteceu comigo: cinco suítes não rodaram e o placar parecia limpo.
#
# Então aqui a regra é outra: quem não roda REPROVA, com o mesmo peso de quem
# falha. Suíte que não rodou não é suíte verde; é suíte sem notícia.
# ===========================================================================
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"
cd "$RAIZ"

# ── Achar o Playwright sozinho ─────────────────────────────────────────────
# Pedir o caminho para quem roda o teste é transferir para a pessoa um problema
# que o script resolve em três tentativas.
if [ -z "${PLAYWRIGHT:-}" ]; then
  for tentativa in \
    "$AQUI/bancada/node_modules/playwright" \
    "$RAIZ/node_modules/playwright" \
    "$(npm root -g 2>/dev/null)/playwright"
  do
    [ -d "$tentativa" ] && { PLAYWRIGHT="$tentativa"; break; }
  done
fi
if [ -z "${PLAYWRIGHT:-}" ]; then
  echo "✗ Não achei o Playwright. Instale com 'npm i -g playwright' ou aponte:"
  echo "    PLAYWRIGHT=/caminho/para/node_modules/playwright bash tests/tudo.sh"
  exit 1
fi
export PLAYWRIGHT

# ── Onde está o Chromium ───────────────────────────────────────────────────
# Nesta máquina de desenvolvimento ele mora em /opt/pw-browsers/chromium. No
# CI, quem sabe o caminho é o próprio Playwright, e apontar para /opt lá faria
# TODAS as suítes de navegador falharem com "executable doesn't exist" — um
# erro sobre caminho, que ninguém lê como "estou na outra máquina".
if [ -z "${CHROMIUM:-}" ] && [ -x /opt/pw-browsers/chromium ]; then
  CHROMIUM=/opt/pw-browsers/chromium
fi
if [ -z "${CHROMIUM:-}" ] || [ ! -x "$CHROMIUM" ]; then
  CHROMIUM="$(node -e "console.log(require('$PLAYWRIGHT').chromium.executablePath())" 2>/dev/null || true)"
fi
if [ -z "${CHROMIUM:-}" ] || [ ! -x "$CHROMIUM" ]; then
  echo "✗ Não achei o Chromium. Instale com 'npx playwright install chromium'"
  echo "  ou aponte:  CHROMIUM=/caminho/para/chromium bash tests/tudo.sh"
  exit 1
fi
export CHROMIUM

ESTATICO="${ESTATICO:-http://127.0.0.1:8099}"
BANCADA="${BANCADA:-http://127.0.0.1:8123}"
export BASE="${BASE:-$ESTATICO/}"
export BANCADA

no_ar() { curl -s -o /dev/null --max-time 2 "$1" 2>/dev/null; }

echo "▸ Playwright: $PLAYWRIGHT"
no_ar "$ESTATICO/criar.html" \
  || { echo "✗ Nada servindo em $ESTATICO — rode:  python3 -m http.server 8099 --directory ."; exit 1; }
no_ar "$BANCADA/" \
  || { echo "✗ A bancada não está de pé em $BANCADA — rode:  bash tests/bancada/subir.sh"; exit 1; }

falhou=0
reprovadas=()

rodar() {
  local nome="$1"; shift
  echo ""
  echo "▸ $nome"
  local saida
  saida="$("$@" 2>&1)"
  local codigo=$?
  # Só as duas últimas linhas: o placar. O detalhe fica para quem reprova.
  echo "$saida" | tail -2
  if [ $codigo -ne 0 ]; then
    # Se saiu por erro sem ter falhado teste — módulo faltando, bancada caída —
    # o rastro inteiro importa, porque ninguém adivinha isso pelo placar.
    echo "$saida" | grep -q "falharam" || { echo "   ── não chegou a rodar ──"; echo "$saida" | tail -12; }
    falhou=1; reprovadas+=("$nome")
  fi
}

# Primeiro de todos, e de propósito: erro de sintaxe derruba a tela inteira,
# e sem esta linha ele aparecia de raspão noutra suíte, apontando outro
# arquivo. Custa menos de um segundo.
rodar "sintaxe"           node "$AQUI/sintaxe.test.js"
rodar "banco (SQL)"        bash "$AQUI/rodar.sh"
rodar "colunas"            node "$AQUI/colunas.test.js"
rodar "nuvem"              node "$AQUI/nuvem.test.mjs"
rodar "cota"               node "$AQUI/cota.test.mjs"
rodar "funil na nuvem"     node "$AQUI/funil-nuvem.test.mjs"
rodar "link da cliente"    node "$AQUI/cliente-nuvem.test.mjs"
rodar "senha"              node "$AQUI/senha.test.mjs"
rodar "cadastro"           node "$AQUI/cadastro.test.mjs"
rodar "abertura"           node "$AQUI/abertura.test.mjs"
rodar "celular"            node "$AQUI/celular.test.mjs"
rodar "imagens"            node "$AQUI/imagens.test.mjs"
rodar "plataforma"         node "$AQUI/plataforma.test.mjs"
rodar "aparência"          node "$AQUI/aparencia.test.mjs"
rodar "segurança"          node "$AQUI/seguranca.test.mjs"
rodar "segredos"           node "$AQUI/segredos.test.js"
rodar "instalar"           node "$AQUI/instalar.test.mjs"
rodar "auditoria"          node "$AQUI/auditoria.test.mjs"
rodar "fluxo"              node "$AQUI/fluxo-auditoria.test.mjs"
rodar "sincronia"          node "$AQUI/sincronia.test.mjs"
rodar "whatsapp"           node "$AQUI/whatsapp.test.mjs"
rodar "varredura"          node "$AQUI/varredura.test.mjs"
rodar "grade"              node "$AQUI/grade.test.mjs"
rodar "ficha repetida"     node "$AQUI/ficha-repetida.test.mjs"
rodar "semana"             node "$AQUI/semana.test.mjs"
rodar "arquivar"           node "$AQUI/arquivar.test.mjs"
rodar "confere grade"      node "$AQUI/confere-grade.test.mjs"
rodar "cartão legível"     node "$AQUI/cartao-legivel.test.mjs"
rodar "abas do salão"      node "$AQUI/abas-salao.test.mjs"
rodar "convite da equipe"  node "$AQUI/convite.test.mjs"
rodar "papéis no painel"   node "$AQUI/papeis.test.mjs"
rodar "relatórios"         node "$AQUI/relatorios.test.mjs"
rodar "assinatura do webhook" node "$AQUI/webhook-assinatura.test.js"
rodar "checkout"           node "$AQUI/cobranca.test.mjs"

echo ""
if [ "$falhou" -eq 0 ]; then
  echo "✓ Tudo passou — as 34 suítes."
else
  echo "✗ Reprovaram: ${reprovadas[*]}"
  echo "  Nada deve ser publicado assim."
  exit 1
fi
