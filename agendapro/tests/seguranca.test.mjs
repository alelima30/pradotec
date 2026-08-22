/* ===========================================================================
   AgendaPro — texto de gente não vira código

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/seguranca.test.mjs

   ── O QUE ESTAVA ABERTO ────────────────────────────────────────────────────
   `agendar()` é liberada para `anon` de propósito: a cliente marca horário sem
   criar conta, e é isso que faz o link funcionar. O nome que ela digita vai
   direto para `clientes.nome`.

   Do outro lado, o painel do dono desenhava a agenda com

       html += `<b>${hm(a.inicio)} ${nomeCliente(a.clienteId)}</b>`

   e jogava tudo em `innerHTML`. Então quem marcasse um horário com o nome

       <img src=x onerror="...">

   não estava escolhendo um nome: estava mandando código para rodar dentro da
   sessão do dono — a mesma sessão que lê a agenda inteira, a lista de
   clientes, o faturamento, e cujo token está no `localStorage` ao lado.

   Sem conta. Sem senha. Só marcar um horário.

   O segundo furo não pedia nem isso: `agendar.html?salao=XXX`, quando o
   apelido não existe, escrevia o XXX de volta na tela — também em innerHTML.
   Um link pronto, mandado por WhatsApp, rodava no navegador de quem abrisse.

   Os dois estão reproduzidos aqui, com a carga de verdade, e a asserção é a
   única que importa: o script NÃO rodou. Conferir se o texto "está escapado"
   seria conferir a minha própria ideia de como se escapa.

   ── E POR QUE O VARREDOR NO FIM ────────────────────────────────────────────
   Fechar os dois furos é fácil. O que é difícil é continuar fechado: são mais
   de cem interpolações nos dois arquivos, e a próxima linha que alguém
   escrever vai ser copiada de uma vizinha. A última seção lê o código-fonte e
   reprova nome, observação ou endereço que entre em HTML sem passar pelo
   `escapar()` — assim o furo volta a aparecer no CI, e não num painel.
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
const ok = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => a === b ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
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

/* A carga. `onerror` do <img> é a mais honesta para um teste: dispara sozinha,
   sem clique e sem espera, então "não rodou" aqui quer mesmo dizer não rodou.
   Um <script> injetado por innerHTML NÃO executa — usá-lo daria um teste
   verde sobre um painel furado. */
const CARGA = nome => `<img src=x onerror="window.INVADIDO='${nome}'">`;

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`seg-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Dona do Salão', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const criado = await d.chamar('criar_salao', { p_nome_salao:'Salão ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const salaoId = criado[0].salao_id, SLUG = criado[0].slug;
const prof = (await d.lista('profissionais', { salaoId }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: prof.id, diaSemana:i,
                                inicio:'08:00', fim:'20:00' });
const servico = await d.inserir('servicos', { salaoId, nome:'Corte', duracaoMin:30,
  preco:50, ativo:true, aceitaOnline:true });

const nav = await chromium.launch({ executablePath: CHROMIUM });

/* ══════════════════════════════════════════════════════════════════════════
   1. QUEM MARCA UM HORÁRIO NÃO ESCREVE NA SESSÃO DO DONO

   O caminho completo, sem atalho: chamada anônima ao `agendar()` — só com a
   chave publicável, a mesma que está à vista no config.js — e depois o painel
   do dono aberto de verdade, no navegador, com a sessão dele.
   ══════════════════════════════════════════════════════════════════════════ */
secao('A cliente marca horário com um nome hostil');

const amanha = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const marcado = await fetch(BASE + '/rest/v1/rpc/agendar', {
  method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
  body: JSON.stringify({ p_profissional: prof.id,
    p_inicio: amanha + 'T13:00:00-03:00', p_servicos:[servico.id],
    p_nome: CARGA('agenda') + 'Maria', p_telefone:'11977665544',
    p_obs: CARGA('obs') }) });
verdade('o banco aceita a marcação — é para aceitar, ela é uma cliente',
  marcado.ok, 'se isto falhar o resto do teste não prova nada');

const painel = await nav.newContext().then(c => c.newPage());
const errosPainel = [];
painel.on('pageerror', e => errosPainel.push(e.message));
await painel.addInitScript(([base, ses]) => {
  window.AGENDAPRO = { url: base, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(ses));
}, [BASE, d.sessao()]);
await painel.goto(BASE + '/app.html');
await painel.waitForTimeout(3500);
await painel.evaluate(() => mudarDia(1));
await painel.waitForTimeout(1200);

const naAgenda = await painel.evaluate(() => ({
  invadido: window.INVADIDO || null,
  cartoes: document.querySelectorAll('.ag').length,
  texto: (document.querySelector('.ag b') || {}).textContent || '',
  imgs: document.querySelectorAll('.ag img').length,
}));
verdade('o horário aparece na agenda do dono', naAgenda.cartoes === 1,
  JSON.stringify(naAgenda));
igual('e o nome NÃO vira código na sessão dele', naAgenda.invadido, null);
verdade('nenhuma tag entrou junto — é texto, e só',
  naAgenda.imgs === 0, `entraram ${naAgenda.imgs} <img>`);
/* E tem que continuar LEGÍVEL: escapar não pode virar "some com o nome".
   O dono precisa ver o que a pessoa digitou, inclusive para desconfiar. */
verdade('o dono lê o nome exatamente como foi digitado',
  naAgenda.texto.includes('<img src=x') && naAgenda.texto.includes('Maria'),
  JSON.stringify(naAgenda.texto));

/* ── E O ERRO QUE COSTUMA VIR JUNTO COM O CONSERTO ────────────────────────
   Escapar duas vezes transforma `&` em `&amp;` NA TELA. Ninguém percebe
   testando com `<script>`; percebe a dona da "Tesoura & Cia" vendo o nome da
   cliente sair errado na agenda dela. Então: um nome comum, com os três
   caracteres que o escapar mexe, tem que aparecer letra por letra igual. */
const COMUM = `Ana D'Ávila & Cia "Tesoura"`;
await fetch(BASE + '/rest/v1/rpc/agendar', {
  method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
  body: JSON.stringify({ p_profissional: prof.id,
    p_inicio: amanha + 'T15:00:00-03:00', p_servicos:[servico.id],
    p_nome: COMUM, p_telefone:'11966554433' }) });
// Recarrega: o painel baixou os dados antes desta segunda marcação existir.
await painel.reload();
await painel.waitForTimeout(3500);
await painel.evaluate(() => mudarDia(1));
await painel.waitForTimeout(1200);
igual('e um nome comum com & e aspas não vira &amp; na tela',
  await painel.evaluate(() => {
    const c = [...document.querySelectorAll('.ag b')]
      .find(x => x.textContent.includes('Ana'));
    return c ? c.textContent.replace(/^\d\d:\d\d /, '') : null;
  }), COMUM);

// A ficha da cliente e o detalhe do horário — os outros dois lugares onde o
// mesmo nome é desenhado, cada um com o seu próprio `innerHTML`.
await painel.evaluate(() => irPara('clientes'));
await painel.waitForTimeout(900);
igual('nem na lista de clientes',
  await painel.evaluate(() => window.INVADIDO || null), null);

await painel.evaluate(() => { irPara('agenda'); mudarDia(1); });
await painel.waitForTimeout(900);
await painel.evaluate(() => { const c = document.querySelector('.ag'); if(c) c.click(); });
await painel.waitForTimeout(900);
igual('nem no detalhe do horário, com a observação junto',
  await painel.evaluate(() => window.INVADIDO || null), null);

igual('e o painel não quebrou no caminho',
  errosPainel.length ? errosPainel.join(' | ') : 0, 0);
await painel.close();

/* ══════════════════════════════════════════════════════════════════════════
   2. UM LINK NÃO É UM PROGRAMA

   `?salao=` que não existe voltava para a tela dentro de innerHTML. Este é o
   mais fácil de explorar dos dois: não precisa marcar nada, não precisa que
   ninguém aceite nada — precisa que a pessoa clique num link.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Um link com carga no endereço');

const pag = await nav.newContext().then(c => c.newPage());
await pag.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
await pag.goto(BASE + '/agendar.html?salao=' + encodeURIComponent(CARGA('link')));
await pag.waitForTimeout(2800);

const doLink = await pag.evaluate(() => ({
  invadido: window.INVADIDO || null,
  imgs: document.querySelectorAll('.recado img').length,
  diz: (document.querySelector('.recado') || {}).textContent || '',
}));
igual('o apelido do link não roda como código', doLink.invadido, null);
verdade('nem entra como tag na página', doLink.imgs === 0);
verdade('e a página ainda explica o que houve',
  /não encontrado/i.test(doLink.diz), JSON.stringify(doLink.diz.slice(0,80)));
await pag.close();

/* ══════════════════════════════════════════════════════════════════════════
   3. O SALÃO TAMBÉM NÃO ESCREVE NO NAVEGADOR DA CLIENTE

   Menos grave que os dois de cima — aqui quem ataca é o dono, e as vítimas
   são as clientes dele. Mas é o mesmo furo, e um salão só precisa de um
   cadastro para existir. Vale também para o dia a dia: um salão chamado
   `Tesoura & Cia "O Corte"` quebrava o atributo `title` sem nenhuma má
   intenção — o mesmo conserto arruma os dois.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O nome do salão, na tela da cliente');

await d.atualizar('saloes', salaoId, { nome: CARGA('salao') + 'Studio' });
await d.atualizar('servicos', servico.id, { nome: CARGA('servico') + 'Corte' });

const cli = await nav.newContext().then(c => c.newPage());
await cli.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
await cli.goto(BASE + '/agendar.html?salao=' + SLUG);
await cli.waitForTimeout(2800);
igual('a capa mostra o nome sem executá-lo',
  await cli.evaluate(() => window.INVADIDO || null), null);

await cli.click('.boas-cta');
await cli.waitForTimeout(1200);
igual('e a lista de serviços também',
  await cli.evaluate(() => window.INVADIDO || null), null);
await cli.close();

await nav.close();

/* ══════════════════════════════════════════════════════════════════════════
   4. O VARREDOR — para não voltar na próxima linha escrita

   Lê os dois arquivos e procura texto de gente indo para HTML sem `escapar()`.
   Não é análise de verdade: é uma busca por padrão, e por isso as exceções
   abaixo são regras com motivo, não números de linha. Número de linha num
   teste envelhece na primeira edição do arquivo — e um varredor que aponta a
   linha errada é um varredor que alguém desliga.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Nenhum campo de gente entra em HTML sem escapar');

const CAMPOS = /(nome|apelido|obs|motivo|legenda|descricao|categoria|telefone|logradouro|complemento|bairro|cidade|slug|atendido)/i;

/* Escapar aqui não protegeria — ou estragaria a tela. */
const PODE_CRU = [
  { porque: 'o trecho já devolve HTML de propósito',
    vale: (e) => /\bmedidor\(|\bico\(|<[a-z]/i.test(e) },
];

const LINHA_PODE_CRU = [
  { porque: 'o título do abrirModal() vai por textContent, que não lê HTML',
    vale: (l) => /^\s*abrirModal\(`/.test(l) },
];

/* String JS dentro de atributo (`onclick="f('${x}')"`): o parser de HTML
   desfaz a entidade ANTES de o JS ler, então &#39; volta a ser aspa e escapar
   não fecha nada. Ali quem protege é a forma do dado — os dois casos que
   existem passam `slug`, que o banco trava em
   `^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$`: aspa não entra. Por isso o varredor
   ignora esta posição em vez de exigir um escapar que seria teatro. */
const dentroDeEvento = (linha, pos) => {
  for(const a of linha.matchAll(/\son[a-z]+="[^"]*"/gi))
    if(pos > a.index && pos < a.index + a[0].length) return true;
  return false;
};

let crus = 0;
for(const arq of ['app.html', 'agendar.html']){
  const linhas = fs.readFileSync(path.join(RAIZ, arq), 'utf8').split('\n');
  linhas.forEach((l, i) => {
    if(LINHA_PODE_CRU.some(r => r.vale(l))) return;
    for(const m of l.matchAll(/\$\{[^{}]*\}/g)){
      const e = m[0];
      if(!CAMPOS.test(e) || e.includes('escapar(')) continue;
      if(PODE_CRU.some(r => r.vale(e))) continue;
      if(dentroDeEvento(l, m.index)) continue;
      console.log(`      ${arq}:${i + 1}  ${e}`);
      crus++;
    }
  });
}
verdade('nenhuma interpolação de nome, observação ou endereço saiu crua',
  crus === 0, `${crus} sem escapar — a lista está acima`);

// A rede de segurança só vale se estiver armada. Se alguém apagar o
// `escapar()`, tudo acima passa a dar ReferenceError, não silêncio.
for(const arq of ['app.html', 'agendar.html'])
  verdade(`${arq} define o escapar() que usa`,
    /const escapar = /.test(fs.readFileSync(path.join(RAIZ, arq), 'utf8')));

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de segurança.`);
