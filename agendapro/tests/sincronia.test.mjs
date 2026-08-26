/* ===========================================================================
   AgendaPro — a agenda do dono se atualiza sozinha

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/sincronia.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   O painel lia o banco UMA vez, ao abrir, e nunca mais. O dono deixa o painel
   aberto o dia inteiro — é para isso que ele serve. A cliente marcava pelo
   link às 10h, o horário entrava no banco na hora, e a tela do dono continuava
   mostrando a agenda de quando ele abriu.

   Medido: painel aberto, cliente marca, dono olha o dia certo → 0 cartões.
   Recarregando a página → 1 cartão. O dado estava lá o tempo todo; quem não
   sabia era a tela. Num sistema de agendamento isso não é atraso, é o defeito
   central: o dono diz à cliente que ela não tem nada marcado.

   ── E O RISCO DA PRÓPRIA CORREÇÃO ──────────────────────────────────────────
   Puxar novidade do banco é a parte fácil. A difícil é não atropelar o dono:
   se ele está com uma comanda pela metade e a sincronização joga o banco por
   cima, o trabalho some sem aviso — que é pior que a tela desatualizada.

   Por isso metade desta suíte não testa se o horário novo aparece. Testa se o
   que o dono digitou continua lá depois.
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
const ok  = m => { console.log('  ✓ ' + m); passou++; };
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

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`sinc-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Sincronia ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte', duracaoMin:60,
  intervaloMin:0, preco:70, ativo:true, aceitaOnline:true });

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');
const emQue = hhmm => `${AMANHA}T${hhmm}:00${desl}`;

// A cliente marcando pelo link, sem login — como acontece de verdade.
const clienteMarca = (hhmm, nome) => fetch(BASE + '/rest/v1/rpc/agendar', {
  method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
  body: JSON.stringify({ p_profissional: PROF.id, p_inicio: emQue(hhmm),
    p_servicos:[SV.id], p_nome: nome,
    p_telefone: '11' + (900000000 + Math.floor(Math.random()*99999999)) }) });

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const dono = await ctx.newPage();
const erros = [];
dono.on('pageerror', e => erros.push(e.message));
await dono.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await dono.goto(BASE + '/app.html');
await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(600);

const cartoes = () => dono.evaluate(() => document.querySelectorAll('.ag').length);
const sincronizar = async () => {
  await dono.evaluate(() => sincronizarAgenda());
  await dono.waitForTimeout(1200);
};

/* ══════════════════════════════════════════════════════════════════════════
   1. O CASO RELATADO
   ══════════════════════════════════════════════════════════════════════════ */
secao('Com o painel ABERTO, o horário da cliente aparece');

igual('a agenda começa vazia', await cartoes(), 0);

const m1 = await clienteMarca('14:00', 'Primeira Cliente');
verdade('a cliente marcou pelo link', m1.ok);

await sincronizar();
igual('e o horário aparece SEM recarregar a página', await cartoes(), 1);

const texto = await dono.evaluate(() =>
  (document.querySelector('.ag') || {}).textContent.replace(/\s+/g,' ').trim());
verdade('com o nome de quem marcou', /Primeira Cliente/.test(texto || ''),
  JSON.stringify(texto));
verdade('e com o serviço', /Corte/.test(texto || ''), JSON.stringify(texto));

verdade('e o dono é avisado de que chegou horário novo',
  await dono.evaluate(() => !!document.getElementById('recadoNovos')),
  'a grade mudaria sozinha sem ninguém perceber — pior se for noutro dia');

/* ══════════════════════════════════════════════════════════════════════════
   2. O RISCO DA CORREÇÃO: o trabalho do dono não pode ser atropelado
   ══════════════════════════════════════════════════════════════════════════ */
secao('O que o dono está editando sobrevive à sincronização');

// O dono muda uma observação e AINDA NÃO salvou.
await dono.evaluate(() => {
  const a = bd.agendamentos[0];
  a.obs = 'ANOTACAO DO DONO QUE NAO PODE SUMIR';
  a.status = 'em_atendimento';
});
// Enquanto isso, outra cliente marca.
await clienteMarca('16:00', 'Segunda Cliente');
await sincronizar();

const sobreviveu = await dono.evaluate(() => {
  const a = bd.agendamentos.find(x => x.obs === 'ANOTACAO DO DONO QUE NAO PODE SUMIR');
  return a ? { obs: a.obs, status: a.status } : null;
});
verdade('a anotação não salva do dono continua na tela', !!sobreviveu,
  'a sincronização apagou o trabalho dele');
igual('e o status que ele mudou também', sobreviveu && sobreviveu.status, 'em_atendimento');
igual('ao mesmo tempo, o horário da outra cliente entrou', await cartoes(), 2);

/* E a gravação seguinte não pode apagar o que a cliente marcou. Este é o
   ponto mais perigoso da correção inteira: `subir()` apaga do banco tudo que
   está no retrato e não está na tela. Se a sincronização tivesse mexido só
   num dos dois lados, salvar aqui destruiria o horário da cliente. */
await dono.evaluate(() => salvar());
await dono.waitForTimeout(3000);

const noBanco = await d.lista('agendamentos', { salaoId: SALAO });
const vivos = noBanco.filter(a => ['pendente','confirmado','em_atendimento'].includes(a.status));
igual('depois de o dono SALVAR, os dois horários continuam no banco', vivos.length, 2);
verdade('e a anotação do dono foi gravada',
  noBanco.some(a => a.obs === 'ANOTACAO DO DONO QUE NAO PODE SUMIR'),
  JSON.stringify(noBanco.map(a => a.obs)));

/* ══════════════════════════════════════════════════════════════════════════
   3. O CANCELAMENTO DA CLIENTE TAMBÉM CHEGA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Quando a cliente cancela, o dono vê');

const terceira = await clienteMarca('10:00', 'Vai Cancelar').then(r => r.json());
const tk = (Array.isArray(terceira) ? terceira[0] : terceira).token;
await sincronizar();
igual('o terceiro horário aparece', await cartoes(), 3);

await fetch(BASE + '/rest/v1/rpc/cancelar_agendamento', {
  method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
  body: JSON.stringify({ p_token: tk }) });
await sincronizar();

const cancelado = await dono.evaluate(() => {
  const a = bd.agendamentos.find(x => x.status === 'cancelado');
  return !!a;
});
verdade('e o cancelamento dela chega ao painel do dono', cancelado,
  'o dono guardaria a cadeira para quem não vem mais');

/* ══════════════════════════════════════════════════════════════════════════
   4. QUANDO A SINCRONIZAÇÃO NÃO PODE RODAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('E quando ela sai de cena, de propósito');

// Janela aberta: repintar por baixo de um formulário meio preenchido é o
// tipo de "ajuda" que faz perder trabalho.
await dono.evaluate(() => abrirModal('Teste', '<p>formulário aberto</p>', []));
await dono.waitForTimeout(400);
await clienteMarca('11:00', 'Enquanto A Janela Abre');
const antesDaJanela = await cartoes();
const trouxe = await dono.evaluate(() => sincronizarAgenda());
await dono.waitForTimeout(800);
igual('com uma janela aberta, ela não traz nada', trouxe, 0);
igual('e não repinta a grade por baixo', await cartoes(), antesDaJanela);

await dono.evaluate(() => fecharModal());
await dono.waitForTimeout(500);
await sincronizar();
verdade('fechada a janela, o horário que ficou esperando entra',
  (await cartoes()) > antesDaJanela,
  `antes ${antesDaJanela}, depois ${await cartoes()}`);

igual('nenhum erro de JavaScript no painel',
  erros.length ? erros.join(' | ') : 0, 0);

await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de sincronia.`);
