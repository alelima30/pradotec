#!/usr/bin/env bash
# ===========================================================================
# Gera supabase/99_remendo.sql — o caminho da cliente, SEM UM COMENTÁRIO
#
# ── POR QUE ESTE ARQUIVO EXISTE ────────────────────────────────────────────
# O 00_tudo.sql tem 166 KB e é feito para ser colado inteiro. Copiado no
# celular, ou por seleção de mouse, as quebras de linha às vezes se perdem —
# e aí cada `--` engole o resto da linha. Quase nada é executado, e o editor
# do Supabase responde "Success. No rows returned", que é verdade: um arquivo
# inteiramente comentado de fato não faz nada.
#
# Aconteceu de verdade. O conferidor mostrou ficha_do_cliente FALTA e
# vitrine_com_galeria FALTA depois de um "Success".
#
# Este remendo é imune: nenhum comentário, nem `--` nem `/* */`. Colado numa
# linha só, roda igual — está testado das duas formas.
#
# É gerado dos MESMOS arquivos-fonte, nunca escrito à mão: divergir do
# 00_tudo.sql seria criar uma segunda verdade sobre o que o banco deve ter.
# ===========================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PY'
import re

def limpar(sql):
    sql = re.sub(r'/\*.*?\*/', '', sql, flags=re.S)
    fora = []
    for linha in sql.split('\n'):
        c = linha.find('--')
        if c >= 0: linha = linha[:c]
        if linha.strip(): fora.append(linha.rstrip())
    return '\n'.join(fora)

fonte05 = open('supabase/05_agenda.sql', encoding='utf-8').read()
i = fonte05.index('create or replace function public.ficha_do_cliente')
ficha = fonte05[i:fonte05.index('$$;', i) + 3]

partes = [
    limpar(ficha),
    "revoke all on function public.ficha_do_cliente(uuid, text, text) from public;",
    limpar(open('supabase/09_cliente.sql', encoding='utf-8').read()),
    limpar(open('supabase/06_vitrine.sql', encoding='utf-8').read()),
]
saida = '\n\n'.join(partes) + '\n'
assert '--' not in saida, 'sobrou comentário: o remendo perde a imunidade'
open('supabase/99_remendo.sql', 'w', encoding='utf-8').write(saida)
print('supabase/99_remendo.sql —', saida.count('\n'), 'linhas')
PY
