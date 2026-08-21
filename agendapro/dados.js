/* ===========================================================================
   AgendaPro — camada de dados
   ---------------------------------------------------------------------------
   Um lugar só conversa com o armazenamento. As telas chamam funções daqui e
   nunca sabem se o dado veio do navegador ou do banco.

   DOIS MODOS, escolhidos pelo config.js:
     demo  — localStorage. Roda sem instalar nada, serve para conhecer.
     nuvem — Supabase de verdade, via a API REST (PostgREST) e a API de Auth.

   POR QUE `fetch` E NÃO O SDK DO SUPABASE
   O SDK viria de um CDN. CDN fora do ar = tela branca, e o projeto inteiro
   foi feito para não depender de build nem de pacote. São ~200 linhas de
   fetch, todas legíveis, sem nada pendurado.

   AS DUAS LÍNGUAS
   A tela fala camelCase (`salaoId`, `duracaoMin`) porque é JavaScript. O
   banco fala snake_case (`salao_id`, `duracao_min`) porque é Postgres. A
   tradução mora no mapa COLUNAS logo abaixo, num lugar só — e é justamente
   esse mapa que `tests/colunas.test.js` confere contra o schema de verdade,
   porque nome de coluna errado é o erro mais bobo e mais caro daqui.
   =========================================================================== */

(function (global) {
'use strict';

/* ── O mapa das duas línguas ──────────────────────────────────────────────
   chave  = nome no JavaScript
   valor  = nome da coluna no Postgres
   Campo que não aparece aqui vai com o mesmo nome nos dois lados.
   ──────────────────────────────────────────────────────────────────────── */
const COLUNAS = {
  // `saloes` não entra no mapa de propósito. Uma versão anterior traduzia
  // `id` para `salaoId` aqui, e isso renomeava a CHAVE PRIMÁRIA: o objeto
  // chegava na tela sem `.id`, e todo `bd.saloes[0].id` virava undefined.
  // A agenda abria vazia dizendo "nenhum profissional", porque o filtro por
  // salão saía com undefined. Chave primária se chama `id` dos dois lados.
  perfis:        { superAdmin:'super_admin', criadoEm:'criado_em' },
  vinculos:      { perfilId:'perfil_id', salaoId:'salao_id', criadoEm:'criado_em' },
  profissionais: { salaoId:'salao_id', perfilId:'perfil_id',
                   comissaoPct:'comissao_pct', aceitaOnline:'aceita_online',
                   criadoEm:'criado_em' },
  servicos:      { salaoId:'salao_id', duracaoMin:'duracao_min',
                   intervaloMin:'intervalo_min', comissaoPct:'comissao_pct',
                   aceitaOnline:'aceita_online', criadoEm:'criado_em' },
  jornadas:      { profissionalId:'profissional_id', diaSemana:'dia_semana' },
  bloqueios:     { salaoId:'salao_id', profissionalId:'profissional_id',
                   criadoEm:'criado_em' },
  clientes:      { salaoId:'salao_id', perfilId:'perfil_id', criadoEm:'criado_em' },
  agendamentos:  { salaoId:'salao_id', clienteId:'cliente_id',
                   profissionalId:'profissional_id', valorPrevisto:'valor_previsto',
                   canceladoMotivo:'cancelado_motivo', atendidoNome:'atendido_nome',
                   sinalExigido:'sinal_exigido', sinalPago:'sinal_pago',
                   sinalRef:'sinal_ref', criadoPor:'criado_por', criadoEm:'criado_em' },
  agendamento_servicos: { agendamentoId:'agendamento_id', servicoId:'servico_id',
                   duracaoMin:'duracao_min', comissaoPct:'comissao_pct' },
  lista_espera:  { salaoId:'salao_id', clienteId:'cliente_id',
                   profissionalId:'profissional_id', duracaoMin:'duracao_min',
                   avisadoEm:'avisado_em', criadoEm:'criado_em' },
  produtos:      { salaoId:'salao_id', comissaoPct:'comissao_pct' },
  comandas:      { salaoId:'salao_id', agendamentoId:'agendamento_id',
                   clienteId:'cliente_id', descontoMotivo:'desconto_motivo',
                   abertaEm:'aberta_em', fechadaEm:'fechada_em',
                   abertaPor:'aberta_por' },
  comanda_itens: { comandaId:'comanda_id', servicoId:'servico_id',
                   produtoId:'produto_id', precoUnit:'preco_unit',
                   profissionalId:'profissional_id', comissaoPct:'comissao_pct',
                   comissaoValor:'comissao_valor' },
  pagamentos:    { comandaId:'comanda_id', recebidoEm:'recebido_em' },
  planos:        { maxProfissionais:'max_profissionais', precoMes:'preco_mes' },
  assinaturas:   { salaoId:'salao_id', trialAte:'trial_ate', venceEm:'vence_em',
                   indicadoPor:'indicado_por', criadoEm:'criado_em',
                   atualizadoEm:'atualizado_em' },
};

// Campos que existem só na tela e NÃO devem ir para o banco. Mandar coluna
// inexistente faz o PostgREST devolver 400 e derruba a gravação inteira.
const SO_DA_TELA = {
  agendamentos: ['servicos'],       // vira linhas em agendamento_servicos
  comandas:     ['itens','pagamentos','numero'],  // numero é do gatilho
  profissionais:['jornada'],        // vira linhas em jornadas
  assinaturas:  ['planoPretendido'],
};

/* ── CAMPO VAZIO NÃO É TEXTO VAZIO ────────────────────────────────────────
   Um <input> nunca devolve null: quando ninguém digitou nada, ele devolve
   `''`. Para uma coluna de texto tudo bem. Para data, número ou uuid, o
   Postgres recusa a gravação inteira:

       clientes: invalid input syntax for type date: ""

   Foi o que apareceu ao cadastrar um cliente sem preencher a data de
   nascimento — um campo opcional derrubando o cadastro todo. E não era um
   caso isolado: são 18 colunas anuláveis de data, número e uuid que alguma
   tela pode deixar em branco, cada uma esperando a vez.

   Consertar formulário por formulário deixaria as outras 17 de pé. Aqui a
   regra é uma só, no ponto por onde tudo passa: nestas colunas, "em branco"
   quer dizer null.

   Coluna de TEXTO fica de fora de propósito. Lá `''` e null são coisas
   diferentes — apagar a observação de um cliente é uma intenção legítima, e
   virar null quebraria as que são NOT NULL.

   A lista sai do schema de verdade, e o tests/colunas.test.js confere que ela
   continua completa: coluna nova desse tipo entra aqui ou reprova lá. */
const VAZIO_E_NULO = new Set([
  'nascimento', 'perfil_id', 'profissional_id', 'produto_id', 'servico_id',
  'agendamento_id', 'criado_por', 'aberta_por', 'fechada_em', 'avisado_em',
  'comissao_pct', 'comissao_valor', 'total', 'duracao_min', 'preco',
  'trial_ate', 'vence_em', 'indicado_por', 'cliente_id', 'sinal_exigido',
  'sinal_pago', 'nascimento_dia',
]);

function paraBanco(tabela, obj){
  const mapa = COLUNAS[tabela] || {};
  const fora = SO_DA_TELA[tabela] || [];
  const saida = {};
  for(const k of Object.keys(obj)){
    if(fora.includes(k)) continue;
    if(obj[k] === undefined) continue;
    const coluna = mapa[k] || k;
    saida[coluna] = (obj[k] === '' && VAZIO_E_NULO.has(coluna)) ? null : obj[k];
  }
  return saida;
}

function paraTela(tabela, linha){
  const mapa = COLUNAS[tabela] || {};
  const inverso = {};
  for(const k of Object.keys(mapa)) inverso[mapa[k]] = k;
  const saida = {};
  for(const k of Object.keys(linha)) saida[inverso[k] || k] = linha[k];
  return saida;
}

/* ── Conversa com o Supabase ─────────────────────────────────────────── */
const cfg = global.AGENDAPRO || {};
const LIGADO = !!(cfg.url && cfg.chave);

let sessao = null;   // { token, refresh, usuarioId, expiraEm }

const CHAVE_SESSAO = 'agendapro.sessao';

function guardarSessao(s){
  sessao = s;
  try{
    if(s) localStorage.setItem(CHAVE_SESSAO, JSON.stringify(s));
    else localStorage.removeItem(CHAVE_SESSAO);
  }catch(e){ console.error('[dados] não consegui guardar a sessão:', e); }
}

function lerSessao(){
  try{
    const cru = localStorage.getItem(CHAVE_SESSAO);
    if(cru) sessao = JSON.parse(cru);
  }catch(e){ console.error('[dados] sessão guardada está corrompida:', e); }
  return sessao;
}

/* ── OS DOIS CABEÇALHOS, E POR QUE ELES NÃO SÃO A MESMA COISA ─────────────
   `apikey` diz QUAL PROJETO é. Vai em toda requisição, sempre.
   `Authorization` diz QUEM É A PESSOA. Só existe depois do login.

   A primeira versão mandava a chave do projeto nos dois quando não havia
   sessão — `Authorization: Bearer <chave>`. Funcionava porque a chave antiga
   (`anon`) era um JWT, e o PostgREST lia dela o papel `anon`.

   O Supabase trocou o formato: a chave nova é `sb_publishable_...`, que não é
   JWT. Mandada no `Authorization`, a plataforma tenta interpretar como token
   e RECUSA. Existe uma exceção — vale se o valor for idêntico ao do `apikey`
   — mas depender de exceção é escolher o caminho que quebra primeiro.

   Sem `Authorization`, o PostgREST resolve o papel pelo `apikey` e roda como
   `anon`, que é justamente o que a vitrine pública precisa: a cliente abre o
   link do salão sem ter conta nenhuma. Com token, vira `authenticated` e o
   RLS aplica as regras daquela pessoa.

   Assim funciona com os dois formatos de chave, o velho e o novo.
   ──────────────────────────────────────────────────────────────────────── */
function cabecalhos(extra){
  const h = {
    'apikey': cfg.chave,
    'Content-Type': 'application/json',
  };
  if(sessao && sessao.token) h['Authorization'] = 'Bearer ' + sessao.token;
  return Object.assign(h, extra || {});
}

// Erro do PostgREST vem em JSON com `message`, `details` e `hint`. Mostrar
// só "400 Bad Request" faz perder justamente a frase que explica o que
// aconteceu — inclusive as mensagens que os gatilhos do banco escrevem.
async function conferir(resp){
  if(resp.ok) return resp;
  let msg = resp.status + ' ' + resp.statusText;
  try{
    const corpo = await resp.json();
    msg = corpo.message || corpo.error_description || corpo.error || msg;
    if(corpo.hint) msg += ' — ' + corpo.hint;
    if(corpo.details && !corpo.message) msg += ' (' + corpo.details + ')';
  }catch(e){ /* resposta sem JSON; fica o status mesmo */ }
  const erro = new Error(msg);
  erro.status = resp.status;
  throw erro;
}

async function rest(caminho, opcoes){
  // ⚠ Os cabeçalhos são montados DEPOIS da cópia das opções, de propósito.
  //
  // A primeira versão fazia `Object.assign({headers: cabecalhos(...)}, opcoes)`
  // — e quando a chamada trazia o próprio `headers` (o `Prefer` do insert),
  // ele substituía o objeto inteiro em vez de somar. Resultado: a requisição
  // saía SEM o Authorization, o banco tratava o dono como visitante anônimo
  // e devolvia "permission denied".
  //
  // O erro só aparecia na gravação, nunca na leitura, e a mensagem apontava
  // para permissão de tabela — o lugar errado. Quem pegou foi o teste contra
  // um Postgres de verdade (tests/nuvem.test.mjs).
  const o = Object.assign({}, opcoes || {});
  o.headers = cabecalhos(o.headers);

  const resp = await fetch(cfg.url + '/rest/v1/' + caminho, o);
  await conferir(resp);
  const txt = await resp.text();
  return txt ? JSON.parse(txt) : null;
}

async function auth(caminho, corpo, metodo){
  // Mesma regra do `cabecalhos()` logo acima: a chave do projeto só no
  // `apikey`, e o `Authorization` só quando há uma pessoa logada. Entrar e
  // criar conta acontecem JUSTAMENTE quando não há — mandar a chave ali
  // faria o login falhar antes de tentar.
  const h = { 'apikey': cfg.chave, 'Content-Type': 'application/json' };
  if(sessao && sessao.token) h['Authorization'] = 'Bearer ' + sessao.token;
  const resp = await fetch(cfg.url + '/auth/v1/' + caminho, {
    method: metodo || 'POST',
    headers: h,
    body: corpo ? JSON.stringify(corpo) : undefined,
  });
  await conferir(resp);
  const txt = await resp.text();
  return txt ? JSON.parse(txt) : null;
}

/* ── As operações que as telas usam ──────────────────────────────────── */

const Nuvem = {
  modo: 'nuvem',

  // ── Autenticação ──
  async criarConta({ email, senha, nome, telefone }){
    const r = await auth('signup', { email, password: senha,
      data: { nome, telefone } });
    if(r.access_token){
      guardarSessao({ token: r.access_token, refresh: r.refresh_token,
                      usuarioId: r.user && r.user.id });
    }
    return r;
  },

  async entrar({ email, senha }){
    const r = await auth('token?grant_type=password', { email, password: senha });
    guardarSessao({ token: r.access_token, refresh: r.refresh_token,
                    usuarioId: r.user && r.user.id });
    return r;
  },

  // Código no WhatsApp: quem gera, valida e expira é o Supabase Auth. A
  // entrega passa pelo Send SMS Hook, que chama a Edge Function. Nada disso
  // acontece aqui — é justamente o ponto: o navegador nunca vê o código.
  async pedirCodigo(telefone){
    return auth('otp', { phone: telefone, create_user: true });
  },

  async conferirCodigo(telefone, codigo){
    const r = await auth('verify', { type: 'sms', phone: telefone, token: codigo });
    guardarSessao({ token: r.access_token, refresh: r.refresh_token,
                    usuarioId: r.user && r.user.id });
    return r;
  },

  async sair(){
    try{ await auth('logout', {}); }catch(e){ /* token já morto, tudo bem */ }
    guardarSessao(null);
  },

  sessao(){ return sessao; },

  // ── Leitura ──
  async lista(tabela, filtro, ordem){
    const q = new URLSearchParams();
    q.set('select', '*');
    for(const k of Object.keys(filtro || {})){
      const mapa = COLUNAS[tabela] || {};
      q.set(mapa[k] || k, 'eq.' + filtro[k]);
    }
    if(ordem) q.set('order', ordem);
    const linhas = await rest(tabela + '?' + q.toString());
    return (linhas || []).map(l => paraTela(tabela, l));
  },

  async inserir(tabela, obj){
    const linhas = await rest(tabela, {
      method: 'POST',
      headers: { 'Prefer': 'return=representation' },
      body: JSON.stringify(paraBanco(tabela, obj)),
    });
    return linhas && linhas[0] ? paraTela(tabela, linhas[0]) : null;
  },

  async atualizar(tabela, id, mudancas){
    const chave = tabela === 'assinaturas' ? 'salao_id' : 'id';
    const linhas = await rest(tabela + '?' + chave + '=eq.' + id, {
      method: 'PATCH',
      headers: { 'Prefer': 'return=representation' },
      body: JSON.stringify(paraBanco(tabela, mudancas)),
    });
    return linhas && linhas[0] ? paraTela(tabela, linhas[0]) : null;
  },

  async apagar(tabela, id){
    await rest(tabela + '?id=eq.' + id, { method: 'DELETE' });
  },

  async chamar(funcao, argumentos){
    return rest('rpc/' + funcao, {
      method: 'POST', body: JSON.stringify(argumentos || {}) });
  },

  /* ── A vitrine, que abre sem login ────────────────────────────────────
     Antes isto lia a vista `saloes_publicos` filtrando pelo apelido. Lia bem,
     e vazava do lado que ninguém olha: quem tirasse o filtro recebia TODOS os
     salões da plataforma, com nome, endereço e WhatsApp. Não é dado de
     cliente — é a lista de clientes DO NEGÓCIO, entregue numa requisição a
     qualquer concorrente com a chave publicável, que fica à vista no código
     da página de propósito.

     Agora é uma função que só responde a quem já sabe o apelido. E vem tudo
     de uma vez — salão, serviços e profissionais — em vez de três idas ao
     servidor: no 3G da cliente, é a diferença entre abrir e demorar.
     ──────────────────────────────────────────────────────────────────── */
  async vitrine(slug){
    const r = await rest('rpc/vitrine', {
      method: 'POST', body: JSON.stringify({ p_slug: slug }) });
    // Função que devolve escalar vem crua; a de conjunto vem em lista.
    const v = Array.isArray(r) ? r[0] : r;
    return v && v.salao ? v : null;
  },

  // Compatibilidade: quem só quer o salão continua chamando isto.
  async salaoPorSlug(slug){
    const v = await this.vitrine(slug);
    return v ? v.salao : null;
  },
};

/* ── Modo demonstração ───────────────────────────────────────────────────
   Mesma API, guardando no navegador. Existe para o sistema poder ser
   conhecido sem instalar nada — e para o dia em que o Supabase estiver fora
   do ar durante uma apresentação.
   ──────────────────────────────────────────────────────────────────────── */
const CHAVE_DEMO = 'agendapro.demo.v1';

function lerDemo(){
  try{
    const cru = localStorage.getItem(CHAVE_DEMO);
    return cru ? JSON.parse(cru) : {};
  }catch(e){
    console.error('[dados] dados de demonstração corrompidos:', e);
    return {};
  }
}
function gravarDemo(d){
  try{ localStorage.setItem(CHAVE_DEMO, JSON.stringify(d)); }
  catch(e){ console.error('[dados] não consegui gravar:', e); throw e; }
}
/* ── IDENTIFICADOR NOVO, VÁLIDO NOS DOIS MUNDOS ───────────────────────────
   Isto era `'x' + Math.random().toString(36).slice(2,10)` — algo como
   "xxe7qkwou". No navegador funciona: é só uma chave de objeto. No Postgres,
   não: as colunas `id` são `uuid`, e o que voltava era

       clientes: invalid input syntax for type uuid: "xxe7qkwou"

   Quer dizer que NADA criado pelo painel — cliente, serviço, agendamento,
   comanda, profissional, jornada — conseguia ser gravado no banco. A tela
   mostrava a linha, o `subir()` era recusado, e o aviso dizia a verdade que
   ninguém quer ler: "o que está na tela ainda não foi gravado".

   Nenhum teste pegou porque todos abrem o painel em `?demo=1`, e lá o id vive
   no localStorage, onde qualquer texto serve. É a terceira vez que o defeito
   mora exatamente no modo que os testes não visitavam.

   UUID de verdade resolve dos dois lados: o Postgres aceita, e para o
   localStorage continua sendo só um texto único. Não dá para deixar o banco
   gerar (`gen_random_uuid()`), porque a tela usa o id no mesmo instante em
   que cria a linha — `clienteId: cli.id` acontece antes de qualquer viagem
   até o servidor.
   ──────────────────────────────────────────────────────────────────────── */
function novoId(){
  // Caminho normal em https e em localhost.
  try{
    if(typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  }catch(e){}

  // `crypto.randomUUID` exige contexto seguro, e as cópias avulsas de dist/
  // abrem em file://. Aqui o mesmo formato, montado à mão.
  try{
    if(typeof crypto !== 'undefined' && crypto.getRandomValues){
      const b = crypto.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40;        // versão 4
      b[8] = (b[8] & 0x3f) | 0x80;        // variante RFC 4122
      const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
      return h.slice(0,8) + '-' + h.slice(8,12) + '-' + h.slice(12,16)
           + '-' + h.slice(16,20) + '-' + h.slice(20);
    }
  }catch(e){}

  // Último recurso, para navegador antigo. Colide muito menos do que os oito
  // caracteres de antes, e continua sendo um uuid válido para o Postgres.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

const Demo = {
  modo: 'demo',

  async criarConta({ nome, telefone, email }){
    const d = lerDemo();
    d.perfis = d.perfis || [];
    const p = { id: novoId(), nome, telefone, email };
    d.perfis.push(p); gravarDemo(d);
    guardarSessao({ token: null, usuarioId: p.id });
    return { user: { id: p.id } };
  },
  async entrar(){ throw new Error('Login por senha só existe no modo nuvem.'); },
  async pedirCodigo(){ return { demo: true }; },
  async conferirCodigo(telefone){
    const d = lerDemo();
    d.perfis = d.perfis || [];
    let p = d.perfis.find(x => x.telefone === telefone);
    if(!p){ p = { id: novoId(), nome: '', telefone }; d.perfis.push(p); gravarDemo(d); }
    guardarSessao({ token: null, usuarioId: p.id });
    return { user: { id: p.id } };
  },
  async sair(){ guardarSessao(null); },
  sessao(){ return sessao; },

  async lista(tabela, filtro){
    const d = lerDemo();
    let linhas = d[tabela] || [];
    for(const k of Object.keys(filtro || {})) linhas = linhas.filter(x => x[k] === filtro[k]);
    return linhas.slice();
  },
  async inserir(tabela, obj){
    const d = lerDemo();
    d[tabela] = d[tabela] || [];
    const novo = Object.assign({ id: obj.id || novoId() }, obj);
    d[tabela].push(novo); gravarDemo(d);
    return novo;
  },
  async atualizar(tabela, id, mudancas){
    const d = lerDemo();
    const chave = tabela === 'assinaturas' ? 'salaoId' : 'id';
    const alvo = (d[tabela] || []).find(x => x[chave] === id);
    if(alvo) Object.assign(alvo, mudancas);
    gravarDemo(d);
    return alvo || null;
  },
  async apagar(tabela, id){
    const d = lerDemo();
    d[tabela] = (d[tabela] || []).filter(x => x.id !== id);
    gravarDemo(d);
  },
  async chamar(funcao, args){
    // As funções do banco não existem aqui; as telas têm a versão de tela.
    console.info('[dados] rpc "' + funcao + '" ignorada no modo demonstração.');
    return null;
  },
  async salaoPorSlug(slug){
    return (lerDemo().saloes || []).find(s => s.slug === slug) || null;
  },
};

/* ===========================================================================
   A PONTE — como as telas existentes falam com o banco sem serem reescritas
   ---------------------------------------------------------------------------
   As três telas trabalham com um objeto `bd` inteiro na memória e chamam
   `salvar()` quando algo muda. Reescrever isso para "uma chamada por
   alteração" seria mexer em cada botão dos três arquivos — muito risco para
   pouco ganho.

   Em vez disso: `baixar()` monta o `bd` a partir do banco, e `subir()`
   compara o `bd` de agora com o que foi baixado e grava só a diferença.
   As telas continuam iguais; quem sabe de banco é este arquivo.

   O que a comparação faz: linha nova (id que não existia) vira INSERT,
   linha diferente vira UPDATE só dos campos que mudaram, linha que sumiu
   vira DELETE. Campo calculado pelo banco (número da comanda, total,
   comissão) fica fora, porque escrever de volta o que o banco calculou é
   pedir divergência.
   =========================================================================== */

const TABELAS_SINCRONIZADAS = [
  'saloes','profissionais','servicos','servicos_profissionais','jornadas',
  'bloqueios','clientes','agendamentos','lista_espera','produtos',
  'comandas','comanda_itens','pagamentos',
];

// Só leitura: quem manda nelas é a plataforma, não a tela.
const TABELAS_SO_LEITURA = ['planos','assinaturas','perfis','vinculos'];

function mesmaCoisa(a, b){
  return JSON.stringify(a) === JSON.stringify(b);
}

// O que mudou de `antes` para `agora`, campo a campo.
function diferenca(tabela, antes, agora){
  const soDaTela = SO_DA_TELA[tabela] || [];
  const d = {};
  for(const k of Object.keys(agora)){
    if(k === 'id') continue;
    /* Campo que só existe na tela não pode DECIDIR uma gravação. A jornada de
       um profissional mora aqui como `p.jornada` e no banco como linhas da
       tabela `jornadas`; mudá-la marcava o profissional como "diferente", e o
       update que saía disso ficava vazio depois de o `paraBanco()` remover o
       campo — um PATCH sem nada para mudar, recusado pelo servidor. */
    if(soDaTela.includes(k)) continue;
    if(!mesmaCoisa(antes[k], agora[k])) d[k] = agora[k];
  }
  return d;
}

async function baixar(salaoId){
  // Sem sessão não há o que buscar: cada tabela responderia 400 e o console
  // encheria de erro para dizer "você não está logado", que a tela já sabe.
  if(LIGADO && !(sessao && sessao.token)){
    const vazio = {};
    for(const t of TABELAS_SO_LEITURA.concat(TABELAS_SINCRONIZADAS)) vazio[t] = [];
    vazio.semSessao = true;
    return vazio;
  }
  const bd = {};
  for(const t of TABELAS_SO_LEITURA.concat(TABELAS_SINCRONIZADAS)){
    try{
      /* ── QUEM PODE SER FILTRADA POR SALÃO ────────────────────────────────
         Aqui havia uma lista escrita à mão — `['saloes','planos','perfis',
         'vinculos']` — com as tabelas que não têm `salao_id`. A lista estava
         incompleta, e faltavam quatro: `jornadas`, `servicos_profissionais`,
         `comanda_itens` e `pagamentos`.

         Nessas quatro o filtro saía como `salaoId=eq.…`, o PostgREST punha em
         minúsculas, procurava a coluna `salaoid`, não achava e devolvia 400.
         O `catch` logo abaixo engolia o 400 e devolvia lista vazia — então o
         painel na nuvem abria sem jornada de trabalho (agenda sem horário
         livre nenhum), sem o vínculo serviço↔profissional, e com o Caixa
         zerado: item de comanda e pagamento são o histórico de dinheiro do
         salão, e ele simplesmente não chegava na tela. Nenhum teste pegou
         porque todos abrem o painel em `?demo=1`, e no navegador o campo se
         chama `salaoId` mesmo.

         Lista escrita à mão envelhece calada. O mapa COLUNAS já sabe quem tem
         `salao_id` — e é conferido contra o schema de verdade pelo
         colunas.test.js. Perguntando a ele, tabela nova entra certa sozinha.

         `vinculos` fica de fora de propósito, mesmo tendo a coluna: é por ela
         que se descobre a QUAIS salões a pessoa pertence. Filtrar pelo salão
         atual esconderia os outros dela. */
      const temSalao = t !== 'vinculos' && !!(COLUNAS[t] && COLUNAS[t].salaoId);
      const filtro = (salaoId && temSalao) ? { salaoId } : {};
      bd[t] = await Dados.lista(t, filtro);
    }catch(e){
      /* Tabela que esta pessoa não alcança não é erro: é o RLS funcionando, e
         seguir com lista vazia é o certo. Mas "não alcança" e "a pergunta
         estava malfeita" chegavam aqui com a mesma cara, e foi assim que os
         400 acima passaram anos parecendo permissão. Agora o segundo caso
         grita — porque ele é defeito nosso, e some se ninguém olhar. */
      const cru = String(e.message || '');
      if(/does not exist|malformed|invalid input|400/i.test(cru)){
        console.error('[dados] pergunta malfeita para "' + t + '" — isto é '
          + 'defeito do código, não permissão: ' + cru);
      } else {
        console.info('[dados] sem acesso a "' + t + '": ' + cru);
      }
      bd[t] = [];
    }
  }
  return bd;
}

async function subir(antes, agora){
  const problemas = [];
  for(const t of TABELAS_SINCRONIZADAS){
    const velhas = new Map((antes[t] || []).map(x => [x.id, x]));
    const novas  = new Map((agora[t] || []).map(x => [x.id, x]));

    for(const [id, linha] of novas){
      try{
        if(!velhas.has(id)){
          await Dados.inserir(t, linha);
        } else {
          const d = diferenca(t, velhas.get(id), linha);
          if(Object.keys(d).length) await Dados.atualizar(t, id, d);
        }
      }catch(e){ problemas.push(t + ': ' + e.message); }
    }
    for(const id of velhas.keys()){
      if(!novas.has(id)){
        try{ await Dados.apagar(t, id); }
        catch(e){ problemas.push(t + ' (apagar): ' + e.message); }
      }
    }
  }
  // Erro aqui NÃO pode passar calado: a tela mostraria o dado salvo enquanto
  // o banco não recebeu nada. Foi um dos vícios do AdminPro que este projeto
  // se propôs a não repetir.
  if(problemas.length) throw new Error(problemas.join(' | '));
}

/* ── Imagens ──────────────────────────────────────────────────────────
   O Storage do Supabase não é o PostgREST: outro caminho, outro verbo, e o
   corpo vai binário, não JSON. Por isso não passa pelo `rest()`.

   `x-upsert: true` porque trocar a logo é o caso normal — sem isso o segundo
   envio devolveria "resource already exists" e o dono ficaria preso na
   primeira foto que escolheu.

   O caminho é sempre `<salao_id>/<arquivo>`: é dele que a policy do balde tira
   de quem é o arquivo. Mudar essa convenção aqui sem mudar lá abre a porta
   para um dono sobrescrever a logo do salão vizinho.
   ──────────────────────────────────────────────────────────────────────── */
async function enviarImagem(salaoId, nomeArquivo, blob){
  if(!salaoId) throw new Error('Sem salão: não sei em que pasta guardar.');
  const caminho = salaoId + '/' + nomeArquivo;

  const resp = await fetch(cfg.url + '/storage/v1/object/salao/' + caminho, {
    method: 'POST',
    headers: {
      'apikey': cfg.chave,
      'Authorization': 'Bearer ' + ((sessao && sessao.token) || cfg.chave),
      'Content-Type': blob.type || 'image/jpeg',
      'x-upsert': 'true',
    },
    body: blob,
  });
  if(!resp.ok){
    const txt = await resp.text().catch(() => '');
    throw new Error('Falha ao enviar a imagem (' + resp.status + '): ' + txt);
  }

  // `?v=` derruba o cache do navegador e da CDN. Sem isso, trocar a logo não
  // muda nada na tela: o endereço é o mesmo e o navegador devolve a antiga.
  return cfg.url + '/storage/v1/object/public/salao/' + caminho + '?v=' + Date.now();
}

async function apagarImagem(salaoId, nomeArquivo){
  const caminho = salaoId + '/' + nomeArquivo;
  const resp = await fetch(cfg.url + '/storage/v1/object/salao/' + caminho, {
    method: 'DELETE',
    headers: {
      'apikey': cfg.chave,
      'Authorization': 'Bearer ' + ((sessao && sessao.token) || cfg.chave),
    },
  });
  // 404 não é erro: o arquivo já não estava lá, que é o estado desejado.
  if(!resp.ok && resp.status !== 404){
    throw new Error('Falha ao apagar a imagem (' + resp.status + ').');
  }
}

/* ── O que as telas enxergam ─────────────────────────────────────────── */
const Dados = LIGADO ? Nuvem : Demo;
Dados.baixar = baixar;
Dados.subir = subir;
Dados.TABELAS_SINCRONIZADAS = TABELAS_SINCRONIZADAS;

Dados.enviarImagem = enviarImagem;
Dados.apagarImagem = apagarImagem;

/* Quem está logado, se é que alguém está. Existe porque uma tela precisa
   saber a diferença entre "ninguém entrou" e "entrou, mas não pode".

   Sem isto, o admin.html olhava só a recusa do banco — que é a mesma nos dois
   casos, `insufficient_privilege` — e dizia "esta conta não é da plataforma"
   para quem não tinha conta nenhuma na jogada. A pessoa vai conferir o
   super_admin, encontra tudo certo, e perde a tarde procurando o que não
   está quebrado. */
Dados.sessaoAtual = () => (sessao && sessao.token) ? sessao : null;

/* As telas cunham id antes de gravar, e o formato tem que ser o mesmo em
   todas — foi por elas terem cada uma a sua cópia que o painel ficou meses
   mandando "xxe7qkwou" para uma coluna uuid. Uma implementação só, aqui. */
Dados.novoId = novoId;
Dados.VAZIO_E_NULO = VAZIO_E_NULO;   // conferido contra o schema pelo colunas.test.js

Dados.ligado = LIGADO;
Dados.ambiente = cfg.ambiente || (LIGADO ? 'nuvem' : 'demonstração');
Dados.COLUNAS = COLUNAS;      // exposto para o teste de colunas
Dados.paraBanco = paraBanco;
Dados.paraTela = paraTela;

lerSessao();

global.Dados = Dados;

if(!LIGADO){
  console.info('[AgendaPro] Modo demonstração — os dados ficam neste navegador. '
             + 'Para ligar no Supabase, preencha url e chave em config.js.');
} else {
  console.info('[AgendaPro] Ligado em ' + cfg.url);
}

})(window);
