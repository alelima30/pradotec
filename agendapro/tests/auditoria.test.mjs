/* ===========================================================================
   AgendaPro — auditoria da agenda

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/auditoria.test.mjs

   Esta suíte não confere se a tela desenha. Confere se a AGENDA está certa —
   que é outra coisa, e é a que faz o salão perder cliente quando erra.

   A pergunta que ela responde, e que nenhuma outra respondia inteira:
   dá para dois clientes ocuparem a mesma cadeira? Dá para marcar em cima do
   almoço, depois de fechar, ontem, ou por cima de um atendimento que já
   existe? A duração do serviço é respeitada de verdade, ou só na tela?

   Tudo aqui bate no Postgres de verdade, com o schema e o RLS de verdade —
   inclusive as chamadas ANÔNIMAS, que é como a cliente marca.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

/* Conexão direta ao banco, só para uma coisa: subir o plano do salão de teste.
   A cota de profissionais é travada por gatilho, e `assinaturas` é escrita
   SÓ pela plataforma — de propósito, para o dono não se promover sozinho.
   Uma auditoria de agenda precisa de dois profissionais na casa, então o
   plano sobe por fora, como a plataforma faria. */
const exigir = createRequire(import.meta.url);
const pg = exigir('./bancada/node_modules/pg');
const bd = new pg.Client({
  host: process.env.PGHOST || '/tmp', port: +(process.env.PGPORT || 5444),
  user: process.env.PGUSER || 'postgres', database: process.env.PGBANCO || 'app' });
await bd.connect();

const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const achados = [];
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++;
                        achados.push(m + (d ? ' — ' + d : '')); };
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

/* A cliente marca SEM LOGIN. Todo teste de agendamento passa por aqui, e não
   pela sessão do dono — senão a suíte prova o caminho errado. */
async function anon(fn, args){
  const r = await fetch(`${BASE}/rest/v1/rpc/${fn}`, {
    method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
    body: JSON.stringify(args) });
  const corpo = await r.json().catch(() => null);
  return { ok: r.ok, corpo,
           erro: r.ok ? null : (corpo && (corpo.message || corpo.msg)) || 'erro' };
}

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const d = novaAba();
await d.criarConta({ email:`aud-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Dona do Salão', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const criado = await d.chamar('criar_salao', { p_nome_salao:'Salão Auditoria ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = criado[0].salao_id, SLUG = criado[0].slug;

const salao = (await d.lista('saloes', { id: SALAO }))[0];
const FUSO = salao.fuso;

/* Dois profissionais: um é o que veio com o salão, o outro é criado aqui. É
   o par mínimo para provar que a agenda de um não tranca a do outro. */
/* E o horizonte da agenda vai a 300 dias. O padrão é 30 — e é correto: a
   auditoria precisa de datas espalhadas, mas isso é necessidade do TESTE, não
   defeito do produto. Deixar o padrão faria a suíte reprovar o comportamento
   certo, que é justamente o erro que uma auditoria não pode cometer. */
await bd.query(`update public.saloes
                   set cfg = coalesce(cfg,'{}'::jsonb) || '{"diasLiberados":300}'::jsonb
                 where id = $1`, [SALAO]);

await bd.query(`delete from public.assinaturas where salao_id = $1`, [SALAO]);
await bd.query(`insert into public.assinaturas (salao_id, plano, status)
                values ($1, 'salao', 'ativa')`, [SALAO]);

const P1 = (await d.lista('profissionais', { salaoId: SALAO }))[0];
const P2 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Segunda Pessoa',
  cor:'#7C3AED', ativo:true, aceitaOnline:true, comissaoPct:0 });

// Jornada 08:00–18:00 todos os dias, nos dois.
for(const p of [P1, P2])
  for(let i = 0; i <= 6; i++)
    await d.inserir('jornadas', { profissionalId: p.id, diaSemana:i,
                                  inicio:'08:00', fim:'18:00' });

// Um serviço de cada duração que o enunciado pede.
const SV = {};
for(const min of [15, 30, 45, 60, 90, 120])
  SV[min] = await d.inserir('servicos', { salaoId: SALAO, nome:`Serviço ${min}min`,
    duracaoMin: min, intervaloMin: 0, preco: min, ativo:true, aceitaOnline:true });

/* Datas de trabalho: sempre no futuro, longe do "cedo demais" de 30 minutos,
   e num dia em que a jornada existe (aqui, todos). */
const emDias = n => {
  const t = new Date(Date.now() + n * 864e5);
  return t.toISOString().slice(0, 10);
};
const DIA = emDias(3), DIA2 = emDias(4), DIA3 = emDias(5);

/* O instante que o banco entende. A jornada é hora de parede no fuso do
   salão, então a conta tem que ser feita nesse fuso — fazer no fuso de quem
   roda o teste é o erro clássico, e ele passa despercebido em UTC. */
function instante(dia, hhmm){
  const [h, m] = hhmm.split(':').map(Number);
  // Descobre o deslocamento do fuso do salão naquele dia.
  const meioDia = new Date(`${dia}T12:00:00Z`);
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone: FUSO, timeZoneName:'longOffset' });
  const desl = fmt.formatToParts(meioDia).find(p => p.type === 'timeZoneName').value
                  .replace('GMT', '') || '+00:00';
  const pad = n => String(n).padStart(2, '0');
  return `${dia}T${pad(h)}:${pad(m)}:00${desl}`;
}

/* ⚠ O PostgREST devolve `setof timestamptz` como LISTA DE OBJETOS —
   `[{horarios_livres:'...'}]`, não `['...']`. A primeira versão desta função
   devolvia os objetos crus, e `temHora()` comparava `new Date({...})` com uma
   data: sempre falso. Resultado: TODA asserção negativa desta suíte
   ("12:00 não é oferecido", "17:30 não é oferecido") passava por vácuo, sem
   provar nada. É o defeito clássico de teste — verde porque não olhou. */
const livres = async (prof, dia, servicos) => {
  const r = await anon('horarios_livres', { p_profissional: prof, p_data: dia,
                                            p_servicos: servicos });
  if(!r.ok || !Array.isArray(r.corpo)) return [];
  return r.corpo.map(x => (x && typeof x === 'object') ? Object.values(x)[0] : x);
};
// "10:00" aparece na lista de horários livres?
const temHora = (lista, dia, hhmm) => {
  const alvo = new Date(instante(dia, hhmm)).getTime();
  return lista.some(x => new Date(x).getTime() === alvo);
};
const marcarEm = (prof, dia, hhmm, sv, nome, tel) =>
  anon('agendar', { p_profissional: prof, p_inicio: instante(dia, hhmm),
    p_servicos: [sv], p_nome: nome || 'Cliente Teste',
    p_telefone: tel || '11' + (900000000 + Math.floor(Math.random()*99999999)) });

/* ══════════════════════════════════════════════════════════════════════════
   A. SOBREPOSIÇÃO — a matriz do enunciado

   Um atendimento das 10:00 às 11:00. As quatro tentativas em volta, mais o
   caso que TEM de passar (11:00, encostado) e o que não pode ser bloqueado
   (o outro profissional na mesma hora).
   ══════════════════════════════════════════════════════════════════════════ */
secao('A. Sobreposição de horário no mesmo profissional');

const base = await marcarEm(P1.id, DIA, '10:00', SV[60].id, 'Cliente Base');
verdade('marca 10:00–11:00 (60 min) para começar', base.ok, base.erro);

for(const [hora, dur, deveAceitar, porque] of [
  ['10:00', 60, false, 'mesmo início, mesmo fim'],
  ['10:30', 60, false, 'começa no meio do que já existe'],
  ['09:30', 60, false, 'termina no meio do que já existe'],
  ['10:15', 15, false, 'cabe inteiro dentro do que já existe'],
  ['09:00', 60, true,  'termina exatamente quando o outro começa'],
  ['11:00', 60, true,  'começa exatamente quando o outro termina'],
]){
  const r = await marcarEm(P1.id, DIA, hora, SV[dur].id);
  igual(`${hora} (${dur}min) — ${porque}`, r.ok, deveAceitar);
  if(r.ok && !deveAceitar) achados.push(`SOBREPOSIÇÃO ACEITA: ${hora} ${dur}min`);
}

/* E o horário ocupado tem que sumir da LISTA também, não só ser recusado no
   fim. Oferecer e recusar depois é pior que não oferecer. */
const listaP1 = await livres(P1.id, DIA, [SV[60].id]);
verdade('e 10:00 nem aparece mais na lista de horários livres',
  !temHora(listaP1, DIA, '10:00'));
verdade('nem 10:30, que começaria dentro do atendimento',
  !temHora(listaP1, DIA, '10:30'));
verdade('nem 09:30, que terminaria dentro dele',
  !temHora(listaP1, DIA, '09:30'));

secao('A2. Mas o outro profissional continua livre na mesma hora');
const p2dez = await marcarEm(P2.id, DIA, '10:00', SV[60].id, 'Cliente do P2');
verdade('P2 aceita 10:00 mesmo com P1 ocupado às 10:00', p2dez.ok, p2dez.erro);

/* ══════════════════════════════════════════════════════════════════════════
   B. CONCORRÊNCIA — dois clientes no mesmo instante
   ══════════════════════════════════════════════════════════════════════════ */
secao('B. Dois clientes disparando no mesmo horário ao mesmo tempo');

const [c1, c2] = await Promise.all([
  marcarEm(P1.id, DIA2, '14:00', SV[60].id, 'Corrida A', '11911111111'),
  marcarEm(P1.id, DIA2, '14:00', SV[60].id, 'Corrida B', '11922222222'),
]);
const venceram = [c1, c2].filter(x => x.ok).length;
igual('exatamente UM consegue — o outro é recusado pelo banco', venceram, 1);
/* ⚠ E o recado não pode trazer o nome de quem ganhou.
   `agendar()` é alcançável por `anon`. A primeira versão do gatilho da Fase
   1A repassava a mensagem de `porque_nao_cabe()` — "Dona do Salão já tem
   Corrida A das 14:00 às 15:00" — e foi ESTA asserção que pegou o vazamento. */
verdade('e quem perdeu recebe recado de gente, não erro de banco',
  venceram !== 1 || /hor[áa]rio|livre|marc/i.test(([c1,c2].find(x => !x.ok) || {}).erro || ''),
  JSON.stringify(([c1,c2].find(x => !x.ok) || {}).erro));
verdade('e NÃO traz o nome de quem ganhou o horário',
  !/Corrida [AB]/.test(([c1,c2].find(x => !x.ok) || {}).erro || ''),
  JSON.stringify(([c1,c2].find(x => !x.ok) || {}).erro));

const naGrade = await d.lista('agendamentos', { salaoId: SALAO });
const em14 = naGrade.filter(a => a.profissionalId === P1.id
  && new Date(a.inicio).getTime() === new Date(instante(DIA2,'14:00')).getTime()
  && ['pendente','confirmado'].includes(a.status));
igual('e só existe UMA linha gravada naquele horário', em14.length, 1);

/* ══════════════════════════════════════════════════════════════════════════
   C. DURAÇÃO — cada serviço reserva o que promete
   ══════════════════════════════════════════════════════════════════════════ */
secao('C. Serviços de 15, 30, 45, 60, 90 e 120 minutos');

/* Faixa própria: `10 + min` colidia com o bloco seguinte (10+90 = 100) e com
   os dias soltos lá de cima. Cada bloco daqui em diante tem a sua dezena, e
   nenhum encosta no outro. */
let iDur = 0;
for(const min of [15, 30, 45, 60, 90, 120]){
  const dia = emDias(200 + (iDur++));    // um dia limpo por duração
  const r = await marcarEm(P1.id, dia, '09:00', SV[min].id);
  if(!r.ok){ nao(`${min}min: marcação recusada`, r.erro); continue; }
  const feito = Array.isArray(r.corpo) ? r.corpo[0] : r.corpo;
  const reservou = (new Date(feito.fim) - new Date(feito.inicio)) / 60000;
  igual(`${String(min).padStart(3)}min reserva ${min} minutos de cadeira`, reservou, min);
}

secao('C2. E a agenda respeita essa duração ao oferecer o próximo horário');
{
  /* Dia próprio. Este bloco usava emDias(40), que o bloco C acima já tinha
     ocupado — a marcação de 2h era recusada por choque, ninguém conferia, e
     o teste então reprovava o produto por um horário que estava livre mesmo.
     Cenário montado sem conferir é cenário que mente nas duas direções. */
  const dia = emDias(250);
  const posto = await marcarEm(P1.id, dia, '09:00', SV[120].id);   // 09:00–11:00
  verdade('o cenário foi montado: 2h marcadas às 9h', posto.ok, posto.erro);
  const l = await livres(P1.id, dia, [SV[30].id]);
  verdade('e o dia tem horários para conferir', l.length > 0);
  verdade('depois de um serviço de 2h às 9h, 10:30 não é oferecido',
    !temHora(l, dia, '10:30'));
  verdade('e 11:00 é', temHora(l, dia, '11:00'));
}

/* ══════════════════════════════════════════════════════════════════════════
   D. HORÁRIO DE FUNCIONAMENTO — o serviço tem que CABER antes de fechar
   ══════════════════════════════════════════════════════════════════════════ */
secao('D. Abertura, fechamento e o serviço que não cabe');
{
  const dia = emDias(50);
  const l60 = await livres(P1.id, dia, [SV[60].id]);
  /* Antes de qualquer "não é oferecido": a lista tem que ter conteúdo. Lista
     vazia aprova toda asserção negativa sem provar nada, e foi assim que a
     primeira versão desta suíte ficou verde estando quebrada. */
  verdade('a lista de horários deste dia não veio vazia', l60.length > 0,
    'sem isto, todo "não é oferecido" abaixo passa por vácuo');
  verdade('com 60min e fechamento às 18:00, 17:00 é oferecido', temHora(l60, dia, '17:00'));
  verdade('e 17:30 NÃO é — terminaria 18:30, meia hora depois de fechar',
    !temHora(l60, dia, '17:30'));
  verdade('nem 07:30, antes de abrir', !temHora(l60, dia, '07:30'));

  const l120 = await livres(P1.id, dia, [SV[120].id]);
  verdade('com 120min, 16:00 é oferecido', temHora(l120, dia, '16:00'));
  verdade('e 16:30 não', !temHora(l120, dia, '16:30'));

  // E o banco recusa, mesmo se a tela oferecesse.
  const forcado = await marcarEm(P1.id, dia, '17:30', SV[60].id);
  igual('e marcar 17:30 na mão é recusado pelo banco', forcado.ok, false);
}

secao('D2. Dia sem jornada = casa fechada');
{
  // Um profissional sem jornada nenhuma: a agenda dele não abre.
  const P3 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Sem Jornada',
    cor:'#2563EB', ativo:true, aceitaOnline:true, comissaoPct:0 });
  const l = await livres(P3.id, emDias(6), [SV[60].id]);
  igual('quem não tem jornada não oferece horário nenhum', l.length, 0);
  const r = await marcarEm(P3.id, emDias(6), '10:00', SV[60].id);
  igual('e não aceita marcação forçada', r.ok, false);
}

/* ══════════════════════════════════════════════════════════════════════════
   E. PASSADO — ontem e hoje-que-já-passou
   ══════════════════════════════════════════════════════════════════════════ */
secao('E. Datas e horários que já passaram');
{
  const ontem = emDias(-1);
  const l = await livres(P1.id, ontem, [SV[60].id]);
  igual('ontem não oferece horário nenhum', l.length, 0);
  const r = await marcarEm(P1.id, ontem, '10:00', SV[60].id);
  igual('e marcar ontem é recusado', r.ok, false);

  const hoje = emDias(0);
  const lh = await livres(P1.id, hoje, [SV[60].id]);
  const agora = Date.now();
  const passados = lh.filter(x => new Date(x).getTime() <= agora);
  igual('e hoje não sobra nenhum horário já vencido na lista', passados.length, 0);
}

/* ══════════════════════════════════════════════════════════════════════════
   F. BLOQUEIO — almoço, médico, feriado
   ══════════════════════════════════════════════════════════════════════════ */
secao('F. Bloqueio de horário (o almoço)');
{
  const dia = emDias(7);
  await d.inserir('bloqueios', { salaoId: SALAO, profissionalId: P1.id,
    inicio: instante(dia, '12:00'), fim: instante(dia, '13:00'), motivo:'Almoço' });

  const l = await livres(P1.id, dia, [SV[60].id]);
  verdade('12:00 não é oferecido durante o almoço', !temHora(l, dia, '12:00'));
  verdade('nem 11:30, que invadiria o almoço', !temHora(l, dia, '11:30'));
  verdade('11:00 continua livre — termina quando o almoço começa', temHora(l, dia, '11:00'));
  verdade('e 13:00 volta a ser oferecido', temHora(l, dia, '13:00'));

  const r = await marcarEm(P1.id, dia, '12:00', SV[60].id);
  igual('e o banco recusa marcar por cima do almoço', r.ok, false);

  // O bloqueio é DESTE profissional: o outro segue trabalhando.
  const l2 = await livres(P2.id, dia, [SV[60].id]);
  verdade('e o almoço de um não fecha a agenda do outro', temHora(l2, dia, '12:00'));
}

secao('F2. Bloqueio do salão inteiro fecha todo mundo');
{
  const dia = emDias(8);
  await d.inserir('bloqueios', { salaoId: SALAO, profissionalId: null,
    inicio: instante(dia, '08:00'), fim: instante(dia, '18:00'), motivo:'Feriado' });
  const l1 = await livres(P1.id, dia, [SV[60].id]);
  const l2 = await livres(P2.id, dia, [SV[60].id]);
  igual('no feriado, P1 não tem horário', l1.length, 0);
  igual('nem P2', l2.length, 0);
}

/* ══════════════════════════════════════════════════════════════════════════
   G. CANCELAMENTO — o horário tem que VOLTAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('G. Cancelar devolve a cadeira');
{
  const dia = emDias(9);
  const r = await marcarEm(P1.id, dia, '15:00', SV[60].id, 'Vai Cancelar');
  const feito = Array.isArray(r.corpo) ? r.corpo[0] : r.corpo;
  verdade('marcou 15:00', r.ok, r.erro);

  const antes = await livres(P1.id, dia, [SV[60].id]);
  verdade('e 15:00 saiu da lista', !temHora(antes, dia, '15:00'));

  const c = await anon('cancelar_agendamento', { p_token: feito.token });
  verdade('o cancelamento pelo link da cliente funciona', c.ok, c.erro);

  const depois = await livres(P1.id, dia, [SV[60].id]);
  verdade('e 15:00 VOLTA para a lista', temHora(depois, dia, '15:00'));

  const linhas = (await d.lista('agendamentos', { salaoId: SALAO }))
    .filter(a => new Date(a.inicio).getTime() === new Date(instante(dia,'15:00')).getTime());
  igual('sem duplicar registro: continua uma linha só', linhas.length, 1);
  igual('e ela ficou como cancelada', linhas[0] && linhas[0].status, 'cancelado');

  const remarcado = await marcarEm(P1.id, dia, '15:00', SV[60].id, 'Pegou a Vaga');
  verdade('e outra pessoa consegue pegar o horário liberado', remarcado.ok, remarcado.erro);
}

/* ══════════════════════════════════════════════════════════════════════════
   H. ISOLAMENTO ENTRE ESTABELECIMENTOS
   ══════════════════════════════════════════════════════════════════════════ */
secao('H. Um salão não enxerga o outro');
{
  const outra = novaAba();
  await outra.criarConta({ email:`pet-${marca}@teste.com`, senha:'minhasenhaboa',
    nome:'Dono do Pet', telefone:'+5521' + (100000000 + (Date.now() % 89999999)) });
  const cr = await outra.chamar('criar_salao', { p_nome_salao:'Pet Shop ' + marca,
    p_tipo:'salao', p_telefone:'(21) 4444-5555', p_documento:null, p_origem:null });
  const SALAO_B = cr[0].salao_id;

  const vistos = await outra.lista('agendamentos', {});
  igual('o dono do Pet Shop não vê nenhum agendamento do outro salão',
    vistos.filter(a => a.salaoId === SALAO).length, 0);
  const clis = await outra.lista('clientes', {});
  igual('nem os clientes', clis.filter(c => c.salaoId === SALAO).length, 0);
  const svs = await outra.lista('servicos', {});
  igual('nem os serviços', svs.filter(s => s.salaoId === SALAO).length, 0);
  const profs = await outra.lista('profissionais', {});
  igual('nem a equipe', profs.filter(p => p.salaoId === SALAO).length, 0);

  // E não consegue marcar na agenda do vizinho nem tentando de propósito.
  let barrado = false;
  try{ await outra.inserir('agendamentos', { salaoId: SALAO, clienteId: null,
        profissionalId: P1.id, inicio: instante(emDias(11),'10:00'),
        fim: instante(emDias(11),'11:00'), status:'confirmado' }); }
  catch(e){ barrado = true; }
  verdade('e não consegue escrever na agenda do vizinho', barrado);
}

/* ══════════════════════════════════════════════════════════════════════════
   I. O AGENDAMENTO CARREGA TUDO O QUE PRECISA
   ══════════════════════════════════════════════════════════════════════════ */
secao('I. Cliente → estabelecimento → profissional → serviço → hora → status');
{
  const dia = emDias(12);
  const r = await marcarEm(P1.id, dia, '09:00', SV[45].id, 'Ana Completa', '11955554444');
  const feito = Array.isArray(r.corpo) ? r.corpo[0] : r.corpo;
  verdade('marcou', r.ok, r.erro);

  const a = (await d.lista('agendamentos', { salaoId: SALAO })).find(x => x.id === feito.id);
  verdade('o agendamento existe na agenda do dono', !!a);
  verdade('com salão', a && a.salaoId === SALAO);
  verdade('com cliente', !!(a && a.clienteId));
  verdade('com profissional', a && a.profissionalId === P1.id);
  verdade('com início e fim', !!(a && a.inicio && a.fim));
  igual('com status', a && a.status, 'confirmado');
  igual('e marcado como vindo do link', a && a.origem, 'online');

  const itens = await d.lista('agendamento_servicos', { agendamentoId: feito.id });
  igual('e com o serviço escolhido preso a ele', itens.length, 1);
  igual('com a duração daquele serviço', itens[0] && Number(itens[0].duracaoMin), 45);

  const cli = (await d.lista('clientes', { salaoId: SALAO })).find(c => c.id === a.clienteId);
  igual('e o nome que a pessoa digitou está na ficha', cli && cli.nome, 'Ana Completa');
}

/* ══════════════════════════════════════════════════════════════════════════
   J. O QUE O BANCO NÃO PODE DEIXAR GRAVAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('J. Lixo que não pode entrar na agenda');
{
  const dia = emDias(13);
  let fimAntes = false;
  try{ await d.inserir('agendamentos', { salaoId: SALAO,
        clienteId: (await d.lista('clientes', { salaoId: SALAO }))[0].id,
        profissionalId: P1.id, inicio: instante(dia,'11:00'),
        fim: instante(dia,'10:00'), status:'confirmado' }); }
  catch(e){ fimAntes = true; }
  verdade('agendamento que termina antes de começar é recusado', fimAntes);

  let semProf = false;
  try{ await d.inserir('agendamentos', { salaoId: SALAO,
        clienteId: (await d.lista('clientes', { salaoId: SALAO }))[0].id,
        profissionalId: null, inicio: instante(dia,'10:00'),
        fim: instante(dia,'11:00'), status:'confirmado' }); }
  catch(e){ semProf = true; }
  verdade('agendamento sem profissional é recusado', semProf);

  const statusInvalido = await (async () => {
    try{ await d.inserir('agendamentos', { salaoId: SALAO,
          clienteId: (await d.lista('clientes', { salaoId: SALAO }))[0].id,
          profissionalId: P1.id, inicio: instante(dia,'10:00'),
          fim: instante(dia,'11:00'), status:'inventado' });
         return false; }catch(e){ return true; }
  })();
  verdade('status fora da lista é recusado', statusInvalido);
}

/* ══════════════════════════════════════════════════════════════════════════
   K. O DONO MARCANDO PELO PAINEL — a mesma trava vale
   ══════════════════════════════════════════════════════════════════════════ */
secao('K. O dono também não fura a agenda pelo painel');
{
  const dia = emDias(14);
  const cliente = (await d.lista('clientes', { salaoId: SALAO }))[0];
  await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cliente.id,
    profissionalId: P1.id, inicio: instante(dia,'10:00'), fim: instante(dia,'11:00'),
    status:'confirmado', origem:'recepcao' });

  let choque = false;
  try{ await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cliente.id,
        profissionalId: P1.id, inicio: instante(dia,'10:30'), fim: instante(dia,'11:30'),
        status:'confirmado', origem:'recepcao' }); }
  catch(e){ choque = true; }
  verdade('a recepção não consegue marcar em cima de outro atendimento', choque);

  // E a cliente também não pega esse horário pelo link.
  const pelaCliente = await marcarEm(P1.id, dia, '10:30', SV[30].id);
  igual('nem a cliente pelo link', pelaCliente.ok, false);
}

/* ══════════════════════════════════════════════════════════════════════════
   L. LIMITE DE HORÁRIOS EM ABERTO
   ══════════════════════════════════════════════════════════════════════════ */
secao('L. O teto de 3 horários em aberto por cliente');
{
  const tel = '11933332222';
  const r1 = await marcarEm(P2.id, emDias(20), '09:00', SV[30].id, 'Muitos Horários', tel);
  const r2 = await marcarEm(P2.id, emDias(21), '09:00', SV[30].id, 'Muitos Horários', tel);
  const r3 = await marcarEm(P2.id, emDias(22), '09:00', SV[30].id, 'Muitos Horários', tel);
  const r4 = await marcarEm(P2.id, emDias(23), '09:00', SV[30].id, 'Muitos Horários', tel);
  igual('os três primeiros passam', [r1,r2,r3].filter(x => x.ok).length, 3);
  igual('e o quarto é barrado', r4.ok, false);
  verdade('com recado que explica o que fazer',
    /3 hor[áa]rios|cancele/i.test(r4.erro || ''), JSON.stringify(r4.erro));
}

/* ══════════════════════════════════════════════════════════════════════════
   M. A FICHA DA CLIENTE — quem é quem

   O cenário do enunciado: "o agendamento de João aparece como sendo de
   outro". Aqui é onde isso poderia acontecer, porque a ficha é reencontrada
   pelo TELEFONE quando não há login.
   ══════════════════════════════════════════════════════════════════════════ */
secao('M. Duas pessoas, dois telefones, duas fichas');
{
  const dia = emDias(24);
  await marcarEm(P2.id, dia, '10:00', SV[30].id, 'João Silva',  '11944441111');
  await marcarEm(P2.id, dia, '11:00', SV[30].id, 'Maria Souza', '11944442222');

  const cls = await d.lista('clientes', { salaoId: SALAO });
  const joao  = cls.find(c => c.nome === 'João Silva');
  const maria = cls.find(c => c.nome === 'Maria Souza');
  verdade('cada uma ganhou a própria ficha', !!joao && !!maria && joao.id !== maria.id);

  const ags = await d.lista('agendamentos', { salaoId: SALAO });
  const doJoao  = ags.find(a => new Date(a.inicio).getTime() === new Date(instante(dia,'10:00')).getTime());
  const daMaria = ags.find(a => new Date(a.inicio).getTime() === new Date(instante(dia,'11:00')).getTime());
  verdade('o horário das 10 é do João', doJoao && doJoao.clienteId === joao.id);
  verdade('o das 11 é da Maria', daMaria && daMaria.clienteId === maria.id);

  /* E marcar de novo com o MESMO telefone reaproveita a ficha, em vez de
     criar uma segunda para a mesma pessoa. */
  await marcarEm(P2.id, emDias(25), '10:00', SV[30].id, 'João Silva', '11944441111');
  const depois = (await d.lista('clientes', { salaoId: SALAO }))
    .filter(c => c.telefone === '11944441111');
  igual('o mesmo telefone não cria uma segunda ficha', depois.length, 1);
}

/* ══════════════════════════════════════════════════════════════════════════
   N. SITUAÇÕES DE BORDA QUE NINGUÉM CADASTRA DE PROPÓSITO
   ══════════════════════════════════════════════════════════════════════════ */
secao('N. Jornada cadastrada duas vezes no mesmo dia');
{
  const P4 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Jornada Dobrada',
    cor:'#2563EB', ativo:true, aceitaOnline:true, comissaoPct:0 });
  const dia = emDias(30);
  const dow = new Date(instante(dia, '12:00')).getDay();
  // Duas faixas que se cruzam — erro de digitação comum: 08–13 e 12–18.
  await d.inserir('jornadas', { profissionalId: P4.id, diaSemana: dow,
                                inicio:'08:00', fim:'13:00' });
  await d.inserir('jornadas', { profissionalId: P4.id, diaSemana: dow,
                                inicio:'12:00', fim:'18:00' });
  const l = await livres(P4.id, dia, [SV[30].id]);
  const repetidos = l.length - new Set(l.map(x => new Date(x).getTime())).size;
  igual('jornadas que se cruzam não geram horário repetido na lista', repetidos, 0);

  let paraTras = 0;
  for(let i = 1; i < l.length; i++)
    if(new Date(l[i]) < new Date(l[i-1])) paraTras++;
  igual('e a lista não volta no tempo no meio dela', paraTras, 0);
}

secao('N1b. Mas manhã e tarde com almoço no meio CONTINUAM separadas');
{
  /* A costura das faixas não pode virar "junta tudo": quem cadastra 08–12 e
     14–18 está dizendo que fecha para o almoço, e essas duas horas têm de
     seguir fechadas. Consertar a duplicação fundindo tudo seria trocar um
     defeito visível por um que abre a agenda na hora do almoço. */
  const P6 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Manhã e Tarde',
    cor:'#2563EB', ativo:true, aceitaOnline:true, comissaoPct:0 });
  const dia = emDias(36);
  const dow = new Date(instante(dia, '12:00')).getDay();
  await d.inserir('jornadas', { profissionalId: P6.id, diaSemana: dow,
                                inicio:'08:00', fim:'12:00' });
  await d.inserir('jornadas', { profissionalId: P6.id, diaSemana: dow,
                                inicio:'14:00', fim:'18:00' });
  const l = await livres(P6.id, dia, [SV[30].id]);
  verdade('11:30 é oferecido — último da manhã', temHora(l, dia, '11:30'));
  verdade('12:00 NÃO é — fechou para o almoço', !temHora(l, dia, '12:00'));
  verdade('13:00 também não', !temHora(l, dia, '13:00'));
  verdade('e 14:00 volta', temHora(l, dia, '14:00'));
}

secao('N2. Mudar o status pelo painel devolve a cadeira');
{
  const dia = emDias(31);
  const r = await marcarEm(P1.id, dia, '10:00', SV[60].id, 'Vai Faltar');
  const feito = Array.isArray(r.corpo) ? r.corpo[0] : r.corpo;
  verdade('marcou', r.ok, r.erro);

  await d.atualizar('agendamentos', feito.id, { status:'cancelado' });
  const l = await livres(P1.id, dia, [SV[60].id]);
  verdade('cancelado pelo painel, 10:00 volta a ser oferecido', temHora(l, dia, '10:00'));

  await d.atualizar('agendamentos', feito.id, { status:'confirmado' });
  const l2 = await livres(P1.id, dia, [SV[60].id]);
  verdade('e reconfirmado, sai de novo', !temHora(l2, dia, '10:00'));

  await d.atualizar('agendamentos', feito.id, { status:'faltou' });
  const l3 = await livres(P1.id, dia, [SV[60].id]);
  verdade('"não compareceu" também libera a cadeira', temHora(l3, dia, '10:00'));
}

secao('N3. O dono marcando fora do horário de funcionamento');
{
  /* Isto NÃO é bug: a recepção precisa poder encaixar a cliente antiga às 7h.
     O que o teste fixa é que a porta é só do dono — pelo link, ninguém entra
     fora da jornada. Se um dia alguém "consertar" isso fechando os dois
     lados, o salão perde um encaixe legítimo e vai reclamar sem saber por quê.

     ⚠ O QUE MUDOU NA FASE 1A: a porta continua aberta, mas deixou de ser
     silenciosa. Antes, marcar às 7h e marcar às 7h POR ENGANO entravam no
     banco exatamente iguais. Agora o encaixe precisa se declarar — e é isso
     que este bloco fixa: sem a marca, recusa; com ela, entra. */
  const dia = emDias(32);
  const cliente = (await d.lista('clientes', { salaoId: SALAO }))[0];

  let semMarca = null;
  try{
    await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cliente.id,
      profissionalId: P2.id, inicio: instante(dia,'07:00'), fim: instante(dia,'07:45'),
      status:'confirmado', origem:'recepcao' });
  }catch(e){ semMarca = e.message; }
  verdade('sem se declarar encaixe, 7h é recusado', semMarca !== null);
  verdade('e a recusa diz que é a jornada, sem citar ninguém',
    /jornada/i.test(semMarca || '') && !/[A-Z][a-z]+ já tem/.test(semMarca || ''),
    String(semMarca));

  let deuCerto = true;
  try{
    await d.inserir('agendamentos', { salaoId: SALAO, clienteId: cliente.id,
      profissionalId: P2.id, inicio: instante(dia,'07:00'), fim: instante(dia,'07:45'),
      status:'confirmado', origem:'recepcao', encaixe: true });
  }catch(e){ deuCerto = false; }
  verdade('a recepção consegue encaixar às 7h, antes de abrir', deuCerto);

  const pelaCliente = await marcarEm(P2.id, dia, '07:00', SV[30].id);
  igual('mas pelo link, 7h continua fechado', pelaCliente.ok, false);

  const l = await livres(P2.id, dia, [SV[30].id]);
  verdade('e o encaixe das 7h não vaza para a lista pública',
    !temHora(l, dia, '07:00'));
}

secao('N4. Telefone de outra pessoa: a ficha é capturada?');
{
  /* O cenário do enunciado, item 8. Sem login, a ficha é reencontrada PELO
     TELEFONE — é o que faz a cliente antiga não virar ficha nova a cada
     visita. O preço disso é que quem digitar o telefone de outra pessoa cai
     na ficha dela. Aqui o teste registra o que o sistema FAZ hoje, para a
     decisão de mudar (ou não) ser tomada com o fato à vista. */
  const dia = emDias(33);
  const tel = '11977778888';
  await marcarEm(P2.id, dia, '09:00', SV[30].id, 'Dona Original', tel);
  const original = (await d.lista('clientes', { salaoId: SALAO }))
    .find(c => c.telefone === tel);
  verdade('a primeira pessoa ganhou ficha', !!original);

  await marcarEm(P2.id, dia, '10:00', SV[30].id, 'Outra Pessoa', tel);
  const fichas = (await d.lista('clientes', { salaoId: SALAO }))
    .filter(c => c.telefone === tel);
  igual('quem repete o telefone NÃO cria ficha nova', fichas.length, 1);
  igual('e o nome da ficha continua sendo o da primeira', fichas[0].nome, 'Dona Original');

  const ags = await d.lista('agendamentos', { salaoId: SALAO });
  const segundo = ags.find(a =>
    new Date(a.inicio).getTime() === new Date(instante(dia,'10:00')).getTime());
  igual('o segundo horário fica preso à MESMA ficha — telefone é a identidade aqui',
    segundo && segundo.clienteId, original.id);
}

secao('N5. Serviço desativado some da vitrine e não aceita marcação');
{
  const dia = emDias(34);
  const sv = await d.inserir('servicos', { salaoId: SALAO, nome:'Vai Sumir',
    duracaoMin:30, intervaloMin:0, preco:40, ativo:true, aceitaOnline:true });
  const antes = await anon('vitrine', { p_slug: SLUG });
  verdade('serviço ativo aparece na vitrine',
    (antes.corpo.servicos || []).some(x => x.id === sv.id));

  await d.atualizar('servicos', sv.id, { ativo:false });
  const depois = await anon('vitrine', { p_slug: SLUG });
  verdade('desativado, some da vitrine',
    !(depois.corpo.servicos || []).some(x => x.id === sv.id));

  const r = await marcarEm(P1.id, dia, '09:00', sv.id);
  igual('e não dá para marcar um serviço desativado', r.ok, false);
}

secao('N6. Profissional desativado');
{
  const dia = emDias(35);
  const P5 = await d.inserir('profissionais', { salaoId: SALAO, nome:'Vai Sair',
    cor:'#2563EB', ativo:true, aceitaOnline:true, comissaoPct:0 });
  const dow = new Date(instante(dia,'12:00')).getDay();
  await d.inserir('jornadas', { profissionalId: P5.id, diaSemana: dow,
                                inicio:'08:00', fim:'18:00' });
  const l1 = await livres(P5.id, dia, [SV[30].id]);
  verdade('ativo, tem horário', l1.length > 0);

  await d.atualizar('profissionais', P5.id, { ativo:false });
  const v = await anon('vitrine', { p_slug: SLUG });
  verdade('desativado, some da vitrine',
    !(v.corpo.profissionais || []).some(x => x.id === P5.id));
  const r = await marcarEm(P5.id, dia, '09:00', SV[30].id);
  igual('e não aceita marcação', r.ok, false);
}

await bd.end();

console.log('');
if(falhou){
  console.log(`✗ ${falhou} de ${passou + falhou} verificações falharam.`);
  process.exit(1);
}
console.log(`✓ ${passou} verificações de auditoria da agenda.`);
