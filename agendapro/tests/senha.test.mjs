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

/* ── PEDIR DUAS VEZES SEGUIDAS ────────────────────────────────────────────
   O Supabase limita quantos e-mails saem seguidos e responde, palavra por
   palavra, "For security purposes, you can only request this after 35
   seconds". Nós dizíamos "verifique a conexão" — e a pessoa vai olhar o
   wi-fi, o cabo e o celular, sendo que o que faltava era esperar meio minuto.

   O limite não é sobre a conta: vale igual para endereço que existe e para
   endereço que não existe. Contá-lo não vaza nada. Por isso este é o único
   motivo de falha que esta tela pode nomear.

   A resposta é fingida aqui de propósito: fazer a bancada limitar de verdade
   deixaria as outras seis chamadas de `recover` deste arquivo instáveis. */
secao('Pedir o link duas vezes seguidas');
{
  const t = await ctx.newPage();
  await t.route('**/auth/v1/recover**', r => r.fulfill({ status: 429,
    contentType: 'application/json',
    body: JSON.stringify({ code: 429, error_code: 'over_email_send_rate_limit',
      msg: 'For security purposes, you can only request this after 35 seconds.' }) }));
  await t.goto(BASE + '/entrar.html'); await t.waitForTimeout(3600);
  await t.fill('#email', EMAIL);
  await t.click('.esqueci');
  await t.waitForTimeout(1200);
  const dito = (await t.textContent('#recado')).replace(/\s+/g, ' ').trim();
  verdade('diz para esperar, com o número de segundos que o servidor mandou — '
          + JSON.stringify(dito.slice(0, 60)),
    dito.includes('Espere 35 segundos'));
  verdade('e não manda conferir a conexão, que não tem nada a ver',
    !/conex[aã]o/i.test(dito));
  await t.close();
}

secao('Abrir o link do e-mail');

// O que o e-mail traria. A bancada guarda; o Supabase manda pela caixa postal.
const rec = await fetch(BASE + '/_recuperacao?email=' + encodeURIComponent(EMAIL))
  .then(r => r.json());
verdade('o pedido gerou um token de recuperação', !!rec.access_token);

/* ── PARA ONDE O LINK DEVOLVE A PESSOA ─────────────────────────────────────
   O `redirect_to` era calculado no dados.js e NÃO era enviado: ele vai na
   query, não no corpo. Sem ele o Supabase usa o "Site URL" do projeto — a
   raiz do site, ou `localhost:3000` num projeto recém-criado. A pessoa
   clica no link do e-mail e chega numa página que não tem nada a ver, sem
   token e sem erro. O recurso inteiro não funcionava, e em silêncio.

   Este teste ia até o `nova-senha.html` com o token na mão, então nunca
   passava pelo link de verdade — era o pedaço do caminho que ficava de fora. */
verdade('e o link do e-mail aponta para a tela de trocar a senha — '
        + JSON.stringify(rec.redirect_to),
  /\/nova-senha\.html$/.test(String(rec.redirect_to || '')));

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

/* ══════════════════════════════════════════════════════════════════════════
   O NÚMERO NA CARA DA PESSOA

   Esta seção existe por causa de um print: entrar.html, no ar, respondendo

       Não consegui entrar: 400

   a quem tinha acabado de digitar e-mail e senha. O 400 estava certo — o que
   faltava era LER o motivo. O GoTrue manda a frase no campo `msg`; o
   `conferir()` lia `message`, `error_description` e `error`, os três
   ausentes. Sobrava `status + ' ' + statusText`, e em HTTP/2 não existe
   frase de status: `statusText` vem vazio. Daí o número sozinho.

   E a bancada respondia na forma ANTIGA (`error_description`), que nós
   líamos — então a suíte inteira ficava verde por cima do defeito. É a
   mesma armadilha de sempre nesta base: a bancada mais fácil que a produção.
   Ela agora responde como o serviço real, e o que vem abaixo guarda a porta.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Quando o login falha, a tela diz o quê — nunca só o número');

const semNavegador = novaAba();
let pegou = null;
try{ await semNavegador.entrar({ email: EMAIL, senha: 'senhaerradademais' }); }
catch(e){ pegou = e; }
verdade('senha errada chega como erro', !!pegou);
igual('com o código estável do Supabase, e não com o texto em inglês',
  pegou && pegou.codigo, 'invalid_credentials');
igual('e com a frase do servidor, não com o status',
  pegou && pegou.message, 'Invalid login credentials');
verdade('a mensagem nunca é só um número de três dígitos',
  !/^\s*\d{3}\s*$/.test(String(pegou && pegou.message)));

secao('Conta criada e e-mail ainda não confirmado');

/* O segundo motivo de 400, e o mais cruel: a conta EXISTE, a senha está
   certa, e mesmo assim não entra. Sem uma frase que explique isso, a pessoa
   conclui que perdeu a conta e tenta criar outra — que esbarra em "e-mail já
   cadastrado". Beco fechado dos dois lados. */
const SEMCONF = `naoconf-${marca}@teste.com`;
const recem = novaAba();
await recem.criarConta({ email: SEMCONF, senha: VELHA, nome: 'Rita Alves',
  telefone: '+5551' + (200000000 + (Date.now() % 99999999)) });
await fetch(BASE + '/_naoconfirmado', { method:'POST',
  headers:{ 'Content-Type':'application/json' },
  body: JSON.stringify({ email: SEMCONF }) });

const r6 = await ctx.newPage();
/* Aqui a falha é ESPERADA, então dois barulhos no console também são: o
   `console.error` que a própria tela escreve de propósito (é o que resolve o
   chamado depois) e o "Failed to load resource" com que o navegador narra o
   400. Contar esses dois como defeito faria o teste reprovar justamente
   quando o caminho funciona. O que não se tolera é o resto. */
const errosR6 = [];
const esperado = t => t.startsWith('[AgendaPro] falha ao entrar:')
                   || /Failed to load resource.*400/.test(t);
r6.on('pageerror', e => errosR6.push(e.message));
r6.on('console', m => {
  if(m.type() === 'error' && !esperado(m.text())) errosR6.push(m.text());
});
await r6.goto(BASE + '/entrar.html'); await r6.waitForTimeout(3600);
await r6.fill('#email', SEMCONF);
await r6.fill('#senha', VELHA);
await r6.click('#btEntrar');
await r6.waitForTimeout(3000);

const aviso6 = (await r6.textContent('#recado')).replace(/\s+/g, ' ').trim();
igual('conta sem confirmação não entra', new URL(r6.url()).pathname, '/entrar.html');
verdade('e a tela diz que falta confirmar, em português — ' + JSON.stringify(aviso6.slice(0, 80)),
  aviso6.includes('confirmar o e-mail'));
verdade('com o endereço para onde a mensagem foi', aviso6.includes(SEMCONF));
verdade('e um botão para reenviar, em vez de um beco sem saída',
  await r6.isVisible('#btReenviar'));

/* A regressão que este arquivo inteiro persegue, dita em uma linha. */
for(const [texto, quando] of [[await r5.textContent('#recado'), 'senha errada'],
                              [aviso6, 'e-mail não confirmado']]){
  verdade('nada de "Não consegui entrar: <número>" com ' + quando,
    !/Não consegui entrar:\s*\d+\s*$/.test(texto.replace(/\s+/g,' ').trim()));
}

await r6.click('#btReenviar');
await r6.waitForTimeout(1500);
verdade('e o botão reenvia de verdade, e conta que reenviou',
  (await r6.textContent('#recado')).includes('Mandamos de novo'));
igual('sem erro de JavaScript no caminho da confirmação',
  errosR6.length ? errosR6.join(' | ') : 0, 0);

/* ── A VOLTA DO LINK DE CONFIRMAÇÃO ───────────────────────────────────────
   O Supabase valida o link e devolve a pessoa para cá com a sessão pronta no
   #fragmento. Sem ler o fragmento, ela chegaria numa tela de login pedindo a
   senha outra vez — com o token pendurado na barra de endereço, sem uso. */
const sessao = await fetch(BASE + '/auth/v1/token?grant_type=password', {
  method:'POST', headers:{ 'Content-Type':'application/json', apikey:'k' },
  body: JSON.stringify({ email: EMAIL, password: NOVA }) }).then(r => r.json());

const r7 = await ctx.newPage();
await r7.goto(BASE + '/entrar.html#access_token=' + sessao.access_token
  + '&refresh_token=' + sessao.refresh_token + '&type=signup');
await r7.waitForTimeout(3000);
igual('quem volta do link de confirmação entra direto no painel',
  new URL(r7.url()).pathname, '/app.html');
igual('e o token não fica na barra de endereço', new URL(r7.url()).hash, '');

const r8 = await ctx.newPage();
await r8.goto(BASE + '/entrar.html#error=access_denied&error_code=otp_expired'
  + '&error_description=Email+link+is+invalid+or+has+expired');
await r8.waitForTimeout(900);
const venceuConf = await r8.textContent('#recado');
verdade('e link de confirmação vencido é dito, em vez de um formulário calado',
  venceuConf.includes('já venceu'));
igual('com o fragmento limpo também aí', new URL(r8.url()).hash, '');

/* ══════════════════════════════════════════════════════════════════════════
   O LINK QUE CAI NO LUGAR ERRADO

   Mandar o `redirect_to` não basta: o Supabase só o respeita se ele estiver
   na lista de Redirect URLs do projeto. Fora dela — e por descuido ela fica
   fora — a pessoa é devolvida ao "Site URL", que costuma ser a raiz do site.

   E a raiz fazia `location.replace('entrar.html')`, que joga o #fragmento
   FORA. Com ele ia embora o token de recuperação, que É a prova de
   identidade de quem esqueceu a senha: ela clicava no link do e-mail e
   chegava numa tela de login pedindo justamente a senha que não lembra.

   Um caminho que depende de uma caixa de texto no painel do Supabase estar
   preenchida sem erro de digitação não é um caminho: é uma armadilha. Aqui
   o link cai nos dois lugares errados mais prováveis, e tem que dar certo
   nos dois.
   ══════════════════════════════════════════════════════════════════════════ */
secao('O link cai na raiz do site, ou na tela de login');

await fetch(BASE + '/auth/v1/recover', { method:'POST',
  headers:{ 'Content-Type':'application/json', apikey:'k' },
  body: JSON.stringify({ email: EMAIL }) });
const rec2 = await fetch(BASE + '/_recuperacao?email=' + encodeURIComponent(EMAIL))
  .then(r => r.json());
const pedaco = '#access_token=' + rec2.access_token + '&refresh_token=r0&type=recovery';

const r9 = await ctx.newPage();
await r9.goto(BASE + '/index.html' + pedaco);
await r9.waitForTimeout(1500);
igual('caindo na raiz do site, o link ainda chega na tela de senha nova',
  new URL(r9.url()).pathname, '/nova-senha.html');
verdade('com o formulário pronto — e não um login pedindo a senha esquecida',
  await r9.evaluate(() => document.getElementById('form').style.display !== 'none'));

/* Recuperação não é login. O token de recuperação TAMBÉM é uma sessão
   válida, então a tela de entrar o aceitaria e mandaria a pessoa ao painel
   — logada, e sem nunca ter trocado a senha. Ela sairia dali achando que
   trocou, e no dia seguinte só a senha velha valeria. */
const r10 = await ctx.newPage();
await r10.goto(BASE + '/entrar.html' + pedaco);
await r10.waitForTimeout(3000);
igual('caindo na tela de login, vai para a troca — recuperação não é login',
  new URL(r10.url()).pathname, '/nova-senha.html');

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
