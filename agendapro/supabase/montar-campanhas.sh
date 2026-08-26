#!/usr/bin/env bash
# ===========================================================================
# Gera supabase/98_campanhas.sql — o módulo de campanhas, SEM UM COMENTÁRIO
#
# ── POR QUE NÃO MANDAR O 00_tudo.sql ───────────────────────────────────────
# Ele tem 170 KB. Copiado no celular, ou por seleção de mouse, as quebras de
# linha às vezes se perdem — e aí cada `--` engole o resto da linha. Quase
# nada é executado, e o editor do Supabase responde "Success. No rows
# returned", que é verdade: um arquivo inteiramente comentado de fato não faz
# nada. Já aconteceu neste projeto, com o conferidor acusando função FALTA
# depois de um "Success".
#
# Este arquivo é imune: nenhum comentário, nem `--` nem `/* */`. Colado numa
# linha só, roda igual — e o tests/rodar.sh cola das duas formas.
#
# É gerado dos MESMOS arquivos-fonte, nunca escrito à mão.
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

def recortar(fonte, cabeca):
    i = fonte.index(cabeca)
    return fonte[i:fonte.index('$$;', i) + 3]

rls = open('supabase/02_rls.sql', encoding='utf-8').read()

# Os quatro auxiliares de permissão, com o `coalesce` que impede o NULL.
#
# `papel_no_salao()` é NULL para quem não tem vínculo, e `NULL in (...)` é
# NULL. Dentro de uma policy isso barra igual — policy só deixa passar TRUE.
# Dentro de `if not e_gestor(x) then raise`, NÃO: `not NULL` é NULL, o `if`
# não dispara, e a função segue como se a permissão existisse.
#
# As funções do 10_campanhas.sql conferem permissão exatamente assim. Sem
# estes quatro aqui, o módulo instala com um buraco de autorização.
auxiliares = [
    recortar(rls, 'create or replace function public.tem_acesso('),
    recortar(rls, 'create or replace function public.e_equipe('),
    recortar(rls, 'create or replace function public.e_gestor('),
    recortar(rls, 'create or replace function public.ve_agenda_toda('),
]

partes = [limpar(a) for a in auxiliares]
partes.append(limpar(open('supabase/10_campanhas.sql', encoding='utf-8').read()))

saida = '\n\n'.join(partes) + '\n'
assert '--' not in saida, 'sobrou comentário: o arquivo perde a imunidade'
open('supabase/98_campanhas.sql', 'w', encoding='utf-8').write(saida)
print('supabase/98_campanhas.sql —', saida.count('\n'), 'linhas')
PY
