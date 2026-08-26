/* ===========================================================================
   AgendaPro — o contador e a grade têm que contar a MESMA coisa

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/grade.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   Relatado com print: o topo da agenda dizia "1 atendimento · R$ 50,00
   previsto no dia" e a grade estava vazia.

   Não é um contador errado. São duas contas diferentes sobre a mesma coisa:

     · o contador usa `agendaDoDia(dia)` — TODO agendamento do salão naquele
       dia, seja de quem for, a que hora for;
     · a grade desenha só o que cabe em `profsAtivos()` e só entre `ABRE`
       (08:00) e `FECHA` (20:00), posicionando por `y(min)`.

   Onde as duas discordam, o atendimento é contado e não é desenhado. E some
   em silêncio: o dono vê o número, procura o cartão, não acha, e o que ele
   conclui é que o sistema perdeu o horário da cliente.

   Três formas de cair nisso, e as três são rotina num salão:
     1. horário fora de 08:00–20:00 (a recepção marca a que hora quiser);
     2. profissional desativado depois de já ter horário marcado;
     3. horário que começa dentro e termina depois das 20:00.
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
await d.criarConta({ email:`grade-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Grade ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte', duracaoMin:60,
  intervaloMin:0, preco:50, ativo:true, aceitaOnline:true });

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');
const emQue = hhmm => `${AMANHA}T${hhmm}:00${desl}`;

/* A recepção marcando pelo painel: escreve direto na tabela, sem passar por
   `horarios_livres`. É por aqui que entra horário fora da grade.

   ⚠ `encaixe` por parâmetro, e não sempre ligado, porque a diferença importa:
   07:00 e 21:00 numa jornada 08:00–18:00 SÃO encaixes de verdade — é o que o
   título de cada seção diz, "a recepção encaixou a cliente cedo". Marcar
   assim é dizer a verdade sobre o dado. Já o das 10:00 cabe na jornada e não
   é exceção nenhuma; ligar a marca nele esconderia uma regressão, porque um
   `encaixe = true` universal faria o gatilho ser pulado em todo o arquivo. */
let nCliente = 0;
async function recepcaoMarca(profId, hhmmIni, hhmmFim, encaixe = false){
  const c = await d.inserir('clientes', { salaoId: SALAO,
    nome: 'Cliente ' + (++nCliente),
    telefone: '11' + (900000000 + Math.floor(Math.random()*99999999)) });
  const a = await d.inserir('agendamentos', { salaoId: SALAO, clienteId: c.id,
    profissionalId: profId, inicio: emQue(hhmmIni), fim: emQue(hhmmFim),
    status:'confirmado', origem:'recepcao', valorPrevisto: 50, encaixe });
  await d.inserir('agendamento_servicos', { agendamentoId: a.id, servicoId: SV.id,
    ordem:1, duracaoMin:60, preco:50, comissaoPct:0 });
  return { agendamento: a, cliente: c };
}

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const dono = await ctx.newPage();
const erros = [];
dono.on('pageerror', e => erros.push(e.message));

async function abrirNoDia(){
  await dono.addInitScript(([b, s]) => {
    window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
    localStorage.setItem('agendapro.sessao', JSON.stringify(s));
  }, [BASE, d.sessao()]);
  await dono.goto(BASE + '/app.html');
  await dono.waitForTimeout(3500);
  await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
  await dono.waitForTimeout(600);
}

// O que o dono LÊ no topo, e o que ele CONSEGUE ALCANÇAR na tela. Não conto
// `.ag` no HTML: um cartão em `top:-60px` existe no DOM e não existe para
// quem está olhando. A pergunta é se o horário está ao alcance do dono.
const contador = () => dono.evaluate(() => {
  const k = document.querySelector('#kpisDia .kpi .v');
  return k ? Number(k.textContent) : null;
});
const alcancaveis = () => dono.evaluate(() => {
  const col = document.querySelector('.col');
  const alturaCol = col ? col.getBoundingClientRect().height : 0;
  return [...document.querySelectorAll('.ag')].filter(el => {
    const t = parseFloat(el.style.top || '0');
    const h = parseFloat(el.style.height || '0');
    return t >= 0 && t + h <= alturaCol + 1;
  }).length;
});

/* ══════════════════════════════════════════════════════════════════════════
   1. O CASO DO PRINT
   ══════════════════════════════════════════════════════════════════════════ */
secao('Horário antes das 08:00 — a recepção encaixou a cliente cedo');

await recepcaoMarca(PROF.id, '07:00', '08:00', true);
await abrirNoDia();

igual('o topo conta o atendimento', await contador(), 1);
igual('e o dono consegue chegar nele na tela', await alcancaveis(), 1);

/* ══════════════════════════════════════════════════════════════════════════
   2. DEPOIS DAS 20:00
   ══════════════════════════════════════════════════════════════════════════ */
secao('Horário depois das 20:00 — noite de formatura, festa, véspera de Natal');

await recepcaoMarca(PROF.id, '21:00', '22:00', true);
await dono.reload(); await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(600);

igual('o topo conta os dois', await contador(), 2);
igual('e os dois estão ao alcance', await alcancaveis(), 2);

/* ══════════════════════════════════════════════════════════════════════════
   3. PROFISSIONAL DESATIVADO COM HORÁRIO JÁ MARCADO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A profissional saiu do salão, mas a cliente dela já estava marcada');

// O plano do teste grátis só comporta uma pessoa, e quem troca assinatura é a
// plataforma — não o dono. Aqui a troca é feita por fora, como ela seria.
const pg = exigir('./bancada/node_modules/pg');
const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(
  `update public.assinaturas set plano='time', status='ativa' where salao_id=$1`,
  [SALAO]);

const P2 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Jucelia',
  ativo:true, aceitaOnline:true, comissaoPct:40 });
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: P2.id, diaSemana:i,
                                inicio:'09:00', fim:'19:00' });
await recepcaoMarca(P2.id, '10:00', '11:00');
await d.atualizar('profissionais', P2.id, { ativo:false });

await dono.reload(); await dono.waitForTimeout(3500);
await dono.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await dono.waitForTimeout(600);

igual('o topo conta os três', await contador(), 3);
igual('e nenhum some da tela por causa do desligamento', await alcancaveis(), 3);

/* ══════════════════════════════════════════════════════════════════════════
   4. E NADA DISSO PODE QUEBRAR A TELA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
await banco.end();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
