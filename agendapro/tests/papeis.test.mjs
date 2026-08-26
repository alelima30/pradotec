/* ===========================================================================
   AgendaPro — o painel obedece o papel de quem entrou

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/papeis.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   O convite passou a dar login para a recepção e para quem atende. Mas o
   painel era o MESMO para todo mundo: a recepcionista entrava e via Plano,
   Meu salão e Equipe.

   O banco recusava a escrita dela — o RLS sempre esteve certo, e continua
   sendo ele quem recusa. O problema era a tela OFERECER: uma recepcionista
   lendo o valor do plano e a comissão das colegas, e levando erro em inglês
   quando tentava salvar algo que a própria tela deixou ela abrir.

   ── E UM PIOR, NA AGENDA ───────────────────────────────────────────────────
   Quem atende recebe do RLS só os atendimentos dela. Com as colunas das
   colegas desenhadas assim mesmo, a agenda MENTE: a coluna da Bia aparece
   vazia o dia inteiro, e quem olha conclui que a Bia está livre. Dizer a uma
   cliente "a Bia tem 14h" com a Bia cheia é pior do que não mostrar a Bia.

   ── COMO ELA MEDE ──────────────────────────────────────────────────────────
   Três pessoas de verdade, três navegadores separados, no MESMO salão. Não
   se troca papel por variável: o papel vem do vínculo, como no ar.
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
const tel = () => '+5511' + (100000000 + Math.floor(Math.random()*89999999));

// ── A dona monta o salão ───────────────────────────────────────────────────
const dDona = novaAba();
await dDona.criarConta({ email:`p-dona-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone: tel() });
const cr = await dDona.chamar('criar_salao', { p_nome_salao:'Salão Papéis ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const pg = exigir('./bancada/node_modules/pg');
const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(
  `update public.assinaturas set plano='time', status='ativa' where salao_id=$1`,
  [SALAO]);

const P1 = (await dDona.lista('profissionais', { salaoId: SALAO }))[0];
const P2 = await dDona.inserir('profissionais', { salaoId: SALAO, nome:'Bia',
  ativo:true, aceitaOnline:true, comissaoPct:40, cor:'#7C3AED' });
for(const p of [P1, P2])
  for(let i = 0; i <= 6; i++)
    await dDona.inserir('jornadas', { profissionalId: p.id, diaSemana:i,
                                      inicio:'08:00', fim:'18:00' });
await dDona.inserir('servicos', { salaoId: SALAO, nome:'Corte', duracaoMin:60,
  intervaloMin:0, preco:80, ativo:true, aceitaOnline:true });

// ── Convida a recepção e uma profissional ──────────────────────────────────
async function convidar(papel, nome, email){
  const r = await dDona.chamar('criar_convite',
    { p_salao: SALAO, p_papel: papel, p_para_quem: nome });
  const d = novaAba();
  await d.criarConta({ email, senha:'minhasenhaboa', nome, telefone: tel() });
  await d.chamar('aceitar_convite', { p_token: r.token });
  return d;
}
const dRecep = await convidar('recepcao', 'Rita Recep',
                              `p-recep-${marca}@teste.com`);
const dProf  = await convidar('profissional', 'Bia',
                              `p-prof-${marca}@teste.com`);

// A Bia do login é a MESMA Bia da agenda: sem isso ela não teria coluna.
const euBia = (dProf.sessaoAtual() || {}).usuarioId;
await banco.query(`update public.profissionais set perfil_id=$1 where id=$2`,
                  [euBia, P2.id]);

// Cada uma com um atendimento, amanhã.
const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(x => x.type === 'timeZoneName').value.replace('GMT','');
let n = 0;
for(const [prof, hora] of [[P1,'09:00'], [P2,'11:00']]){
  const c = await dDona.inserir('clientes', { salaoId: SALAO,
    nome:'Cliente ' + (++n), telefone:'11' + (900000000 + Math.floor(Math.random()*99999999)) });
  await dDona.inserir('agendamentos', { salaoId: SALAO, clienteId: c.id,
    profissionalId: prof.id, inicio:`${AMANHA}T${hora}:00${desl}`,
    fim:`${AMANHA}T${hora.replace(/^(\d+)/, m => String(+m+1).padStart(2,'0'))}:00${desl}`,
    status:'confirmado', origem:'recepcao', valorPrevisto: 80 });
}

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

async function abrirPainel(dados, rotulo){
  const p = await (await nav.newContext({ viewport:{width:1360,height:900} })).newPage();
  p.on('pageerror', e => erros.push(rotulo + ': ' + e.message));
  await p.addInitScript(([b, s]) => {
    window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
    localStorage.setItem('agendapro.sessao', JSON.stringify(s));
  }, [BASE, dados.sessao()]);
  await p.goto(BASE + '/app.html');
  await p.waitForTimeout(4000);
  return p;
}

const abasDe = p => p.evaluate(() =>
  [...document.querySelectorAll('#abas .aba')].map(b => b.dataset.chave));

/* ══════════════════════════════════════════════════════════════════════════
   1. A DONA VÊ TUDO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A dona');
const pgDona = await abrirPainel(dDona, 'dona');
const abasDona = await abasDe(pgDona);
igual('vê as 8 abas', abasDona.length, 8);
verdade('inclusive Plano e Meu salão',
  abasDona.includes('plano') && abasDona.includes('salao'));
igual('e o papel dela aparece na lateral',
  (await pgDona.evaluate(() =>
    (document.getElementById('latQuemPapel') || {}).textContent) || '').trim(),
  'Proprietário');

/* ══════════════════════════════════════════════════════════════════════════
   2. A RECEPÇÃO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A recepção');
const pgRecep = await abrirPainel(dRecep, 'recepcao');
const abasRecep = await abasDe(pgRecep);

verdade('trabalha: agenda, caixa e clientes',
  ['agenda','caixa','clientes'].every(k => abasRecep.includes(k)),
  JSON.stringify(abasRecep));
verdade('NÃO vê o Plano', !abasRecep.includes('plano'), JSON.stringify(abasRecep));
verdade('NÃO vê Meu salão', !abasRecep.includes('salao'), JSON.stringify(abasRecep));
verdade('NÃO vê Equipe — que traz a comissão das colegas',
  !abasRecep.includes('equipe'), JSON.stringify(abasRecep));

// A lista de serviços continua: ela precisa conferir preço no balcão.
verdade('vê a lista de Serviços', abasRecep.includes('servicos'));
await pgRecep.evaluate(() => irPara('servicos'));
await pgRecep.waitForTimeout(600);
verdade('com os preços à vista',
  await pgRecep.evaluate(() => /80/.test(
    document.getElementById('listaServicos').textContent)));
verdade('mas SEM botão de criar serviço',
  await pgRecep.evaluate(() => {
    const b = document.getElementById('btNovoServico');
    return !b || getComputedStyle(b).display === 'none';
  }));
verdade('e sem botão de editar',
  await pgRecep.evaluate(() =>
    !document.querySelector('#listaServicos button')));

// Digitar a aba escondida na mão não abre a tela.
await pgRecep.evaluate(() => irPara('plano'));
await pgRecep.waitForTimeout(400);
igual('e chamar a aba escondida cai na agenda',
  await pgRecep.evaluate(() => telaAtual), 'agenda');

// Na agenda ela vê a casa inteira — é o trabalho dela.
await pgRecep.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pgRecep.waitForTimeout(600);
igual('e na agenda ela vê as DUAS colunas da equipe',
  await pgRecep.evaluate(() => document.querySelectorAll('.grade .col').length), 2);
igual('com os dois atendimentos do dia',
  await pgRecep.evaluate(() => document.querySelectorAll('.ag').length), 2);

/* ══════════════════════════════════════════════════════════════════════════
   3. QUEM ATENDE
   ══════════════════════════════════════════════════════════════════════════ */
secao('Quem atende');
const pgProf = await abrirPainel(dProf, 'profissional');
const abasProf = await abasDe(pgProf);

verdade('vê a agenda', abasProf.includes('agenda'), JSON.stringify(abasProf));
verdade('NÃO vê Plano, Meu salão nem Equipe',
  !['plano','salao','equipe'].some(k => abasProf.includes(k)),
  JSON.stringify(abasProf));

await pgProf.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pgProf.waitForTimeout(700);

igual('e a grade dela tem UMA coluna: a dela',
  await pgProf.evaluate(() => document.querySelectorAll('.grade .col').length), 1);
verdade('com o nome dela no cabeçalho',
  await pgProf.evaluate(() => /Bia/.test(
    document.querySelector('.col-h .nm').textContent)),
  await pgProf.evaluate(() => document.querySelector('.col-h .nm').textContent));

/* Este é o ponto: sem a filtragem, a coluna da colega apareceria VAZIA — o
   RLS não entrega os atendimentos dela — e a agenda diria que a colega está
   livre. */
verdade('e nenhuma coluna de colega aparecendo vazia',
  await pgProf.evaluate(() => ![...document.querySelectorAll('.col-h .nm')]
    .some(n => /Ju Barbosa/.test(n.textContent))),
  'coluna vazia de colega faz a agenda mentir sobre quem está livre');

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
await banco.end();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
