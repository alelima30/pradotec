/* ===========================================================================
   AgendaPro — o funil inteiro NA NUVEM: cadastrar, sair, voltar e entrar

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/funil-nuvem.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   Já havia um teste do cadastro — o cadastro.test.mjs — e ele passava. Só que
   ele abre `criar.html?demo=1`, o modo demonstração, que grava no navegador e
   não fala com banco nenhum. Quer dizer: o funil só era exercitado no modo em
   que ele NÃO PODE quebrar.

   Foi por isso que estes três defeitos conviveram com a suíte verde:

     · o "Criando…" ia parar no botão do passo 1, escondido, e o botão que a
       pessoa apertou ficava aceso e sem resposta — "o botão não vai";
     · quatro tabelas eram pedidas com um filtro que o Postgres recusava, e o
       painel abria sem jornada de trabalho e com o Caixa vazio;
     · ninguém nunca tinha feito LOGIN em teste nenhum.

   Nenhum dos três aparece em modo demonstração. Todos os três aparecem aqui.

   Este arquivo faz o caminho de uma pessoa de verdade: cria a conta contra um
   Postgres com o schema e o RLS de verdade, fecha o navegador, volta numa aba
   limpa — como quem entra no dia seguinte, de outro computador — e entra com
   a senha que escolheu. No fim, o painel tem que mostrar o salão dela.
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok = (m) => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + '\n      ' + d); falhou++; };
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c) => c ? ok(m) : nao(m, 'esperava verdadeiro');

const nav = await chromium.launch({ executablePath: CHROMIUM });

// Uma aba nova, com tudo o que ela disser anotado. As respostas 4xx e 5xx
// entram na lista porque foi assim que os quatro `400` passaram despercebidos:
// o código os engolia e devolvia lista vazia, e a tela não tinha como saber.
async function abrir(ctx) {
  const p = await ctx.newPage();
  p.erros = []; p.ruins = [];
  p.on('pageerror', e => p.erros.push(e.message));
  p.on('console', m => { if (m.type() === 'error') p.erros.push(m.text()); });
  p.on('response', r => {
    if (r.status() >= 400) p.ruins.push(r.status() + ' ' + r.url().replace(BASE, ''));
  });
  return p;
}

const digitar = (p, sel, txt) => p.click(sel).then(() => p.type(sel, txt, { delay: 4 }));
const passoAtual = p => p.evaluate(() =>
  [...document.querySelectorAll('.passo')].findIndex(e => e.classList.contains('on')) + 1);

// Cada rodada precisa de e-mail e apelido que ninguém usou: o banco da bancada
// não é zerado entre execuções, e "e-mail já cadastrado" faria o teste falhar
// por sujeira, não por defeito.
const marca     = Date.now().toString(36) + Math.floor(Math.random() * 1000);
const EMAIL     = 'funil-' + marca + '@studioprado.com.br';
const SENHA     = 'minhasenhaboa';
const NOME      = 'Alessandro Prado';
const NOMESALAO = 'Studio Funil ' + marca;

const ctx1 = await nav.newContext({ viewport: { width: 430, height: 780 } });
const p = await abrir(ctx1);

console.log('\nA conta e o salão, contra um Postgres de verdade');

await p.goto(BASE + '/criar.html');
await p.waitForTimeout(500);
verdade('a página abre em modo nuvem, não em demonstração',
  await p.evaluate(() => !!(window.Dados && Dados.ligado)));

await digitar(p, '#fNome', NOME);
await digitar(p, '#fEmail', EMAIL);
await digitar(p, '#fSenha', SENHA);
await p.click('button.grande:has-text("Continuar")');
await p.waitForTimeout(400);
igual('a conta passa do passo 1', await passoAtual(p), 2);

await digitar(p, '#fSalao', NOMESALAO);
await p.selectOption('#fTipo', { index: 1 });
await digitar(p, '#fZap', '51998876655');
await p.waitForTimeout(200);

/* ── O BOTÃO TEM QUE RESPONDER AO DEDO QUE O APERTOU ──────────────────────
   Na bancada a resposta volta em milissegundos, e aí qualquer coisa parece
   instantânea. No celular da pessoa, não: o cadastro fala com o servidor duas
   vezes. Então a rede é atrasada de propósito, e a pergunta é a que ela faz —
   "apertei; mudou alguma coisa?".

   Sem o atraso este teste passaria com o defeito no lugar, que é o mesmo
   motivo de ele ter durado tanto.
   ──────────────────────────────────────────────────────────────────────── */
await p.route('**/auth/v1/**', async r => { await new Promise(f => setTimeout(f, 900)); r.continue(); });
await p.route('**/rest/v1/**', async r => { await new Promise(f => setTimeout(f, 900)); r.continue(); });

await p.click('#btCriar');
await p.waitForTimeout(350);

const visivel = await p.evaluate(() => {
  const b = [...document.querySelectorAll('button.grande')].find(x => x.offsetParent !== null);
  return b && { txt: b.textContent.trim(), desligado: b.disabled };
});
igual('enquanto espera o servidor, o botão à vista diz que está trabalhando',
  visivel && visivel.txt, 'Criando…');
verdade('e fica desabilitado, para o segundo clique não criar tudo de novo',
  visivel && visivel.desligado);

await p.waitForTimeout(4000);
igual('o cadastro chega ao passo 3', await passoAtual(p), 3);
const link = await p.textContent('#linkFinal');
verdade('e entrega o link da cliente com o apelido do salão',
  /agendar\.html\?salao=studio-funil-/.test(link));
igual('sem nenhum erro de JavaScript', p.erros.length, 0);
igual('e sem nenhuma resposta de erro do servidor', p.ruins.join(' | '), '');
await ctx1.close();

console.log('\nVoltar no dia seguinte e entrar');

/* Contexto NOVO: sem localStorage, sem cookie, sem sessão. É a diferença
   entre "continua funcionando na mesma aba" e "a conta existe no banco". */
const ctx2 = await nav.newContext({ viewport: { width: 1280, height: 900 } });
const q = await abrir(ctx2);
await q.goto(BASE + '/entrar.html');
await q.waitForTimeout(3600);          // a cortina de abertura leva 3 segundos

await q.fill('#email', EMAIL);
await q.fill('#senha', SENHA);
await q.click('#btEntrar');
await q.waitForTimeout(3500);

igual('a senha escolhida no cadastro abre o painel', new URL(q.url()).pathname, '/app.html');

const corpo = await q.evaluate(() => document.body.innerText.replace(/\s+/g, ' '));
verdade('e o painel mostra o salão desta pessoa, não outro',
  corpo.includes(NOMESALAO));

/* ── O CAIXA E A JORNADA ──────────────────────────────────────────────────
   Aqui moravam os quatro `400`. Eles não derrubavam a tela: viravam lista
   vazia em silêncio, e o painel abria com cara de salão novo. Como o defeito
   não fazia barulho, o teste tem que fazer — qualquer 4xx reprova. */
igual('nenhuma pergunta malfeita chega ao banco', q.ruins.join(' | '), '');
igual('e nenhum erro de JavaScript no painel', q.erros.length, 0);

// `bd` é declarado com `let` no topo do script da página. `let` global não
// vira propriedade de `window` — mas o nome continua alcançável daqui, que é
// por onde se lê o banco em memória do painel.
const tabelas = await q.evaluate(() => {
  const b = (typeof bd !== 'undefined' && bd) ? bd : {};
  return { jornadas: Array.isArray(b.jornadas), pagamentos: Array.isArray(b.pagamentos),
           itens: Array.isArray(b.comanda_itens) };
});
verdade('as tabelas sem `salao_id` chegam na tela como lista, não como buraco',
  tabelas.jornadas && tabelas.pagamentos && tabelas.itens);

/* ── CADASTRAR UM CLIENTE PELO PAINEL ──────────────────────────────────────
   Este é o caminho mais comum que existe neste sistema: a recepção anota
   alguém no balcão. E era o que estava quebrado na nuvem — a tela cunhava id
   no formato "xxe7qkwou" e o Postgres respondia

       clientes: invalid input syntax for type uuid: "xxe7qkwou"

   Nada criado pelo painel chegava ao banco: cliente, serviço, agendamento,
   comanda, profissional, jornada. Todos os testes do painel rodavam em
   `?demo=1`, onde id é só texto no localStorage e qualquer coisa serve — pela
   terceira vez, o defeito morava no modo que os testes não visitavam.

   O `alert` do navegador é capturado: se a gravação falhar, ele aparece com a
   mensagem crua do Postgres, e é isso que este teste tem que ver. */
const avisos = [];
q.on('dialog', d => { avisos.push(d.message()); d.accept(); });

await q.click('a:has-text("Clientes"), button:has-text("Clientes")');
await q.waitForTimeout(500);
await q.click('button:has-text("+ Cliente")');
await q.waitForTimeout(400);
await q.fill('#kNome', 'Jucelia Barbosa');
await q.fill('#kTel', '11981113251');
await q.click('button:has-text("Salvar")');
await q.waitForTimeout(2500);

igual('gravar um cliente novo não devolve erro nenhum', avisos.join(' | '), '');
verdade('e ele aparece na lista da tela',
  (await q.textContent('body')).includes('Jucelia Barbosa'));

/* A prova que importa: recarregar. O que existe só na memória some aqui, e
   era exatamente esse o estado antes — a linha na tela, nada no banco. */
await q.reload();
await q.waitForTimeout(3000);
await q.click('a:has-text("Clientes"), button:has-text("Clientes")');
await q.waitForTimeout(800);
verdade('e continua lá depois de recarregar, porque foi para o banco',
  (await q.textContent('body')).includes('Jucelia Barbosa'));

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações do funil na nuvem.`);
