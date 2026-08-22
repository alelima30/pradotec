/* ===========================================================================
   AgendaPro — o caminho inteiro, na tela, dos dois lados

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/fluxo-auditoria.test.mjs

   A suíte de auditoria prova o BANCO. Esta prova a TELA — e o que interessa
   aqui é o encontro das duas pontas: a cliente marca pelo link e o dono tem
   que ver, no painel dele, o nome certo, o serviço certo, a pessoa certa e a
   hora certa. É esse encontro que quebra sem ninguém perceber, porque cada
   lado, sozinho, parece funcionar.
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
await d.criarConta({ email:`flx-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Salão Fluxo ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];
for(let i = 0; i <= 6; i++)
  await d.inserir('jornadas', { profissionalId: PROF.id, diaSemana:i,
                                inicio:'08:00', fim:'18:00' });
await d.inserir('servicos', { salaoId: SALAO, nome:'Corte Auditado', duracaoMin:60,
  intervaloMin:0, preco:70, ativo:true, aceitaOnline:true });

const nav = await chromium.launch({ executablePath: CHROMIUM });

/* ══════════════════════════════════════════════════════════════════════════
   A CLIENTE MARCA — pelo link, do celular, sem conta
   ══════════════════════════════════════════════════════════════════════════ */
secao('A cliente marca pelo link, do começo ao fim');

const cel = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
const cli = await cel.newPage();
const errosCli = [];
cli.on('pageerror', e => errosCli.push(e.message));
await cli.addInitScript(b => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
await cli.goto(BASE + '/agendar.html?salao=' + SLUG);
await cli.waitForTimeout(2800);

verdade('a capa do salão abre pelo link', await cli.isVisible('.boas-cta'));
await cli.click('.boas-cta');
await cli.waitForTimeout(1200);

// Escolher o serviço
await cli.click('.opcao:has-text("Corte Auditado")');
await cli.waitForTimeout(700);
verdade('escolheu o serviço', await cli.evaluate(() =>
  document.querySelectorAll('.opcao.sel').length > 0));

const avancar = async () => {
  const bt = await cli.$('#btPrincipal:not([disabled])');
  if(bt) { await bt.click(); await cli.waitForTimeout(1100); }
};
await avancar();                                   // → profissional (ou quando)

// Se a tela de profissional apareceu, escolhe o primeiro.
if(await cli.isVisible('#p-prof')){
  await cli.click('#p-prof .opcao');
  await cli.waitForTimeout(600);
  await avancar();
}
await cli.waitForTimeout(900);
verdade('chegou na escolha de data e hora', await cli.isVisible('#p-quando'),
  'tela atual: ' + await cli.evaluate(() => {
    const s = [...document.querySelectorAll('.passo')].find(x => x.classList.contains('on'));
    return s ? s.id : '—'; }));

// Um dia adiante, para escapar do "cedo demais".
const dias = await cli.$$('.dia:not(.sem)');
if(dias.length > 1) { await dias[1].click(); await cli.waitForTimeout(1500); }

const horas = await cli.$$('#listaHoras .hora');
verdade('a tela oferece horários livres', horas.length > 0, `veio ${horas.length}`);
if(!horas.length){
  console.log('      (sem horários não há o que auditar adiante — parando aqui)');
  process.exit(1);
}

/* A lista de horários tem que estar EM ORDEM. Fora de ordem a pessoa acha que
   o horário não existe e desiste — e é o defeito que uma jornada cadastrada
   em duas faixas produz. */
const emOrdem = await cli.evaluate(() => {
  const t = [...document.querySelectorAll('#listaHoras .hora')].map(b => b.textContent.trim())
    .filter(x => /^\d{1,2}:\d{2}$/.test(x))
    .map(x => { const [h,m] = x.split(':').map(Number); return h*60+m; });
  return { crescente: t.every((v,i) => i === 0 || v > t[i-1]),
           repetidos: t.length - new Set(t).size, quantos: t.length };
});
verdade('em ordem crescente, sem repetir',
  emOrdem.quantos > 0 && emOrdem.crescente && emOrdem.repetidos === 0,
  JSON.stringify(emOrdem) + ' — lista vazia também reprova: '
  + 'sem horário nenhum, "está em ordem" não prova nada');

const horaEscolhida = await cli.evaluate(() => {
  const b = document.querySelector('.hora:not(.off)');
  return b ? b.textContent.trim() : null;
});
await horas[0].click();
await cli.waitForTimeout(800);
await avancar();
await cli.waitForTimeout(1000);

// Dados da pessoa
if(await cli.isVisible('#dNome')){
  await cli.fill('#dNome', 'Cliente Auditoria');
  await cli.fill('#dTel', '(11) 96666-5555');
  await cli.waitForTimeout(500);
  await avancar();
}
await cli.waitForTimeout(1200);

// Verificação por código, quando pedida
if(await cli.isVisible('#p-codigo')){
  const codigo = await cli.evaluate(() => (window.otp && window.otp.codigo) || null);
  if(codigo){
    for(let i = 0; i < 6; i++) await cli.fill('#d' + i, codigo[i]);
    await cli.waitForTimeout(900);
  }
  await avancar();
  await cli.waitForTimeout(1200);
}

/* Do "dados" até o "pronto" pode haver código por telefone e a tela de
   conferir. Em vez de adivinhar a sequência, o teste segue empurrando o botão
   principal enquanto ele estiver ativo — que é o que a pessoa faz. */
for(let i = 0; i < 6 && !(await cli.isVisible('#p-pronto')); i++){
  if(await cli.isVisible('#p-codigo')){
    const codigo = await cli.evaluate(() => (window.otp && window.otp.codigo) || null);
    if(codigo) for(let k = 0; k < 6; k++) await cli.fill('#d' + k, codigo[k]);
    await cli.waitForTimeout(900);
  }
  await avancar();
  await cli.waitForTimeout(1400);
}
await cli.waitForTimeout(1500);

const marcou = await cli.isVisible('#p-pronto');
verdade('a tela de "Agendado!" aparece', marcou, 'a cliente não chegou ao fim');
igual('e nenhum erro de JavaScript no caminho',
  errosCli.length ? errosCli.join(' | ') : 0, 0);

/* ══════════════════════════════════════════════════════════════════════════
   MEUS HORÁRIOS — o que a cliente consegue fazer depois
   ══════════════════════════════════════════════════════════════════════════ */
secao('O que a cliente vê e faz depois de marcar');
{
  await cli.evaluate(() => irPara('meus'));
  await cli.waitForTimeout(2200);
  verdade('a tela de "Meus horários" abre', await cli.isVisible('#p-meus'));

  const acoes = await cli.evaluate(() =>
    [...document.querySelectorAll('#listaMeus button')].map(b => b.textContent.trim()));
  verdade('e oferece cancelar', acoes.some(t => /cancelar/i.test(t)),
    'botões: ' + JSON.stringify(acoes));

  verdade('e remarcar', acoes.some(t => /remarcar/i.test(t)),
    'sem isto, trocar de horário obriga a cancelar primeiro e sair '
    + 'procurando outro sem nada na mão');
}

/* ══════════════════════════════════════════════════════════════════════════
   REMARCAR — o teste que o enunciado pede com nome e sobrenome:
   o horário antigo volta a ficar livre, o novo fica ocupado, e NÃO nasce um
   segundo agendamento.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Remarcar troca o horário, sem duplicar');
{
  const antes = (await d.lista('agendamentos', { salaoId: SALAO }))
    .filter(a => ['pendente','confirmado'].includes(a.status));
  igual('a cliente tem exatamente 1 horário em aberto', antes.length, 1);
  const horaVelha = antes[0].inicio;

  await cli.click('#listaMeus button:has-text("Remarcar")');
  await cli.waitForTimeout(1800);
  verdade('a remarcação leva de volta para a escolha de horário',
    await cli.isVisible('#p-quando'));

  const dd = await cli.$$('.dia:not(.sem)');
  // Um dia diferente do original, para a troca ser inequívoca.
  if(dd.length > 2){ await dd[2].click(); await cli.waitForTimeout(1600); }
  const hh = await cli.$$('#listaHoras .hora');
  verdade('e oferece horários no dia novo', hh.length > 0);
  if(hh.length){
    await hh[0].click(); await cli.waitForTimeout(800);
    for(let i = 0; i < 6 && !(await cli.isVisible('#p-pronto')); i++){
      const bt = await cli.$('#btPrincipal:not([disabled])');
      if(bt){ await bt.click(); await cli.waitForTimeout(1500); }
    }
  }
  await cli.waitForTimeout(2000);
  verdade('a remarcação chega em "Agendado!"', await cli.isVisible('#p-pronto'));

  const depois = await d.lista('agendamentos', { salaoId: SALAO });
  const abertos = depois.filter(a => ['pendente','confirmado'].includes(a.status));
  igual('continua UM horário em aberto — não virou dois', abertos.length, 1);
  verdade('e é num horário diferente do antigo',
    abertos[0] && abertos[0].inicio !== horaVelha,
    `antes ${horaVelha}, depois ${abertos[0] && abertos[0].inicio}`);

  const velhoReg = depois.find(a => a.inicio === horaVelha);
  igual('o antigo ficou registrado como cancelado, não sumiu',
    velhoReg && velhoReg.status, 'cancelado');

  // E a cadeira antiga volta mesmo a ser oferecida.
  const diaVelho = new Date(horaVelha).toISOString().slice(0,10);
  const r = await fetch(`${BASE}/rest/v1/rpc/horarios_livres`, {
    method:'POST', headers:{ apikey:'k', 'Content-Type':'application/json' },
    body: JSON.stringify({ p_profissional: PROF.id, p_data: diaVelho,
                           p_servicos: [(await d.lista('servicos',{salaoId:SALAO}))[0].id] }) });
  const lista = (await r.json()).map(x => Object.values(x)[0]);
  verdade('e o horário antigo volta para a lista de livres',
    lista.some(x => new Date(x).getTime() === new Date(horaVelha).getTime()),
    `${lista.length} horários no dia, nenhum às ${horaVelha}`);
}

/* ══════════════════════════════════════════════════════════════════════════
   O DONO VÊ — o mesmo horário, do outro lado
   ══════════════════════════════════════════════════════════════════════════ */
secao('E o dono vê esse horário na agenda dele');

const gravado = (await d.lista('agendamentos', { salaoId: SALAO }))
  .filter(a => a.status === 'confirmado')
  .sort((a,b) => new Date(a.inicio) - new Date(b.inicio))[0];
verdade('o horário chegou ao banco', !!gravado);

if(gravado){
  const ficha = (await d.lista('clientes', { salaoId: SALAO }))
    .find(c => c.id === gravado.clienteId);
  igual('preso ao nome que a cliente digitou', ficha && ficha.nome, 'Cliente Auditoria');
  igual('e ao profissional escolhido', gravado.profissionalId, PROF.id);
  igual('marcado como vindo do link', gravado.origem, 'online');
  const itens = await d.lista('agendamento_servicos', { agendamentoId: gravado.id });
  igual('com o serviço preso ao agendamento', itens.length, 1);
  igual('e com a duração de 60 minutos', Number(itens[0] && itens[0].duracaoMin), 60);

  const painel = await nav.newContext({ viewport:{ width:1360, height:900 } });
  const pg = await painel.newPage();
  const errosDono = [];
  pg.on('pageerror', e => errosDono.push(e.message));
  await pg.addInitScript(([b, s]) => {
    window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
    localStorage.setItem('agendapro.sessao', JSON.stringify(s));
  }, [BASE, d.sessao()]);
  await pg.goto(BASE + '/app.html');
  await pg.waitForTimeout(3500);

  const alvo = new Date(gravado.inicio).toISOString().slice(0,10);
  await pg.evaluate(dd => { diaAtual = dd; pintar(); }, alvo);
  await pg.waitForTimeout(1200);

  const cartao = await pg.evaluate(() => {
    const c = document.querySelector('.ag');
    return c ? c.textContent.replace(/\s+/g,' ').trim() : null;
  });
  verdade('o cartão aparece na grade do dia certo', !!cartao, 'nada desenhado');
  verdade('com o nome da cliente', (cartao || '').includes('Cliente Auditoria'),
    JSON.stringify(cartao));
  verdade('e com o serviço', (cartao || '').includes('Corte Auditado'),
    JSON.stringify(cartao));

  /* O dono cancela e a cadeira volta. Este é o ciclo completo: a cliente
     marcou pela tela dela, o dono desmarcou pela tela dele, e o banco tem
     que refletir as duas pontas. */
  await pg.evaluate(id => {
    const a = bd.agendamentos.find(x => x.id === id);
    a.status = 'cancelado'; salvar();
  }, gravado.id);
  await pg.waitForTimeout(2000);

  const depois = (await d.lista('agendamentos', { salaoId: SALAO }))
    .find(a => a.id === gravado.id);
  igual('o cancelamento do dono chega ao banco', depois && depois.status, 'cancelado');
  igual('sem apagar o registro', !!depois, true);

  igual('e o painel não deu erro de JavaScript',
    errosDono.length ? errosDono.join(' | ') : 0, 0);
  await pg.close();
}

await cli.close();
await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de fluxo.`);
