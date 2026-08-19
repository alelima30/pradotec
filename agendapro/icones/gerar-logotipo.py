#!/usr/bin/env python3
"""
AgendaPro — gerador do logotipo

Emite os três SVG que o sistema usa, a partir de um desenho só:

    logotipo.svg          bloco inteiro, letra escura   — para fundo claro
    logotipo-branco.svg   bloco inteiro, letra branca   — para fundo escuro
    marca-linha.svg       só a palavra e o anel, branca — para a barra lateral

Por que as letras viram CONTORNO em vez de <text>: posicionar "Agenda" e "pro"
por coordenada depende da fonte instalada na máquina de quem abre. Na primeira
versão as duas palavras se sobrepunham fora daqui, porque a métrica do Segoe
Black do Windows não é a do que existe neste servidor. Contorno é desenho: sai
igual em qualquer lugar, com ou sem fonte.

    pip install fonttools brotli
    python3 icones/gerar-logotipo.py caminho/para/Montserrat-Black.woff2
"""
import io, os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.misc.transform import Transform

TAM     = 104.0        # corpo da letra, em px do viewBox
APERTO  = -0.035       # espacejamento negativo, como no original
BASE    = 116.0        # linha de base
ALTURA  = 250

def contornos(fonte, texto, x0):
    f = TTFont(fonte)
    k = TAM / f['head'].unitsPerEm
    cmap, gs, hm = f.getBestCmap(), f.getGlyphSet(), f['hmtx']
    partes, x = [], x0
    for ch in texto:
        g = cmap.get(ord(ch))
        if not g:
            raise SystemExit('A fonte não tem o caractere %r' % ch)
        caneta = SVGPathPen(gs)
        gs[g].draw(TransformPen(caneta, Transform(k, 0, 0, -k, x, 0)))
        d = caneta.getCommands()
        if d: partes.append(d)
        x += hm[g][0] * k + APERTO * TAM
    return ' '.join(partes), x - x0

def montar(d1, d2, w1, w2, *, tinta, com_pilula):
    anel_x = w1 + w2 - 6
    anel_r = 46
    larg   = anel_x + anel_r * 2 + 74
    alt    = ALTURA if com_pilula else 176
    meio   = (larg - 300) / 2
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {larg:.0f} {alt}"
     width="{larg:.0f}" height="{alt}" role="img" aria-labelledby="lg-t lg-d">
  <title id="lg-t">AgendaPro{' Gestão' if com_pilula else ''}</title>
  <desc id="lg-d">Logotipo do AgendaPro: a palavra Agenda, pro em magenta
  virando roxo, com o o substituído por um anel com um visto saindo por cima, e
  uma curva sob a palavra{'; abaixo, a pílula Gestão com um calendário marcado' if com_pilula else ''}.
  As letras são contornos, não texto: o desenho sai igual em qualquer máquina.</desc>
  <defs>
    <linearGradient id="lg-g" x1="{w1:.0f}" y1="30" x2="{larg-40:.0f}" y2="150"
                    gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#E0219B"/>
      <stop offset=".38" stop-color="#8A25E4"/>
      <stop offset="1" stop-color="#4B14A8"/>
    </linearGradient>
    <linearGradient id="lg-c" x1="60" y1="170" x2="{larg-90:.0f}" y2="150"
                    gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#E0219B"/><stop offset="1" stop-color="#4B14A8"/>
    </linearGradient>
    <linearGradient id="lg-p" x1="120" y1="185" x2="430" y2="240"
                    gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#E8137F"/><stop offset="1" stop-color="#5B1FD0"/>
    </linearGradient>
    <filter id="lg-r" x="-5%" y="-12%" width="110%" height="126%">
      <feDropShadow dx="0" dy="3" stdDeviation="1.8" flood-color="#0A0710"
                    flood-opacity="{'.32' if tinta != '#FFFFFF' else '.55'}"/>
    </filter>
  </defs>

  <g filter="url(#lg-r)" transform="translate(26 {BASE})">
    <path d="{d1}" fill="{tinta}"/>
    <path d="{d2}" fill="url(#lg-g)"/>
  </g>

  <g transform="translate({26 + anel_x:.1f} {BASE - 76:.1f})">
    <g stroke="url(#lg-g)" stroke-width="8" stroke-linecap="round" opacity=".92">
      <path d="M{anel_r*2+8} 26h26"/><path d="M{anel_r*2+4} 46h30"/>
      <path d="M{anel_r*2+8} 66h26"/>
    </g>
    <path d="M{anel_r*2-8:.0f} 40A{anel_r-4} {anel_r-4} 0 1 1 {anel_r*2-22:.0f} 24"
          fill="none" stroke="url(#lg-g)" stroke-width="13" stroke-linecap="round"/>
    <path d="M28 48 44 64 {anel_r*2+2:.0f} 8" fill="none" stroke="url(#lg-g)"
          stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  </g>

  <path d="M62 168C190 140 {larg*0.66:.0f} 136 {larg-86:.0f} 152"
        fill="none" stroke="url(#lg-c)" stroke-width="14" stroke-linecap="round"/>
{f"""
  <g transform="translate({meio:.0f} 182)">
    <rect x="2" y="2" width="296" height="58" rx="29" fill="#14111C"
          stroke="url(#lg-p)" stroke-width="4"/>
    <g transform="translate(38 15)" fill="#fff">
      <path d="M15 0h2l1.1 4.2 3 1.2 3.6-2.3 1.4 1.4-2.3 3.6 1.2 3L29.2 12v2l-4.2 1.1
               -1.2 3 2.3 3.6-1.4 1.4-3.6-2.3-3 1.2L17 25.2h-2l-1.1-4.2-3-1.2-3.6 2.3
               -1.4-1.4 2.3-3.6-1.2-3L2.8 14v-2l4.2-1.1 1.2-3L5.9 4.3l1.4-1.4 3.6 2.3
               3-1.2Z"/>
      <circle cx="16" cy="13" r="4.4" fill="#14111C"/>
    </g>
    <path d="M86 15v32" stroke="#fff" stroke-width="2.6" stroke-linecap="round" opacity=".8"/>
    <text x="112" y="42" fill="#fff" font-size="29" font-weight="800" letter-spacing="2.6"
          font-family="'Segoe UI','Arial Black',Arial,sans-serif">GESTÃO</text>
  </g>""" if com_pilula else ''}
</svg>
'''

def principal():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    fonte = sys.argv[1]
    aqui = os.path.dirname(os.path.abspath(__file__))
    d1, w1 = contornos(fonte, 'Agenda', 0)
    d2, w2 = contornos(fonte, 'pr', w1)

    saidas = [
        ('logotipo.svg',        '#141021', True),
        ('logotipo-branco.svg', '#FFFFFF', True),
        ('marca-linha.svg',     '#FFFFFF', False),
    ]
    for nome, tinta, pilula in saidas:
        svg = montar(d1, d2, w1, w2, tinta=tinta, com_pilula=pilula)
        caminho = os.path.join(aqui, nome)
        io.open(caminho, 'w', encoding='utf-8').write(svg)
        print('%-22s %5.1f KB' % (nome, len(svg) / 1024))

if __name__ == '__main__':
    principal()
