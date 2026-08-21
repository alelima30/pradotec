/* ===========================================================================
   AgendaPro — esqueci minha senha, do pedido até entrar com a nova

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/senha.test.mjs

   POR QUE ESTE ARQUIVO EXISTE
   "Esqueci minha senha" era um texto explicativo mandando falar no WhatsApp.
   Numa ferramenta que o salão abre todo dia, isso não é um recurso faltando:
   é um cliente parado no balcão sem conseguir abrir a agenda, e um recado
   para você às sete da manhã de sábado.

   O caminho tem quatro pedaços e três deles falham calados quando quebram —
   o e-mail que não sai, o link que não traz o token, o token que não vira
   sessão. Por isso o teste vai do começo ao fim: pede, pesca o token como o
   e-mail traria, abre a página, troca a senha, e ENTRA com ela.

   O que a bancada finge: só a caixa postal. O resto — a conta, a sessão que
   nasce do token, o PUT que troca a senha — acontece de verdade.
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
const verdade = (m, c) => c ? ok(m) : nao(m, 'esperava verdadeiro');
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

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const EMAIL = `senha-${marca}@teste.com`;
const VELHA = 'senhavelhaboa';
const NOVA  = 'senhanovaboa123';

secao('Uma conta que existe, e a dona esqueceu a senha');
const dona = novaAba();
await dona.criarConta({ email: EMAIL, senha: VELHA, nome: 'Marta Prado',
  telefone: '+5551' + (100000000 + (Date.now() % 99999999)) });
await dona.chamar('criar_salao', { p_nome_salao: 'Salao Senha ' + marca,
  p_tipo:'salao', p_telefone:'(51) 99887-6655', p_documento:null, p_origem:null });
ok('conta e salão criados');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport: { width: 1280, height: 900 } });
const p = await ctx.newPage();
const erros = [];
p.on('pageerror', e => erros.push(e.message));
p.on('console', m => { if (m.type() === 'error') erros.push(m.text()); });

secao('Pedir o link');
await p.goto(BASE + '/entrar.html');
await p.waitForTimeout(3600);          // a cortina de abertura

/* Clicar sem preencher o e-mail: é o que a pessoa faz, porque o botão está
   logo abaixo do campo e ela chegou aqui justamente sem lembrar de nada. */
await p.click('.esqueci');
await p.waitForTimeout(400);
verdade('sem e-mail preenchido, pede o e-mail em vez de falhar calado',
  (await p.textContent('#recado')).includes('Digite seu e-mail'));

await p.fill('#email', EMAIL);
await p.click('.esqueci');
await p.waitForTimeout(1500);
const recado = await p.textContent('#recado');
verdade('com o e-mail, diz que o link foi enviado', /a caminho/.test(recado));

/* ── A FRASE NÃO PODE CONFIRMAR QUE A CONTA EXISTE ─────────────────────────
   "Enviamos para o seu e-mail" conta a quem perguntou que aquele endereço é
   cliente. Com uma lista de e-mails e esta tela, dá para separar quem usa o
   sistema de quem não usa — de graça, sem senha nenhuma. Por isso a frase é
   condicional, e por isso o Supabase também responde 200 para endereço que
   não existe. */
verdade('e a frase é condicional — não confirma que a conta existe',
  /[Ss]e existir/.test(recado));

const semConta = 'ninguem-' + marca + '@teste.com';
await p.fill('#email', semConta);
await p.click('.esqueci');
await p.waitForTimeout(1500);
igual('e-mail que NÃO existe recebe a mesma resposta, palavra por palavra',
  (await p.textContent('#recado')).replace(semConta, 'X'),
  recado.replace(EMAIL, 'X'));

secao('Abrir o link do e-mail');

// O que o e-mail traria. A bancada guarda; o Supabase manda pela caixa postal.
const rec = await fetch(BASE + '/_recuperacao?email=' + encodeURIComponent(EMAIL))
  .then(r => r.json());
verdade('o pedido gerou um token de recuperação', !!rec.access_token);

const q = await ctx.newPage();
const errosQ = [];
q.on('pageerror', e => errosQ.push(e.message));
q.on('console', m => { if (m.type() === 'error') errosQ.push(m.text()); });

await q.goto(BASE + '/nova-senha.html#access_token=' + rec.access_token
  + '&type=recovery&refresh_token=r0');
await q.waitForTimeout(900);

verdade('o formulário de senha nova aparece',
  await q.evaluate(() => document.getElementById('form').style.display !== 'none'));

/* O token não pode ficar na barra de endereço: histórico do navegador é um
   lugar onde ele sobrevive à sessão, e ele É uma senha temporária. */
igual('e o token sai da barra de endereço', new URL(q.url()).hash, '');

secao('Trocar a senha');

await q.fill('#senha', 'curta');
await q.click('#btSalvar');
await q.waitForTimeout(400);
verdade('senha curta é recusada, com o número exato',
  (await q.textContent('#aviso')).includes('8 caracteres'));

await q.fill('#senha', NOVA);
await q.fill('#senha2', NOVA + 'x');
await q.click('#btSalvar');
await q.waitForTimeout(400);
verdade('senhas diferentes são recusadas antes de ir ao servidor',
  (await q.textContent('#aviso')).includes('não são iguais'));

await q.fill('#senha2', NOVA);
await q.click('#btSalvar');
await q.waitForTimeout(2500);
/* Depois da troca a página navega para o painel, e aí `#aviso` já não existe
   — ler sem tolerância é o teste falhando por sucesso. */
const depois = {
  url: new URL(q.url()).pathname,
  aviso: await q.evaluate(() => {
    const a = document.getElementById('aviso'); return a ? a.textContent : '';
  }).catch(() => ''),
};
verdade('com as duas iguais, troca e abre o painel — ' + JSON.stringify(depois),
  depois.url === '/app.html' || depois.aviso.includes('Senha trocada'));
igual('sem erro de JavaScript na troca', errosQ.length ? errosQ.join(' | ') : 0, 0);

secao('A senha nova funciona, e a velha não');

const r2 = await ctx.newPage();
await r2.goto(BASE + '/entrar.html'); await r2.waitForTimeout(3600);
await r2.fill('#email', EMAIL);
await r2.fill('#senha', NOVA);
await r2.click('#btEntrar');
await r2.waitForTimeout(3500);
igual('entra com a senha nova', new URL(r2.url()).pathname, '/app.html');

/* A metade que importa. Trocar de senha sem invalidar a velha não é trocar de
   senha: é acrescentar uma. Quem pediu a troca porque desconfiou que alguém
   viu a senha antiga continuaria exposto — e sairia da tela achando o
   contrário, que é pior que não ter o recurso. */
const r5 = await ctx.newPage();
await r5.goto(BASE + '/entrar.html'); await r5.waitForTimeout(3600);
await r5.fill('#email', EMAIL);
await r5.fill('#senha', VELHA);
await r5.click('#btEntrar');
await r5.waitForTimeout(3000);
igual('e a senha VELHA não entra mais', new URL(r5.url()).pathname, '/entrar.html');
verdade('dizendo que não confere, em português',
  (await r5.textContent('#recado')).includes('não conferem'));

secao('Chegar sem o link');

const r3 = await ctx.newPage();
await r3.goto(BASE + '/nova-senha.html');
await r3.waitForTimeout(700);
verdade('quem abre a página direto é avisado, em vez de ver um formulário que vai falhar',
  (await r3.textContent('#aviso')).includes('Falta o link'));

const r4 = await ctx.newPage();
await r4.goto(BASE + '/nova-senha.html#error=access_denied'
  + '&error_description=Email+link+is+invalid+or+has+expired');
await r4.waitForTimeout(700);
const venceu = await r4.textContent('#aviso');
verdade('e link vencido é traduzido, com o caminho para pedir outro',
  venceu.includes('já venceu') && venceu.includes('Esqueci minha senha'));

igual('sem erro de JavaScript na tela de entrar', erros.length, 0);

await nav.close();
console.log('');
if (falhou) { console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de senha.`);
