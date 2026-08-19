#!/usr/bin/env bash
# Gera, em dist/, uma cópia de cada tela com o CSS e o JS embutidos.
#
#   bash montar-avulso.sh
#
# Serve para mandar por e-mail ou WhatsApp e a pessoa abrir com dois cliques,
# sem servidor e sem pasta com nove arquivos. O código de verdade continua
# separado — isto aqui é só empacotamento, e não deve ser editado.
#
# O que NÃO vai junto: o service worker. Navegador nenhum registra service
# worker em file://, então a versão avulsa não instala como aplicativo. Para
# isso, sirva a pasta original por http (veja o COMO-TESTAR.md).
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$AQUI/dist"

# As fontes vão como arquivo, não embutidas: 74 KB em base64 dentro de cada
# uma das três páginas seriam 300 KB a mais, repetidos. O @font-face do CSS
# aponta para `fontes/`, então a pasta precisa viajar junto.
cp -r "$AQUI/fontes" "$AQUI/dist/"

python3 - "$AQUI" <<'PY'
import io, os, sys, re
raiz = sys.argv[1]
dist = os.path.join(raiz, 'dist')

def ler(nome):
    return io.open(os.path.join(raiz, nome), encoding='utf-8').read()

for pagina in ('app.html', 'agendar.html', 'criar.html', 'index.html'):
    s = ler(pagina)

    s = s.replace('<link rel="stylesheet" href="estilo.css" />',
                  '<style>\n' + ler('estilo.css') + '\n</style>')

    def embutir(m):
        return '<script>\n' + ler(m.group(1)) + '\n</script>'
    s = re.sub(r'<script src="([\w.-]+\.js)"></script>', embutir, s)

    # O manifest e o service worker só funcionam servidos por http.
    s = s.replace('<link rel="manifest" href="manifest.webmanifest" />', '')
    s = re.sub(r'<link rel="icon"[^>]*>', '', s)
    s = re.sub(r'<link rel="apple-touch-icon"[^>]*>', '', s)

    io.open(os.path.join(dist, pagina), 'w', encoding='utf-8').write(s)
    print('  %-14s %6.0f KB' % (pagina, len(s.encode()) / 1024))
PY
