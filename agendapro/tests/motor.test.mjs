/* ===========================================================================
   AgendaPro — o motor da tela e o motor do banco dão a mesma resposta

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/motor.test.mjs

   ── POR QUE ESTE ARQUIVO EXISTE ────────────────────────────────────────────
   A regra de disponibilidade está escrita duas vezes, de propósito:

     porque_nao_cabe()  no banco  — é a AUTORIDADE, roda num gatilho e não
                                    tem como ser contornada
     porqueNaoCabe()    na tela   — é a EXPLICAÇÃO, e precisa ser instantânea:
                                    o aviso muda a cada tecla no campo de hora

   Duas implementações da mesma regra divergem calado. A que ninguém confere é
   a que quebra — e o modo como isso aparece no salão é o pior possível: a
   tela diz que dá, a recepção clica, e o banco recusa com a cliente na
   frente.

   Então aqui as duas são perguntadas sobre os MESMOS dados, em dezenas de
   horários, e as respostas são comparadas uma a uma.
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
const falso   = (m, c, d) => !c ? ok(m) : nao(m, d);
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

/* ── O cenário ────────────────────────────────────────────────────────────
   Ana: 09:00–12:00 e 13:00–18:00 (almoço no meio, como duas faixas)
   Bia: 09:00–18:00, com bloqueio de 16:00 às 17:00
   Um atendimento da Ana às 14:00–15:00, para haver choque de verdade.
   ────────────────────────────────────────────────────────────────────── */
const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`motor-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Dona Motor', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Motor ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const pgLib = exigir('./bancada/node_modules/pg');
const banco = new pgLib.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(
  `update public.assinaturas set plano='time', status='ativa' where salao_id=$1`,
  [SALAO]);

const ANA = (await d.lista('profissionais', { salaoId: SALAO }))[0];
await d.atualizar('profissionais', ANA.id, { nome: 'Ana' });
const BIA = await d.inserir('profissionais', { salaoId: SALAO, nome:'Bia',
  ativo:true, aceitaOnline:true, comissaoPct:40, cor:'#7C3AED' });

for(let i = 0; i <= 6; i++){
  await d.inserir('jornadas', { profissionalId: ANA.id, diaSemana:i, inicio:'09:00', fim:'12:00' });
  await d.inserir('jornadas', { profissionalId: ANA.id, diaSemana:i, inicio:'13:00', fim:'18:00' });
  await d.inserir('jornadas', { profissionalId: BIA.id, diaSemana:i, inicio:'09:00', fim:'18:00' });
}

const SV = await d.inserir('servicos', { salaoId: SALAO, nome:'Corte',
  duracaoMin:60, intervaloMin:0, preco:100, ativo:true, aceitaOnline:true });

const AMANHA = new Intl.DateTimeFormat('en-CA', { timeZone:'America/Sao_Paulo' })
  .format(new Date(Date.now() + 864e5));
const desl = new Intl.DateTimeFormat('en-US', { timeZone:'America/Sao_Paulo',
  timeZoneName:'longOffset' }).formatToParts(new Date(AMANHA + 'T12:00:00Z'))
  .find(p => p.type === 'timeZoneName').value.replace('GMT','');
const inst = hhmm => `${AMANHA}T${hhmm}:00${desl}`;

const CLI = await d.inserir('clientes', { salaoId: SALAO, nome:'Cliente Um',
  telefone: '11' + (900000000 + Math.floor(Math.random()*99999999)) });
await d.inserir('agendamentos', { salaoId: SALAO, clienteId: CLI.id,
  profissionalId: ANA.id, inicio: inst('14:00'), fim: inst('15:00'),
  status:'confirmado', origem:'recepcao', valorPrevisto:100 });
await d.inserir('bloqueios', { salaoId: SALAO, profissionalId: BIA.id,
  inicio: inst('16:00'), fim: inst('17:00'), motivo:'Dentista' });

/* ── O painel ─────────────────────────────────────────────────────────── */
const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();
const erros = [], recados = [];
pg.on('pageerror', e => erros.push(e.message));
pg.on('dialog', async dlg => { recados.push(dlg.message()); await dlg.accept(); });
await pg.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);
await pg.evaluate(dd => { diaAtual = dd; pintar(); }, AMANHA);
await pg.waitForTimeout(600);

/* ══════════════════════════════════════════════════════════════════════════
   1. A TELA CARREGOU O QUE PRECISA PARA DECIDIR
   Sem esta seção, toda comparação abaixo ficaria verde com um `bd` vazio —
   as duas diriam "cabe" para tudo, uma por saber e a outra por não saber.
   ══════════════════════════════════════════════════════════════════════════ */
secao('A tela tem os dados na mão');

const carregou = await pg.evaluate(() => ({
  profs: doSalao(bd.profissionais).length,
  jornadas: (bd.profissionais || []).reduce((s,p) =>
    s + Object.values(p.jornada || {}).reduce((n,f) => n + (f ? f.length : 0), 0), 0),
  ags: doSalao(bd.agendamentos).length,
  bloqueios: doSalao(bd.bloqueios).length,
}));
igual('dois profissionais', carregou.profs, 2);
verdade('com jornada carregada', carregou.jornadas >= 21, JSON.stringify(carregou));
igual('um atendimento marcado', carregou.ags, 1);
igual('e um bloqueio', carregou.bloqueios, 1);

/* ══════════════════════════════════════════════════════════════════════════
   2. AS DUAS RESPOSTAS, HORÁRIO A HORÁRIO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A tela e o banco concordam, das 06:00 às 21:00');

const horas = [];
for(let m = 6*60; m <= 21*60; m += 30) horas.push(m);

const nomes = { Ana: ANA.id, Bia: BIA.id };
let divergencias = [], comparados = 0, coubes = 0, naos = 0;

for(const [quem, pid] of Object.entries(nomes)){
  for(const m of horas){
    const hh = String(Math.floor(m/60)).padStart(2,'0') + ':'
             + String(m%60).padStart(2,'0');
    const fimM = m + 60;
    const fh = String(Math.floor(fimM/60)).padStart(2,'0') + ':'
             + String(fimM%60).padStart(2,'0');

    const naTela = await pg.evaluate(([p, dd, i, f]) =>
      avaliarHorario(p, dd, i, f, null), [pid, AMANHA, m, fimM]);

    const noBanco = (await banco.query(
      `select public.avaliar_horario($1, $2::timestamptz, $3::timestamptz) as r`,
      [pid, inst(hh), inst(fh)])).rows[0].r;

    comparados++;
    if(naTela.cabe) coubes++; else naos++;

    if(naTela.cabe !== noBanco.cabe){
      divergencias.push(`${quem} ${hh}: tela ${naTela.cabe ? 'CABE' : 'não'}`
        + ` / banco ${noBanco.cabe ? 'CABE' : 'não'} (${noBanco.motivo || ''})`);
    } else if(!naTela.cabe && naTela.encaixavel !== noBanco.encaixavel){
      divergencias.push(`${quem} ${hh}: encaixável diverge —`
        + ` tela ${naTela.encaixavel} / banco ${noBanco.encaixavel}`);
    }
  }
}

verdade(`${comparados} horários comparados`, comparados === 62, String(comparados));
/* Se tudo coubesse, ou nada coubesse, a comparação não provaria nada: duas
   funções que sempre dizem a mesma coisa concordam por acidente. */
verdade('e há dos dois tipos de resposta na amostra', coubes > 5 && naos > 5,
  `cabe=${coubes} não=${naos}`);
verdade('nenhuma divergência entre a tela e o banco', divergencias.length === 0,
  divergencias.slice(0, 6).join('\n      '));

/* ══════════════════════════════════════════════════════════════════════════
   3. OS CASOS QUE IMPORTAM, CONFERIDOS UM A UM
   A varredura acima pega divergência. Estes aqui provam que a resposta é a
   CERTA — as duas poderiam concordar estando as duas erradas.
   ══════════════════════════════════════════════════════════════════════════ */
secao('E as respostas são as certas');

const naTela = (pid, i, f) => pg.evaluate(([p, dd, a, b]) =>
  avaliarHorario(p, dd, a, b, null), [pid, AMANHA, i, f]);

verdade('Ana às 10:00 cabe', (await naTela(ANA.id, 10*60, 11*60)).cabe);
verdade('Ana às 12:00 (almoço) não cabe',
  !(await naTela(ANA.id, 12*60, 13*60)).cabe);
verdade('e o almoço é encaixável, porque é jornada',
  (await naTela(ANA.id, 12*60, 13*60)).encaixavel);
verdade('Ana às 14:30 choca com o atendimento das 14:00',
  !(await naTela(ANA.id, 14*60+30, 15*60+30)).cabe);
falso('e choque NÃO é encaixável',
  (await naTela(ANA.id, 14*60+30, 15*60+30)).encaixavel);
verdade('Bia às 16:00 esbarra no bloqueio',
  !(await naTela(BIA.id, 16*60, 17*60)).cabe);
falso('e bloqueio NÃO é encaixável',
  (await naTela(BIA.id, 16*60, 17*60)).encaixavel);
verdade('a mensagem do bloqueio traz o motivo escrito pelo dono',
  /Dentista/.test((await naTela(BIA.id, 16*60, 17*60)).motivo));
verdade('17:30 + 60 min passa das 18:00 e não cabe',
  !(await naTela(BIA.id, 17*60+30, 18*60+30)).cabe);
verdade('mas 17:00 às 18:00, encostado no fim, cabe',
  (await naTela(BIA.id, 17*60, 18*60)).cabe);

/* ══════════════════════════════════════════════════════════════════════════
   4. O ENCAIXE, DO CLIQUE ATÉ O BANCO
   ══════════════════════════════════════════════════════════════════════════ */
secao('O encaixe pede confirmação e fica registrado');

const marcarPeloPainel = async (pid, ini, fim) => {
  await pg.evaluate(([p, dd, i]) => abrirNovo(p, i), [pid, AMANHA, ini]);
  await pg.waitForTimeout(500);
  await pg.evaluate(([dd, i, f, sv]) => {
    document.querySelector('.serv-op input[value="' + sv + '"]').checked = true;
    document.getElementById('fData').value = dd;
    document.getElementById('fInicio').value =
      String(Math.floor(i/60)).padStart(2,'0') + ':' + String(i%60).padStart(2,'0');
    document.getElementById('fNome').value = 'Encaixe Teste';
    document.getElementById('fTel').value = '11' + (900000000 + (i % 99999999));
    recalcularFim();
  }, [AMANHA, ini, fim, SV.id]);
  await pg.waitForTimeout(300);
  recados.length = 0;
  await pg.evaluate(() => salvarAgendamento());
  await pg.waitForTimeout(2500);
};

// 08:00 é antes de a Ana abrir: só a jornada está no caminho.
await marcarPeloPainel(ANA.id, 8*60, 9*60);
verdade('a tela pediu confirmação, dizendo que é encaixe',
  recados.some(t => /encaixe/i.test(t)), JSON.stringify(recados));

const encaixado = (await banco.query(
  `select encaixe, encaixe_por from public.agendamentos
    where profissional_id = $1 and inicio = $2::timestamptz`,
  [ANA.id, inst('08:00')])).rows[0];
verdade('e o banco gravou como encaixe', encaixado && encaixado.encaixe === true,
  JSON.stringify(encaixado));
verdade('com o nome de quem confirmou', !!(encaixado && encaixado.encaixe_por),
  'encaixe anônimo não responde "quem marcou fora da jornada?"');

// Já com o encaixe das 08:00 gravado, tentar 14:30 (choque) tem que recusar
// sem oferecer encaixe nenhum.
recados.length = 0;
await marcarPeloPainel(ANA.id, 14*60+30, 15*60+30);
verdade('choque é recusado sem oferecer encaixe',
  recados.some(t => /já tem/i.test(t)) && !recados.some(t => /Confirmar o encaixe/i.test(t)),
  JSON.stringify(recados));
const naoEntrou = (await banco.query(
  `select count(*)::int as n from public.agendamentos
    where profissional_id = $1 and inicio = $2::timestamptz`,
  [ANA.id, inst('14:30')])).rows[0].n;
igual('e nada foi gravado', naoEntrou, 0);

/* ══════════════════════════════════════════════════════════════════════════
   5. O BANCO SEGURA MESMO SEM A TELA
   A tela é a explicação; a autoridade é o gatilho. Aqui a tela é pulada.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Sem passar pela tela, o banco recusa igual');

let erroDireto = null;
try{
  await d.inserir('agendamentos', { salaoId: SALAO, clienteId: CLI.id,
    profissionalId: ANA.id, inicio: inst('03:00'), fim: inst('04:00'),
    status:'confirmado', origem:'recepcao', valorPrevisto:100 });
}catch(e){ erroDireto = e.message; }
verdade('03:00 pela API direto é recusado', erroDireto !== null);
verdade('com o motivo em português', /jornada/i.test(erroDireto || ''),
  String(erroDireto).slice(0, 120));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await banco.end();
await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
