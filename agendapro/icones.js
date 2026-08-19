/* ===========================================================================
   AgendaPro — ícones
   ---------------------------------------------------------------------------
   SVG traçado, no lugar de emoji.

   Emoji parecia atalho e cobra caro: cada sistema desenha o seu (a tesoura do
   Android não é a do iPhone), não aceita cor nem espessura, não alinha com a
   tipografia e envelhece junto com a moda do teclado. Num produto que o dono
   do salão vai mostrar para o cliente, isso lê como improviso.

   Aqui é uma família só — traço de 1,75, cantos e pontas arredondados, grade
   de 24 — que herda a cor do texto e acompanha o tamanho da fonte.

   Uso:
       ico('calendario')            devolve o SVG como texto, para template
       <span data-ico="relogio">    trocado por SVG quando a página carrega
   =========================================================================== */

(function (global) {
'use strict';

const D = {
  calendario: '<rect x="3" y="4.5" width="18" height="16" rx="2.5"/><path d="M3 9.5h18M8 2.5v4M16 2.5v4"/>',
  relogio:    '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
  usuario:    '<circle cx="12" cy="8" r="3.5"/><path d="M4.5 20a7.5 7.5 0 0 1 15 0"/>',
  equipe:     '<circle cx="9" cy="8" r="3.2"/><path d="M2.5 19.5a6.5 6.5 0 0 1 13 0"/><path d="M16 5.2a3.2 3.2 0 0 1 0 5.6M17.5 19.5a6.5 6.5 0 0 0-2-4.7"/>',
  tesoura:    '<circle cx="6" cy="6" r="2.6"/><circle cx="6" cy="18" r="2.6"/><path d="M20 4 8.3 16.4M20 20 8.3 7.6"/>',
  busca:      '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.4-4.4"/>',
  ok:         '<path d="m4.5 12.5 5 5 10-11"/>',
  fechar:     '<path d="M6 6l12 12M18 6 6 18"/>',
  mais:       '<path d="M12 5v14M5 12h14"/>',
  // Três traços. O "+" que estava no lugar dizia "adicionar", não "abrir o
  // menu" — é o botão mais visível do celular e apontava para a ação errada.
  menu:       '<path d="M4 7h16M4 12h16M4 17h16"/>',
  sair:       '<path d="M14 4.5h4a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-4"/><path d="M10 8.5 6 12l4 3.5M6 12h9"/>',
  chave:      '<circle cx="8" cy="14" r="4.5"/><path d="m11.5 11 8-8M17 5.5l2 2M14.5 8l2 2"/>',
  menos:      '<path d="M5 12h14"/>',
  esquerda:   '<path d="m14.5 5-7 7 7 7"/>',
  direita:    '<path d="m9.5 5 7 7-7 7"/>',
  baixo:      '<path d="m5 9 7 7 7-7"/>',
  telefone:   '<path d="M6.5 3.5h3l1.5 4-2 1.5a12 12 0 0 0 6 6l1.5-2 4 1.5v3a2 2 0 0 1-2.2 2A17 17 0 0 1 4.5 5.7a2 2 0 0 1 2-2.2Z"/>',
  email:      '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="m3.8 6.5 8.2 6 8.2-6"/>',
  cadeado:    '<rect x="4.5" y="10.5" width="15" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
  olho:       '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="3"/>',
  documento:  '<rect x="2.5" y="5" width="19" height="14" rx="2.5"/><path d="M2.5 10h19M6.5 14.5h4"/>',
  casa:       '<path d="m3.5 10.5 8.5-7 8.5 7V19a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z"/><path d="M9.5 21v-6h5v6"/>',
  sino:       '<path d="M18 9a6 6 0 1 0-12 0c0 5-2 6.5-2 6.5h16S18 14 18 9Z"/><path d="M10.3 19a2 2 0 0 0 3.4 0"/>',
  escudo:     '<path d="M12 3 5 6v5.5c0 4.3 2.9 7.9 7 9.5 4.1-1.6 7-5.2 7-9.5V6Z"/><path d="m9 12 2.2 2.2L15.5 10"/>',
  presente:   '<rect x="3" y="9" width="18" height="11.5" rx="2"/><path d="M3 13.5h18M12 9v11.5"/><path d="M12 9S10.5 3.5 8 4.5 9.5 9 12 9Zm0 0s1.5-5.5 4-4.5S14.5 9 12 9Z"/>',
  info:       '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8v.2"/>',
  alerta:     '<path d="M12 4.5 3 19.5h18Z"/><path d="M12 10v4M12 17.2v.2"/>',
  cartao:     '<rect x="2.5" y="5.5" width="19" height="13" rx="2.5"/><path d="M2.5 10h19M6 14.5h3"/>',
  predio:     '<rect x="4.5" y="3" width="15" height="18" rx="2"/><path d="M9 7.5h2M13 7.5h2M9 11.5h2M13 11.5h2M10 21v-4h4v4"/>',
  etiqueta:   '<path d="M3.5 11V4.5H10L20 14.5 13.5 21 3.5 11Z"/><circle cx="7.5" cy="8.5" r="1.3"/>',
  tema:       '<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17" /><path d="M12 3.5a8.5 8.5 0 0 1 0 17Z" fill="currentColor" stroke="none"/>',
  saida:      '<path d="M14 4.5h4a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-4"/><path d="M10 8.5 6 12l4 3.5M6 12h9"/>',
  seta:       '<path d="M5 12h13M13 6.5 18.5 12 13 17.5"/>',
  externo:    '<path d="M13.5 4.5H19.5V10.5M19.5 4.5 11 13"/><path d="M18 14v4.5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4.5"/>',
  copiar:     '<rect x="8.5" y="8.5" width="12" height="12" rx="2.5"/><path d="M15.5 5.5v-1a1 1 0 0 0-1-1h-10a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h1"/>',
  mao:        '<path d="M10 11V5.5a1.6 1.6 0 1 1 3.2 0V11"/><path d="M13.2 11V4.2a1.6 1.6 0 1 1 3.2 0V13"/><path d="M6.8 12.5V9.2a1.6 1.6 0 1 1 3.2 0V13"/><path d="M16.4 8.8a1.6 1.6 0 0 1 3.2 0v4.4a7.4 7.4 0 0 1-7.4 7.4h-.6a6.6 6.6 0 0 1-5.5-3l-2.4-3.6a1.6 1.6 0 0 1 2.5-2l1.4 1.5"/>',
};

// Devolve o SVG como texto, para usar dentro de template literal.
function ico(nome, extra){
  const d = D[nome];
  if(!d){ console.warn('[icones] não existe: ' + nome); return ''; }
  return '<svg class="ic-svg ' + (extra || '') + '" viewBox="0 0 24 24" '
       + 'aria-hidden="true" focusable="false">' + d + '</svg>';
}

// Troca <span data-ico="nome"> pelo SVG. Roda ao carregar e pode ser
// chamado de novo depois de desenhar conteúdo novo.
function aplicar(raiz){
  (raiz || document).querySelectorAll('[data-ico]').forEach(el => {
    const nome = el.getAttribute('data-ico');
    if(!D[nome]) return;
    el.innerHTML = ico(nome, el.getAttribute('data-ico-classe') || '');
    el.removeAttribute('data-ico');
  });
}

global.ico = ico;
global.aplicarIcones = aplicar;

if(document.readyState === 'loading'){
  document.addEventListener('DOMContentLoaded', () => aplicar());
} else { aplicar(); }

})(window);
