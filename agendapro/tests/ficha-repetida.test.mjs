/* ===========================================================================
   AgendaPro — telefone que já tem dono não pode derrubar o agendamento

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/ficha-repetida.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   Relatado com print, no ar. A recepção abre "Novo agendamento", escolhe
   "— novo cliente —", digita o nome e o telefone de quem JÁ era cliente do
   salão. Ao salvar, um alerta do navegador, em inglês:

       NÃO consegui salvar no banco:
       duplicate key value violates unique constraint "ux_cli_tel"
       insert or update on table "agendamentos" violates foreign key
       constraint "agendamentos_cliente_id_fkey"
       O que está na tela ainda não foi gravado.

   O segundo erro é filho do primeiro: a ficha não entrou, e o agendamento
   apontava para ela. O atendimento INTEIRO não gravava — a cliente ficava
   sem horário — e o recado não dizia nem de quem era o telefone repetido.

   O caminho da cliente sempre soube resolver isso: `ficha_do_cliente()` no
   banco reaproveita a ficha do telefone. Quem não sabia era o painel.

   Esta suíte prova pelo RESULTADO, não pela ausência do alerta: depois de
   salvar, o horário tem que estar no banco.
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
await d.criarConta({ email:`ficha-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Ficha ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
await d.inserir('servicos', { salaoId: SALAO, nome:'Pedicure', duracaoMin:40,
  intervaloMin:0, preco:50, ativo:true, aceitaOnline:true });

// A cliente que JÁ existe — foi ela quem marcou pelo link semana passada.
const TEL = '11' + (900000000 + Math.floor(Math.random()*99999999));
await d.inserir('clientes', { salaoId: SALAO, nome:'Maria Antiga', telefone: TEL });

const AMANHA = new Date(Date.now() + 864e5).toISOString().slice(0,10);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const dono = await ctx.newPage();
const erros = [];
dono.on('pageerror', e => erros.push(e.message));

// O alerta do navegador é o sintoma que apareceu no print. Guardo o texto de
// cada um e respondo o que o teste mandar — assim dá para separar o alerta de
// erro (que não pode existir) da pergunta legítima ("é a mesma pessoa?").
let respostaDoDono = true;
const alertas = [];
dono.on('dialog', async dlg => {
  alertas.push(dlg.message());
  await (dlg.type() === 'confirm'
    ? (respostaDoDono ? dlg.accept() : dlg.dismiss())
    : dlg.accept());
});

await dono.addInitScript(([b, s]) => {
  window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await dono.goto(BASE + '/app.html');
await dono.waitForTimeout(3500);

// A recepção preenchendo o formulário, campo por campo, como no print.
async function recepcaoMarca(nome, telefone, hora){
  alertas.length = 0;
  await dono.evaluate(() => abrirNovo());
  await dono.waitForTimeout(300);
  await dono.evaluate(([n, t, dia, h]) => {
    document.getElementById('fCliente').value = '';
    document.getElementById('fCliente').dispatchEvent(new Event('change'));
    document.getElementById('fNome').value = n;
    document.getElementById('fTel').value  = t;
    document.querySelector('.serv-op input').checked = true;
    document.getElementById('fData').value = dia;
    document.getElementById('fInicio').value = h;
    recalcularFim();
  }, [nome, telefone, AMANHA, hora]);
  await dono.evaluate(() => salvarAgendamento());
  await dono.waitForTimeout(2500);
}

const noBanco = async () => (await d.lista('agendamentos', { salaoId: SALAO })).length;
const fichas  = async () => (await d.lista('clientes', { salaoId: SALAO })).length;

/* ══════════════════════════════════════════════════════════════════════════
   1. O CASO DO PRINT — telefone repetido, nome diferente
   ══════════════════════════════════════════════════════════════════════════ */
secao('Recepção marca com o telefone de quem já é cliente');

// O dono confirma que é a mesma pessoa.
respostaDoDono = true;
await recepcaoMarca('Maria', TEL, '10:00');

verdade('nenhum erro de banco em inglês na tela',
  !alertas.some(t => /duplicate key|constraint|violates/i.test(t)),
  JSON.stringify(alertas));
igual('e o horário FOI gravado', await noBanco(), 1);
igual('sem criar uma segunda ficha para o mesmo telefone', await fichas(), 1);

const ag = (await d.lista('agendamentos', { salaoId: SALAO }))[0];
const cli = (await d.lista('clientes', { salaoId: SALAO }))[0];
igual('o horário ficou na ficha que já existia', ag.clienteId, cli.id);
igual('e a ficha manteve o nome dela', cli.nome, 'Maria Antiga');
igual('com o nome digitado guardado em "quem vem"', ag.atendidoNome, 'Maria');

verdade('a pergunta feita ao dono diz de quem é o telefone',
  alertas.some(t => /Maria Antiga/.test(t)),
  'sem o nome, "este telefone já existe" não ajuda a resolver: ' + JSON.stringify(alertas));

/* ══════════════════════════════════════════════════════════════════════════
   2. E O DONO PODE DIZER QUE NÃO É A MESMA PESSOA
   ══════════════════════════════════════════════════════════════════════════ */
secao('Quando o dono cancela a pergunta, nada é gravado');

respostaDoDono = false;
await recepcaoMarca('Outra Pessoa', TEL, '14:00');
igual('o horário não entrou', await noBanco(), 1);
igual('e nenhuma ficha foi criada', await fichas(), 1);

/* ══════════════════════════════════════════════════════════════════════════
   3. TELEFONE NOVO CONTINUA CRIANDO FICHA, COMO SEMPRE
   ══════════════════════════════════════════════════════════════════════════ */
secao('Cliente de verdade nova não foi atrapalhada pela correção');

respostaDoDono = true;
const TEL2 = '11' + (800000000 + Math.floor(Math.random()*99999999));
await recepcaoMarca('Joana Nova', TEL2, '16:00');
igual('o horário entrou', await noBanco(), 2);
igual('e a ficha nova foi criada', await fichas(), 2);
verdade('sem perguntar nada ao dono',
  !alertas.length, JSON.stringify(alertas));

/* ══════════════════════════════════════════════════════════════════════════
   4. O MESMO TELEFONE NO CADASTRO DE CLIENTE
   ══════════════════════════════════════════════════════════════════════════ */
secao('Aba Clientes: o aviso vem antes, e em português');

alertas.length = 0;
await dono.evaluate(() => abrirCliente(null));
await dono.waitForTimeout(300);
await dono.evaluate(t => {
  document.getElementById('kNome').value = 'Terceira';
  document.getElementById('kTel').value = t;
  salvarCliente(null);
}, TEL);
await dono.waitForTimeout(1500);

igual('nenhuma ficha a mais foi criada', await fichas(), 2);
verdade('e o aviso diz de quem é o número',
  alertas.some(t => /Maria Antiga/.test(t)), JSON.stringify(alertas));
verdade('sem despejar o erro do banco em inglês',
  !alertas.some(t => /duplicate key|ux_cli_tel/i.test(t)), JSON.stringify(alertas));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));

await nav.close();
console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
