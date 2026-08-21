/* ===========================================================================
   AgendaPro — a aparência que o salão escolhe, e o que a cliente vê

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/aparencia.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   Uma barbearia de dourado e grafite e uma esmalteria de rosa e branco não
   podem ser a mesma página com o nome trocado. O salão escolhe cor, fundo e
   se a capa mostra preço; a `vitrine()` entrega as três; a página aplica.

   São quatro elos, e todos falham calados quando quebram: a chave que não
   sai do `cfg`, a que não é devolvida pela função, a que a tela não lê, e a
   cor que é aplicada em cima de uma regra `!important` do estilo. Em todos
   os casos o resultado na tela é o mesmo — a página roxa de sempre — e
   ninguém descobre até um dono reclamar que "não muda nada".

   ── E O CONTRASTE ─────────────────────────────────────────────────────────
   O caso que motivou a metade mais cuidadosa daqui: sobre o dourado
   #C8A33C, letra branca dá 2,5:1 de contraste. O mínimo legível é 4,5:1. O
   botão principal da página — o único caminho para marcar horário — virava
   um borrão para quem enxerga pouco, ou para qualquer um no sol.

   A primeira versão do código comparava a luminância com um número escolhido
   a olho e errava exatamente esse caso. Aqui a conta é conferida contra o
   valor da norma, cor por cor, incluindo as sete da paleta pronta.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok = (m) => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c, d) => c ? ok(m) : nao(m, d || 'esperava verdadeiro');
const secao = t => console.log('\n' + t);

function novaAba(){
  const g = {};
  const j = { AGENDAPRO:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

/* ── A conta do contraste, aqui do lado de fora ───────────────────────────
   Escrita de novo de propósito, e não importada do agendar.html: um teste que
   usa a mesma função que testa concorda com ela mesmo quando as duas estão
   erradas. Esta é a fórmula da norma, copiada da norma. */
function contraste(hexA, hexB){
  const lum = h => [1,3,5].map(i => parseInt(h.substr(i,2),16) / 255)
    .map(c => c <= 0.03928 ? c/12.92 : Math.pow((c+0.055)/1.055, 2.4))
    .reduce((s,v,i) => s + [0.2126,0.7152,0.0722][i]*v, 0);
  const [x, y] = [lum(hexA), lum(hexB)].sort((a,b) => b-a);
  return (x + 0.05) / (y + 0.05);
}

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`ap-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Rafael Souza', telefone:'+5551' + (100000000 + (Date.now() % 89999999)) });
const criado = await d.chamar('criar_salao', { p_nome_salao:'Barbearia ' + marca,
  p_tipo:'barbearia', p_telefone:'(51) 99887-6655', p_documento:null, p_origem:null });
const salaoId = criado[0].salao_id, SLUG = criado[0].slug;
const prof = (await d.lista('profissionais', { salaoId }))[0];
for(let i = 0; i <= 6; i++){
  await d.inserir('jornadas', { profissionalId: prof.id, diaSemana:i,
                                inicio:'09:00', fim:'19:00' });
}
await d.inserir('servicos', { salaoId, nome:'Corte navalhado', preco:40,
  duracaoMin:30, intervaloMin:0, ativo:true, aceitaOnline:true });
ok('salão de teste criado');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:412, height:915 } });

async function abrir(){
  const p = await ctx.newPage();
  p.erros = [];
  p.on('pageerror', e => p.erros.push(e.message));
  await p.goto(BASE + '/agendar.html?salao=' + SLUG);
  await p.waitForTimeout(2400);
  return p;
}

/* ══════════════════════════════════════════════════════════════════════════
   A CHAVE PRECISA ATRAVESSAR OS QUATRO ELOS
   ══════════════════════════════════════════════════════════════════════════ */
secao('Do cfg do salão até a tela da cliente');

await d.atualizar('saloes', salaoId, { cfg:{ diasLiberados:30,
  cor:'#C8A33C', tema:'escuro', precoNaCapa:true } });

// Elo 2: a função do banco devolve o que foi guardado.
const v = await d.chamar('vitrine', { p_slug: SLUG });
const daVitrine = Array.isArray(v) ? v[0] : v;
igual('a vitrine() devolve a cor escolhida', daVitrine.salao.cor, '#C8A33C');
igual('e o fundo', daVitrine.salao.tema, 'escuro');
igual('e se a capa mostra preço', daVitrine.salao.precoNaCapa, true);
verdade('e NÃO devolve o cfg inteiro — só as chaves nomeadas',
  daVitrine.salao.cfg === undefined,
  'o cfg cru veio junto: chave nova cairia na vitrine sem ninguém decidir');

// Elos 3 e 4: a tela lê e aplica.
const p = await abrir();
igual('a página entra em fundo escuro',
  await p.getAttribute('html', 'data-tema'), 'escuro');
igual('e a cor de ação é a do salão',
  await p.evaluate(() => getComputedStyle(document.documentElement)
    .getPropertyValue('--acao').trim()), '#C8A33C');

/* ── O CONTRASTE DO BOTÃO ────────────────────────────────────────────────── */
secao('A letra do botão se lê sobre a cor escolhida');

const letra = await p.evaluate(() =>
  getComputedStyle(document.querySelector('.boas-cta')).color);
igual('sobre o dourado, a letra é escura — não branca', letra, 'rgb(16, 16, 20)');
verdade('e o contraste passa do mínimo legível (4,5:1)',
  contraste('#C8A33C', '#101014') >= 4.5,
  'deu ' + contraste('#C8A33C', '#101014').toFixed(2) + ':1');
verdade('enquanto a branca, que era o que saía antes, não passava',
  contraste('#C8A33C', '#FFFFFF') < 4.5,
  'branco sobre este dourado dá ' + contraste('#C8A33C','#FFFFFF').toFixed(2) + ':1');

/* As sete cores prontas do painel, uma a uma. Cor que a casa oferece não pode
   produzir botão ilegível — quem escolhe na paleta confia que dá certo. */
const PALETA = ['#C8A33C','#5B21B6','#B0316A','#0C7568','#1D4ED8','#C2410C','#3F3F46'];
let todasOk = true, pior = null;
for(const c of PALETA){
  const melhor = Math.max(contraste(c, '#101014'), contraste(c, '#FFFFFF'));
  if(melhor < 4.5){ todasOk = false; pior = c + ' (' + melhor.toFixed(2) + ':1)'; }
}
verdade('as sete cores da paleta dão botão legível', todasOk,
  'esta não dá: ' + pior);

/* ══════════════════════════════════════════════════════════════════════════
   O PREÇO NA CAPA É ESCOLHA DO SALÃO
   ══════════════════════════════════════════════════════════════════════════ */
secao('Preço na capa, ligado e desligado');

verdade('ligado, o valor aparece no cartão do serviço',
  await p.isVisible('.sv-cartao-preco'));

/* ── E O TÍTULO NÃO PODE SAIR DUAS VEZES ───────────────────────────────────
   A capa tinha um "O que oferecemos" fixo no HTML e a lista escrevia o nome
   da categoria logo abaixo — então a tela mostrava dois títulos empilhados,
   dizendo a mesma coisa. Com uma categoria só, sai um. */
const titulos = await p.evaluate(() =>
  [...document.querySelectorAll('#capaServicos .cat, #capaServicos .cat-sub')]
    .map(e => e.textContent.trim()));
igual('e o título dos serviços sai UMA vez — ' + JSON.stringify(titulos),
  titulos.length, 1);
igual('com o vocabulário da barbearia', titulos[0], 'Nossos cortes');
igual('sem erro de JavaScript', p.erros.length ? p.erros.join(' | ') : 0, 0);
await p.close();

await d.atualizar('saloes', salaoId, { cfg:{ diasLiberados:30,
  cor:'#B0316A', tema:'claro', precoNaCapa:false } });
const q = await abrir();
verdade('desligado, o valor some da capa', !(await q.isVisible('.sv-cartao-preco')));
verdade('mas o serviço continua lá, com a duração',
  await q.isVisible('.sv-cartao-dur'));
igual('o fundo volta ao claro', await q.getAttribute('html', 'data-tema'), null);
igual('e a cor acompanha',
  await q.evaluate(() => getComputedStyle(document.documentElement)
    .getPropertyValue('--acao').trim()), '#B0316A');
igual('sobre o rosa, a letra volta a ser branca',
  await q.evaluate(() => getComputedStyle(document.querySelector('.boas-cta')).color),
  'rgb(255, 255, 255)');

/* O preço não some do sistema, só da CAPA: na hora de escolher o serviço ele
   é informação necessária, e esconder ali seria esconder o que se vai pagar. */
await q.click('.boas-cta');
await q.waitForTimeout(900);
const naEscolha = await q.evaluate(() =>
  document.getElementById('listaServicos').innerText);
verdade('e no passo de escolher o serviço o preço aparece de qualquer jeito — '
        + JSON.stringify(naEscolha.replace(/\s+/g,' ').slice(0, 60)),
  /R\$\s*40/.test(naEscolha));
igual('sem erro de JavaScript no tema claro',
  q.erros.length ? q.erros.join(' | ') : 0, 0);
await q.close();

/* ══════════════════════════════════════════════════════════════════════════
   A FOTO DA CASA COMO FAIXA DO TOPO

   É o que todo aplicativo de reserva faz, e por um motivo bom: a foto é a
   única coisa da tela que diz "este lugar existe e é assim". Aqui ela era um
   cartão comum no meio da página, depois do nome e dos botões — o lugar onde
   já não convence ninguém.

   E o nome NÃO vai por cima dela: escrever sobre foto de terceiro é apostar
   na foto. Uma parede clara e o texto branco some; uma escura e o preto
   some. Fica abaixo, no fundo da página, onde o contraste é sempre o mesmo.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Com foto do salão, e sem');

const FOTO = 'data:image/svg+xml;base64,' + Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="450">'
  + '<rect width="800" height="450" fill="#3b3128"/></svg>').toString('base64');
await d.atualizar('saloes', salaoId, { capa: FOTO });

const f = await abrir();
verdade('a foto vira a faixa do topo', await f.isVisible('.hero-foto'));
verdade('sangrando pelas bordas, sem moldura dos lados',
  await f.evaluate(() => document.querySelector('.hero-foto').getBoundingClientRect().width
                      >= document.documentElement.clientWidth - 1),
  'foto com moldura branca dos lados parece anúncio colado, não a casa');
verdade('e ela começa no topo da tela, sem faixa morta acima',
  await f.evaluate(() => document.querySelector('.hero-foto').getBoundingClientRect().top <= 1),
  'sobrava o cabeçalho vazio empurrando a imagem para baixo');
verdade('o nome fica ABAIXO da foto, não escrito por cima dela',
  await f.evaluate(() => {
    const foto = document.querySelector('.hero-foto').getBoundingClientRect();
    const nome = document.querySelector('.marca-salao h2').getBoundingClientRect();
    return nome.top >= foto.bottom;
  }));
verdade('e a mesma foto não aparece duas vezes na rolagem',
  await f.evaluate(() => !document.querySelector('#capaFoto .capa-foto')));
igual('sem erro de JavaScript', f.erros.length ? f.erros.join(' | ') : 0, 0);
await f.close();

await d.atualizar('saloes', salaoId, { capa: null });
const g = await abrir();
verdade('sem foto, não sobra faixa nenhuma', !(await g.isVisible('.hero-foto')));
verdade('e o cabeçalho volta, porque agora ele tem função',
  await g.evaluate(() => !document.body.classList.contains('capa-com-foto')));
verdade('a capa continua apresentável: selo, nome e endereço no fundo liso',
  await g.isVisible('.marca-selo') && await g.isVisible('.marca-salao h2'));
igual('sem erro de JavaScript', g.erros.length ? g.erros.join(' | ') : 0, 0);
await g.close();

/* ══════════════════════════════════════════════════════════════════════════
   O BOTÃO EM METAL, E O FUNDO QUE O DONO ANEXA

   O metal sai TODO da cor escolhida, via `color-mix`: nenhuma cor nova entra,
   então dourado vira ouro e grafite vira aço. E o brilho é opcional de duas
   formas — o dono desliga em Aparência, e quem pediu ao celular para reduzir
   animações não vê o movimento de jeito nenhum.

   O fundo é o caso perigoso: foto atrás de texto é ilegível em metade das
   vezes, e a foto é do salão — não dá para prever se vem parede branca ou
   madeira escura. Por isso o véu, e por isso o teste mede o véu.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O botão em metal, e o brilho');

await d.atualizar('saloes', salaoId, { cfg: { cor:'#C8A33C', tema:'escuro' } });
const mt = await abrir();
const botao = await mt.evaluate(() => {
  const b = document.querySelector('.boas-cta');
  const e = getComputedStyle(b);
  const luz = getComputedStyle(b, '::after');
  return { fundo:e.backgroundImage, borda:e.borderTopColor, sombra:e.boxShadow,
           anima:luz.animationName, recorta:e.overflow };
});
verdade('o botão principal é um degradê, não uma cor chapada',
  /gradient/.test(botao.fundo));
verdade('com borda própria, mais escura que o corpo — é o que dá o relevo',
  botao.borda && botao.borda !== 'rgba(0, 0, 0, 0)');
verdade('e sombra interna de luz em cima, que é o brilho da chapa',
  /inset/.test(botao.sombra));
verdade('a faixa de luz atravessa o botão', botao.anima === 'brilho-metal');
verdade('e fica presa dentro dele, sem vazar pela borda',
  botao.recorta === 'hidden');
igual('sem erro de JavaScript', mt.erros.length ? mt.erros.join(' | ') : 0, 0);
await mt.close();

await d.atualizar('saloes', salaoId, { cfg: { cor:'#C8A33C', tema:'escuro', brilho:false } });
const sb = await abrir();
verdade('desligado em Aparência, o movimento some',
  await sb.evaluate(() => getComputedStyle(
    document.querySelector('.boas-cta'), '::after').animationName === 'none'));
verdade('mas o metal fica — o que o dono desligou foi o movimento',
  await sb.evaluate(() => /gradient/.test(
    getComputedStyle(document.querySelector('.boas-cta')).backgroundImage)));
await sb.close();

/* Quem pediu ao sistema para parar de mover coisas não recebe uma faixa de
   luz varrendo a tela a cada cinco segundos — isso passa longe de enfeite
   para quem tem enxaqueca vestibular. */
const rm = await ctx.newPage();
await rm.emulateMedia({ reducedMotion:'reduce' });
await d.atualizar('saloes', salaoId, { cfg: { cor:'#C8A33C', tema:'escuro' } });
await rm.goto(BASE + '/agendar.html?salao=' + SLUG); await rm.waitForTimeout(2200);
verdade('com "reduzir animações" ligado no aparelho, o brilho não roda',
  await rm.evaluate(() => getComputedStyle(
    document.querySelector('.boas-cta'), '::after').animationName === 'none'));
await rm.close();

secao('O fundo que o dono anexa');

const PAREDE = 'data:image/svg+xml;base64,' + Buffer.from(
  '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="1600">'
  + '<rect width="900" height="1600" fill="#F5F0E6"/></svg>').toString('base64');
await d.atualizar('saloes', salaoId,
  { cfg: { cor:'#C8A33C', tema:'escuro', fundo: PAREDE } });

const fd = await abrir();
verdade('a foto vira uma camada presa na tela, atrás de tudo',
  await fd.evaluate(() => {
    const e = document.getElementById('fundoImagem');
    if(!e) return false;
    const c = getComputedStyle(e);
    return c.position === 'fixed' && Number(c.zIndex) < 0;
  }));
verdade('e NÃO por background-attachment:fixed, que treme no Safari do iPhone',
  await fd.evaluate(() => getComputedStyle(document.body).backgroundAttachment !== 'fixed'));
verdade('com um véu por cima — sem ele, metade das fotos deixa o texto ilegível',
  await fd.evaluate(() => {
    const v = document.getElementById('fundoVeu');
    if(!v) return false;
    const o = Number(getComputedStyle(v).opacity);
    return o > 0.5 && o < 1;
  }));
verdade('a página se marca como "tem fundo", para os cartões saberem',
  await fd.evaluate(() => document.body.classList.contains('tem-fundo')));
igual('sem erro de JavaScript', fd.erros.length ? fd.erros.join(' | ') : 0, 0);
await fd.close();

await d.atualizar('saloes', salaoId, { cfg: { cor:'#C8A33C', tema:'escuro' } });
const sf = await abrir();
verdade('sem fundo, nenhuma camada extra é criada',
  await sf.evaluate(() => !document.getElementById('fundoImagem')
                       && !document.getElementById('fundoVeu')));
verdade('e a página não se diz "com fundo"',
  await sf.evaluate(() => !document.body.classList.contains('tem-fundo')));
await sf.close();

/* ══════════════════════════════════════════════════════════════════════════
   SALÃO QUE NUNCA ESCOLHEU NADA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Salão antigo, que nunca abriu a tela de aparência');

await d.atualizar('saloes', salaoId, { cfg:{ diasLiberados:30 } });
const r = await abrir();
igual('não força fundo escuro', await r.getAttribute('html','data-tema'), null);
verdade('e a página abre com a cor do AgendaPro, sem migração nenhuma',
  await r.isVisible('.boas-cta'));
igual('sem erro de JavaScript', r.erros.length ? r.erros.join(' | ') : 0, 0);
await r.close();

await nav.close();
console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de aparência.`);
