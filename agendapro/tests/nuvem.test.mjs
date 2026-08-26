/* ===========================================================================
   AgendaPro — dados.js contra um Postgres de verdade
   Rodar:  node tests/nuvem.test.mjs   (com a bancada de pé, ver tests/bancada/)

   O que este teste prova, e que nenhum outro provava: que a camada de dados
   fala com o banco REAL, com o schema real e o RLS real. Os testes de SQL
   provam o banco; o de colunas prova o mapa; este prova o caminho inteiro,
   do JavaScript até a linha gravada.

   A bancada é um PostgREST caseiro (tests/bancada/postgrest.mjs) apontando
   para um Postgres local com o 00_tudo.sql instalado. Não é o Supabase, mas
   é o mesmo Postgres, o mesmo schema e as mesmas policies — que é onde mora
   o risco de verdade.
   =========================================================================== */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.join(AQUI, '..');
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let ok = 0, falhas = 0;
const dizer = (bom, msg, extra) => {
  if(bom){ ok++; console.log('  ✓ ' + msg); }
  else { falhas++; console.log('  ✗ ' + msg + (extra ? '\n      ' + extra : '')); }
};
const secao = t => console.log('\n' + t);

// Carrega dados.js como o navegador carregaria, com a config apontando para
// a bancada. Cada "aba" tem o próprio armazenamento e a própria sessão.
function novaAba(){
  const guardado = {};
  const janela = {
    AGENDAPRO: { url: BASE, chave: 'chave-de-teste', ambiente: 'bancada' },
    localStorage: {
      getItem: k => (k in guardado ? guardado[k] : null),
      setItem: (k,v) => { guardado[k] = String(v); },
      removeItem: k => { delete guardado[k]; },
    },
  };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    janela, { info(){}, error(){}, log(){} }, fetch, janela.localStorage);
  return janela.Dados;
}

async function recusa(fn){
  try{ await fn(); return null; }catch(e){ return e.message; }
}

// ── O dono cria a conta e o salão ─────────────────────────────────────────
secao('O dono se cadastra e cria o salão');
const dono = novaAba();

const sufixo = Date.now().toString(36);
await dono.criarConta({ email: `dono-${sufixo}@teste.com`, senha: 'barbearia123',
  nome: 'Alessandro Lima', telefone: '+5511' + (900000000 + (Date.now() % 99999999)) });
dizer(!!dono.sessao() && !!dono.sessao().usuarioId, 'conta criada e sessão aberta');

const planos = await dono.lista('planos', {}, 'ordem');
dizer(planos.length >= 6, `os ${planos.length} planos chegam na tela de preços`);
dizer(planos[0].maxProfissionais === 1 && planos[0].precoMes !== undefined,
  'o mapa de colunas traduziu max_profissionais e preco_mes');

const criado = await dono.chamar('criar_salao', {
  p_nome_salao: 'Barbearia Os Meninos dá Vila ' + sufixo,
  p_tipo: 'barbearia', p_telefone: '(11) 96365-9620',
  p_documento: '529.982.247-25', p_origem: 'Instagram' });
const salaoId = criado && criado[0] && criado[0].salao_id;
const slug = criado && criado[0] && criado[0].slug;
dizer(!!salaoId, 'a função criar_salao devolveu o salão', JSON.stringify(criado));
dizer(!!slug && slug.startsWith('barbearia-os-meninos-da-vila'),
  `o apelido saiu sem acento: ${slug}`);

const assin = await dono.lista('minha_assinatura', {});
dizer(assin.length === 1 && assin[0].status === 'trial',
  'a assinatura nasce em teste grátis');
dizer(Number(assin[0].profissionais_ativos) === 1 && Number(assin[0].max_profissionais) === 1,
  'e já mostra 1 de 1 profissional');

// ── O limite do plano, do lado do JavaScript ──────────────────────────────
secao('O limite do plano barra mesmo vindo da tela');
{
  const erro = await recusa(() => dono.inserir('profissionais',
    { salaoId, nome: 'Segundo barbeiro', comissaoPct: 40 }));
  dizer(!!erro && /plano|profissional/i.test(erro),
    'o segundo profissional é recusado, com mensagem legível');
  if(erro) console.log('      banco disse: ' + erro.slice(0,90));
}

// ── Cadastro do catálogo ──────────────────────────────────────────────────
secao('O dono monta o catálogo');
const corte = await dono.inserir('servicos',
  { salaoId, nome: 'Corte masculino', categoria: 'Cabelo',
    duracaoMin: 30, intervaloMin: 5, preco: 50 });
dizer(!!corte && corte.duracaoMin === 30,
  'serviço gravado e lido de volta com duracaoMin');

const profs = await dono.lista('profissionais', { salaoId });
dizer(profs.length === 1 && profs[0].comissaoPct !== undefined,
  'o dono já é o primeiro profissional');

await dono.inserir('jornadas',
  { profissionalId: profs[0].id, diaSemana: 1, inicio: '09:00', fim: '19:00' });
const jornada = await dono.lista('jornadas', { profissionalId: profs[0].id });
dizer(jornada.length === 1 && jornada[0].diaSemana === 1,
  'jornada gravada (dia_semana ↔ diaSemana)');

// ── A vitrine, sem login ──────────────────────────────────────────────────
secao('A vitrine abre para quem não fez login');
const visitante = novaAba();
const vitrine = await visitante.salaoPorSlug(slug);
dizer(!!vitrine && vitrine.nome.startsWith('Barbearia'),
  'o salão é encontrado pelo apelido do link');

{
  const erro = await recusa(() => visitante.lista('clientes', {}));
  const vazio = erro ? null : (await visitante.lista('clientes', {})).length;
  dizer(!!erro || vazio === 0,
    'mas a tabela de clientes continua fechada para o visitante');
}

// ── O cliente entra pelo código e agenda ──────────────────────────────────
secao('O cliente entra pelo código do WhatsApp e marca');
const cliente = novaAba();
// Sem o '+': a ficha do cliente guarda SÓ dígitos — é assim que
// `ficha_do_cliente()` reencontra a mesma pessoa, e a trava
// `cli_tel_so_digitos` do banco agora cobra isso.
const telCliente = '5511' + (910000000 + (Date.now() % 89999999));

{
  const erro = await recusa(() => cliente.conferirCodigo(telCliente, '000000'));
  dizer(!!erro, 'código errado é recusado');
}
await cliente.pedirCodigo(telCliente);
await cliente.conferirCodigo(telCliente, '123456');
dizer(!!cliente.sessao().usuarioId, 'código certo abre a sessão');

// Vira cliente deste salão e marca.
await cliente.inserir('vinculos',
  { perfilId: cliente.sessao().usuarioId, salaoId, papel: 'cliente', status: 'ativo' });
const ficha = await cliente.inserir('clientes',
  { salaoId, perfilId: cliente.sessao().usuarioId, nome: 'João Cliente',
    telefone: telCliente });
dizer(!!ficha, 'a ficha do cliente é criada no salão', JSON.stringify(ficha));

// Agendar precisa de equipe; o cliente não escreve na agenda direto — é o
// desenho do RLS. Quem marca aqui é o dono, como a recepção faria.
const ag = await dono.inserir('agendamentos', {
  salaoId, clienteId: ficha.id, profissionalId: profs[0].id,
  inicio: '2026-09-14T12:00:00Z', fim: '2026-09-14T12:35:00Z',
  status: 'confirmado', origem: 'online', atendidoNome: null });
dizer(!!ag && ag.salaoId === salaoId, 'agendamento gravado pela recepção');

{
  const erro = await recusa(() => cliente.inserir('agendamentos', {
    salaoId, clienteId: ficha.id, profissionalId: profs[0].id,
    inicio: '2026-09-15T12:00:00Z', fim: '2026-09-15T12:35:00Z' }));
  dizer(!!erro, 'o cliente NÃO grava na agenda direto (passa pela função)');
}

// ── A trava anti-choque, chamada pelo JavaScript ──────────────────────────
secao('A trava de horário funciona vinda da tela');
{
  const erro = await recusa(() => dono.inserir('agendamentos', {
    salaoId, clienteId: ficha.id, profissionalId: profs[0].id,
    inicio: '2026-09-14T12:15:00Z', fim: '2026-09-14T12:50:00Z' }));
  dizer(!!erro && /conflit|exclus|choque|agenda_sem_choque/i.test(erro),
    'horário em cima de outro é recusado pelo banco');
  if(erro) console.log('      banco disse: ' + erro.slice(0,90));
}

// ── O isolamento, do lado do JavaScript ───────────────────────────────────
secao('O RLS vale também quando quem chama é a tela');
{
  const meus = await cliente.lista('agendamentos', {});
  dizer(meus.length === 1 && meus[0].clienteId === ficha.id,
    'o cliente enxerga só o agendamento dele');

  const fichas = await cliente.lista('clientes', {});
  dizer(fichas.length === 1, 'e só a própria ficha');

  const outroDono = novaAba();
  await outroDono.criarConta({ email: `outro-${sufixo}@teste.com`, senha: 'outro12345',
    nome: 'Zé Vizinho', telefone: '+5511' + (930000000 + (Date.now() % 69999999)) });
  const nada = await outroDono.lista('agendamentos', {});
  dizer(nada.length === 0, 'o dono de outro salão não alcança nada daqui');
}

// ── Comanda e comissão ────────────────────────────────────────────────────
secao('Comanda fecha e a comissão sai do banco');
{
  const comanda = await dono.inserir('comandas',
    { salaoId, clienteId: ficha.id, agendamentoId: ag.id });
  // bigint chega como texto no driver do Node (e no PostgREST vira número);
  // comparar com Number cobre os dois.
  dizer(!!comanda && Number(comanda.numero) === 1,
    'a comanda ganhou o número 1 pelo gatilho do banco');

  await dono.inserir('comanda_itens', { comandaId: comanda.id, tipo: 'servico',
    servicoId: corte.id, descricao: 'Corte masculino', qtd: 1,
    precoUnit: 50, profissionalId: profs[0].id, comissaoPct: 60 });

  const totais = await dono.lista('comandas_totais', {});
  const t = totais.find(x => x.id === comanda.id);
  dizer(t && Number(t.total) === 50, 'total da comanda = 50');
  dizer(t && Number(t.comissao_total) === 30,
    'comissão de 60% = 30, calculada pelo banco');

  await dono.inserir('pagamentos', { comandaId: comanda.id, forma: 'pix', valor: 50 });
  const pgtos = await dono.lista('pagamentos', { comandaId: comanda.id });
  dizer(pgtos.length === 1 && pgtos[0].forma === 'pix', 'pagamento em Pix registrado');
}

// ── Sair de verdade ───────────────────────────────────────────────────────
secao('Sair fecha o acesso');
{
  await cliente.sair();
  // Sem token, o PostgREST trata como `anon` — que não tem grant nesta
  // tabela. Então o certo é erro de permissão OU lista vazia; as duas
  // respostas significam "não enxerga nada".
  const erro = await recusa(() => cliente.lista('agendamentos', {}));
  const quantos = erro ? null : (await cliente.lista('agendamentos', {})).length;
  dizer(!!erro || quantos === 0, 'depois de sair, não enxerga mais nada');
}

// ── A ponte: baixar, mexer, subir ─────────────────────────────────────────
secao('A ponte entre o `bd` da tela e o banco');
{
  const bd = await dono.baixar(salaoId);
  dizer(Array.isArray(bd.servicos) && bd.servicos.length === 1,
    'baixar() monta o bd com o que existe no banco');
  dizer(Array.isArray(bd.planos) && bd.planos.length >= 6,
    'e traz também as tabelas de leitura (planos)');

  // A tela mexe no objeto, como faria ao clicar em salvar.
  const antes = JSON.parse(JSON.stringify(bd));
  bd.servicos[0].preco = 60;
  bd.servicos.push({ id: crypto.randomUUID(), salaoId, nome: 'Barba',
    categoria: 'Barba', duracaoMin: 30, intervaloMin: 5, preco: 40, ativo: true });

  await dono.subir(antes, bd);

  const depois = await dono.baixar(salaoId);
  dizer(depois.servicos.length === 2, 'serviço novo chegou ao banco');
  const alterado = depois.servicos.find(s => s.nome === 'Corte masculino');
  dizer(alterado && Number(alterado.preco) === 60, 'preço alterado foi gravado');

  // Apagar pela ausência.
  const semBarba = JSON.parse(JSON.stringify(depois));
  semBarba.servicos = semBarba.servicos.filter(s => s.nome !== 'Barba');
  await dono.subir(depois, semBarba);
  const final = await dono.baixar(salaoId);
  dizer(final.servicos.length === 1, 'serviço removido do bd sai do banco também');

  // E o erro do banco NÃO some.
  const ruim = JSON.parse(JSON.stringify(final));
  ruim.profissionais.push({ id: crypto.randomUUID(), salaoId,
    nome: 'Barbeiro além do plano', comissaoPct: 40, ativo: true });
  const erro = await recusa(() => dono.subir(final, ruim));
  dizer(!!erro && /plano/i.test(erro),
    'erro do banco sobe até a tela, não fica engolido');
}

/* ── Os cabeçalhos ────────────────────────────────────────────────────────
   `apikey` diz qual projeto é; `Authorization` diz quem é a pessoa. O Supabase
   trocou o formato da chave pública para `sb_publishable_...`, que não é JWT —
   mandada no Authorization, a plataforma tenta lê-la como token e recusa.

   O dados.js mandava a chave nos dois quando não havia sessão. Funcionava com
   a chave antiga, que era JWT, e passaria a quebrar em todo projeto novo. A
   bancada agora recusa igual ao Supabase, então qualquer volta atrás derruba
   as 33 verificações acima — mas fica também nomeado aqui, para o erro dizer
   o que era em vez de só "falhou tudo".
   ──────────────────────────────────────────────────────────────────────── */
console.log('\nOs cabeçalhos da chave');
{
  const so_apikey = await fetch(BASE + '/rest/v1/planos?select=codigo',
    { headers: { apikey: 'chave-de-teste' } });
  dizer(so_apikey.ok,
    'só com apikey, quem não fez login lê a vitrine', 'status ' + so_apikey.status);

  const nos_dois = await fetch(BASE + '/rest/v1/planos?select=codigo',
    { headers: { apikey: 'chave-de-teste',
                 Authorization: 'Bearer chave-de-teste' } });
  dizer(!nos_dois.ok,
    'a chave do projeto no Authorization é recusada, como no Supabase',
    'status ' + nos_dois.status);
}

/* ═══════════════════════════════════════════════════════════════════════════
   A SESSÃO QUE VENCE NO MEIO DO EXPEDIENTE

   O token do Supabase vale uma hora. Junto dele vem um `refresh_token`, que
   serve para trocá-lo por outro sem pedir a senha de novo. Nós guardávamos
   esse refresh desde o primeiro dia e NUNCA o usávamos.

   Uma hora depois do login, então: 401 em toda requisição, o `baixar()`
   engolindo o 401 como "é o RLS funcionando", e o painel abrindo com tudo
   vazio — "Nenhum salão nesta conta" para quem tem salão, agenda e caixa
   lá dentro.

   Aqui não pegava porque na bancada o token não vencia nunca. Agora ele
   vence, e a porta `/_expirar` mata o token na hora, para o que em produção
   leva uma hora acontecer aqui em um segundo.
   ═══════════════════════════════════════════════════════════════════════════ */
secao('A sessão vence, e o sistema se vira sozinho');
{
  const p = novaAba();
  const marca = 'renova-' + Date.now().toString(36);
  await p.criarConta({ email: marca + '@teste.com', senha: 'minhasenhaboa',
    nome: 'Marta Prado', telefone: '+5551' + (700000000 + (Date.now() % 99999999)) });
  await p.chamar('criar_salao', { p_nome_salao: 'Salao ' + marca, p_tipo:'salao',
    p_telefone:'(51) 99887-6655', p_documento:null, p_origem:null });

  const antes = p.sessao();
  dizer(!!antes.expiraEm && antes.expiraEm > Date.now(),
    'o login anota QUANDO o token vence', JSON.stringify(antes.expiraEm));
  dizer(!!antes.refresh, 'e guarda o refresh_token, que é o que renova');

  // Mata o token que está na mão dela, como o relógio faria numa hora.
  const morto = await fetch(BASE + '/_expirar',
    { method:'POST', headers:{ Authorization: 'Bearer ' + antes.token } })
    .then(r => r.json());
  dizer(morto.expirado === true, 'a bancada mata o token, como o relógio faria');

  const salos = await p.lista('saloes');
  dizer(salos.length === 1,
    'com o token vencido, a leitura AINDA funciona — renovou sozinha',
    'vieram ' + salos.length + ' salões');
  dizer(p.sessao() && p.sessao().token !== antes.token,
    'e o token guardado é outro, não o que venceu');

  /* A metade que importa: gravar. Uma renovação que só conserta a leitura
     deixa a pessoa achando que o sistema voltou — e perdendo o que digita. */
  const meu = salos[0];
  await p.atualizar('saloes', meu.id, { whatsapp: '(51) 90000-0000' });
  const conferido = (await p.lista('saloes'))[0];
  dizer(conferido.whatsapp === '(51) 90000-0000',
    'e a gravação também passa depois da renovação', conferido.whatsapp);

  /* Quando nem o refresh vale mais, a sessão acabou de verdade. Aí o certo é
     apagá-la: guardada, ela faria cada tela seguinte tentar e falhar calada.
     E o `baixar()` precisa dizer `sessaoExpirou` — é o que separa "entre para
     ver sua agenda" de "sua sessão expirou, seus dados estão todos lá". */
  const viva = p.sessao();
  await fetch(BASE + '/_expirar',
    { method:'POST', headers:{ Authorization: 'Bearer ' + viva.token } });
  p.sessao().refresh = 'refresh-que-nao-existe';

  const bd = await p.baixar();
  dizer(bd.sessaoExpirou === true,
    'refresh recusado: o painel sabe que a sessão VENCEU, não que nunca houve');
  dizer(bd.semSessao === true, 'e trata como sem sessão, para não abrir vazio');
  dizer(p.sessaoAtual() === null,
    'a sessão morta é apagada, em vez de ficar tentando para sempre');
}

console.log('\n' + (falhas
  ? `✗ ${falhas} de ${ok+falhas} falharam.`
  : `✓ ${ok} verificações contra um Postgres de verdade.`));
process.exit(falhas ? 1 : 0);
