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
                   sinalRef:'sinal_ref', criadoPor:'criado_por', criadoEm:'criado_em',
                   encaixePor:'encaixe_por',
                   arquivadoEm:'arquivado_em' },
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
  comandas:     ['itens','pagamentos','numero','data'],
  profissionais:['jornada'],        // vira linhas em jornadas
  assinaturas:  ['planoPretendido'],
  // `total` e `comissao_valor` são GENERATED ALWAYS no schema: o Postgres
  // recusa escrita neles, e a gravação inteira cai junto. Quem calcula é o
  // banco, e é assim que a conta da comanda não depende da versão da tela.
  comanda_itens: ['total','comissaoValor'],
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
  'sinal_pago', 'nascimento_dia', 'arquivado_em',
  /* Estas duas entraram quando o `colunas.test.js` passou a ler também as
     colunas criadas por `alter table`. Ele não as via antes — e por isso não
     acusava —, mas o Postgres via: `invalid input syntax for type uuid: ""`
     derruba a gravação inteira, não só o campo.

     `marketing_saiu_em` já estava assim desde o módulo de campanhas. Ficou
     escondido porque nada exercitava o caminho de "a pessoa saiu da lista e
     depois voltou". */
  'marketing_saiu_em', 'encaixe_por',
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

/* Resposta de função que devolve ARRAY jsonb. Vem como a própria lista; se
   algum dia vier embrulhada numa linha, o segundo caso desembrulha. */
function listaJsonb(r){
  if(Array.isArray(r)) return Array.isArray(r[0]) ? r[0] : r;
  return r ? [r] : [];
}

/* ── DINHEIRO CHEGA COMO TEXTO, E TEXTO NÃO SOMA ──────────────────────────
   O PostgREST devolve `numeric` como STRING — de propósito, para não perder
   precisão no JSON, onde todo número é float. O JavaScript não avisa: ele
   aceita a string e faz outra coisa.

   Dois estragos, um visível e um caro:

     · a tela do salão mostrava "80.00" onde devia mostrar "R$ 80,00", porque
       `(('80.00')||0).toLocaleString(...)` devolve a própria string, sem
       reclamar de nada;

     · e somar concatena. `0 + '80.00' + '45.00'` dá '080.0045.00'. Total de
       comanda, comissão e faturamento do dia saem disso — e um sistema de
       salão que erra a conta do caixa não tem serventia nenhuma.

   Converter aqui, no ponto por onde toda leitura passa, resolve os dois de
   uma vez. A lista sai do schema e o colunas.test.js confere que continua
   completa: coluna numérica nova entra aqui ou reprova lá.
   ──────────────────────────────────────────────────────────────────────── */
const NUMERICAS = new Set([
  'comissao_pct', 'comissao_total', 'comissao_valor', 'custo', 'desconto',
  'estoque', 'preco', 'preco_mes', 'preco_unit', 'qtd', 'sinal_exigido',
  'sinal_pago', 'subtotal', 'taxa', 'total', 'valor', 'valor_previsto',
]);

function paraTela(tabela, linha){
  const mapa = COLUNAS[tabela] || {};
  const inverso = {};
  for(const k of Object.keys(mapa)) inverso[mapa[k]] = k;
  const saida = {};
  for(const k of Object.keys(linha)){
    const v = linha[k];
    // null continua null: zero e "não preenchido" são coisas diferentes, e
    // trocar um pelo outro faria "comissão não definida" virar "comissão 0%".
    saida[inverso[k] || k] =
      (NUMERICAS.has(k) && typeof v === 'string' && v !== '') ? Number(v) : v;
  }
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

/* Erro do PostgREST vem em JSON com `message`, `details` e `hint`. Mostrar
   só "400 Bad Request" faz perder justamente a frase que explica o que
   aconteceu — inclusive as mensagens que os gatilhos do banco escrevem.

   ⚠ E A PARTE DE CONTAS NÃO USA `message`.

   O GoTrue — o serviço de login do Supabase — responde assim:

       { "code": 400, "error_code": "invalid_credentials",
         "msg": "Invalid login credentials" }

   O campo é `msg`. Nós líamos `message`, `error_description` e `error`; os
   três ausentes, sobrava o `status + ' ' + statusText`. E em HTTP/2 não
   existe frase de status: `statusText` vem VAZIO. Então a tela de login
   mostrava, para uma senha errada, literalmente:

       Não consegui entrar: 400

   Um número no lugar de "e-mail ou senha não conferem" é a pessoa sem saber
   se errou a senha, se a conta sumiu ou se o sistema caiu — e sem nada para
   fazer a seguir. A bancada devolvia a forma ANTIGA (`error_description`),
   que nós líamos, então a suíte inteira ficava verde por cima do defeito.

   `codigo` sobe junto com a mensagem porque `error_code` é estável e é a
   mesma palavra em toda versão; traduzir por ele é mais firme do que casar
   o texto em inglês, que muda. Em `code` o PostgREST manda o SQLSTATE
   (texto) e o GoTrue manda o status HTTP (número) — daí o teste de tipo. */
async function conferir(resp){
  if(resp.ok) return resp;

  const cru = await resp.text().catch(() => '');
  let corpo = null;
  try{ corpo = cru ? JSON.parse(cru) : null; }catch(e){ /* não era JSON */ }

  let msg = '';
  if(corpo){
    msg = corpo.msg || corpo.message || corpo.error_description || corpo.error || '';
    if(corpo.hint)               msg += (msg ? ' — ' : '') + corpo.hint;
    if(corpo.details && !msg)    msg  = '(' + corpo.details + ')';
  }else if(cru && cru.length <= 300){
    // Página de erro de proxy, texto solto: feio, mas informa mais que o número.
    msg = cru.trim();
  }
  // Sem frase nenhuma, o mínimo é dizer que o erro é de HTTP, e qual.
  if(!msg) msg = ('HTTP ' + resp.status + ' ' + (resp.statusText || '')).trim();

  const erro = new Error(msg);
  erro.status = resp.status;
  erro.codigo = (corpo && (corpo.error_code ||
    (typeof corpo.code === 'string' ? corpo.code : ''))) || '';
  throw erro;
}

/* ═══════════════════════════════════════════════════════════════════════════
   A SESSÃO PRECISA SER RENOVADA — E NÃO ERA

   O token de acesso do Supabase vale UMA HORA. Junto dele vem um
   `refresh_token`, que existe para trocar o token vencido por um novo sem
   pedir a senha de novo. Nós guardávamos esse refresh desde o primeiro dia e
   NUNCA o usávamos.

   O que isso fazia, uma hora depois do login:

     · toda requisição ao banco voltava 401 (`PGRST301`, "JWT expired");
     · o `baixar()` tratava 401 como "esta pessoa não alcança esta tabela —
       é o RLS funcionando" e devolvia lista vazia;
     · o painel abria inteiro, bonito, e dizia "Nenhum salão nesta conta"
       para quem tem salão, agenda, clientes e caixa lá dentro.

   Nenhum teste pegava porque na bancada o token não vencia nunca. Foi
   preciso fazê-lo vencer lá (e ganhar a porta `/_expirar`) para o defeito
   aparecer em segundos em vez de em uma hora.

   `renovando` guarda a promessa em curso: o painel dispara umas quinze
   requisições na abertura, e sem isso as quinze pediriam renovação ao mesmo
   tempo. O refresh do Supabase é de uso único — a primeira renovação
   funcionaria e as outras quatorze derrubariam a sessão.
   ═══════════════════════════════════════════════════════════════════════════ */
let renovando = null;

function quandoVence(r){
  if(r && r.expires_at) return Number(r.expires_at) * 1000;
  return Date.now() + (Number((r && r.expires_in) || 3600) * 1000);
}

// Um minuto de folga: renovar em cima da hora perde a corrida com a rede.
function perto_de_vencer(){
  return !!(sessao && sessao.expiraEm && Date.now() > sessao.expiraEm - 60000);
}

async function renovarSessao(){
  if(!sessao || !sessao.refresh) return false;
  if(renovando) return renovando;
  renovando = (async () => {
    try{
      const r = await auth('token?grant_type=refresh_token',
                           { refresh_token: sessao.refresh });
      guardarSessao({ token: r.access_token, refresh: r.refresh_token,
        usuarioId: (r.user && r.user.id) || (sessao && sessao.usuarioId) || null,
        expiraEm: quandoVence(r) });
      return true;
    }catch(e){
      /* Refresh recusado é a sessão acabando de verdade — passou do prazo, ou
         a pessoa saiu noutro aparelho. Apagar é o certo: guardada, ela faria
         cada tela seguinte tentar e falhar de novo, calada. */
      console.info('[dados] a sessão terminou: ' + e.message);
      guardarSessao(null);
      return false;
    }finally{ renovando = null; }
  })();
  return renovando;
}

/* Faz a requisição com a sessão viva: renova ANTES se está no fim, e renova
   DEPOIS se o servidor recusou por token vencido. Uma tentativa a mais, só
   uma — repetir sem limite transformaria uma sessão morta em laço infinito. */
async function comSessaoViva(tentar){
  if(sessao && sessao.token && perto_de_vencer()) await renovarSessao();
  let resp = await tentar();
  if(resp.status === 401 && sessao && sessao.refresh){
    if(await renovarSessao()) resp = await tentar();
  }
  return resp;
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
  //
  // E são montados A CADA TENTATIVA: depois de renovar a sessão, o token é
  // outro. Reaproveitar o objeto de cabeçalhos mandaria o token vencido de
  // novo, e a renovação não teria servido para nada.
  const o = Object.assign({}, opcoes || {});
  const extras = o.headers;
  const tentar = () => fetch(cfg.url + '/rest/v1/' + caminho,
    Object.assign({}, o, { headers: cabecalhos(extras) }));

  const resp = await comSessaoViva(tentar);
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
                      usuarioId: r.user && r.user.id, expiraEm: quandoVence(r) });
    }
    return r;
  },

  async entrar({ email, senha }){
    const r = await auth('token?grant_type=password', { email, password: senha });
    guardarSessao({ token: r.access_token, refresh: r.refresh_token,
                    usuarioId: r.user && r.user.id, expiraEm: quandoVence(r) });
    return r;
  },

  /* ── O E-MAIL DE CONFIRMAÇÃO, DE NOVO ───────────────────────────────────
     Quando o projeto exige confirmação, a conta nasce e não entra: o login
     devolve `email_not_confirmed`. Sem um jeito de reenviar, a única saída
     é achar uma mensagem de dias atrás — ou criar outra conta, que esbarra
     em "e-mail já cadastrado". É um beco, e a porta custa quatro linhas.

     `redirect_to` precisa estar nas Redirect URLs do projeto, igual ao de
     recuperar senha. E aqui também não dizemos se o e-mail existe. */
  async reenviarConfirmacao(email){
    const volta = new URL('entrar.html', location.href).href;
    await auth('resend?redirect_to=' + encodeURIComponent(volta),
               { type: 'signup', email, gotrue_meta_security: {} });
    return { redirect: volta };
  },

  /* A sessão que chega pelo #fragmento de um link de e-mail (confirmação de
     cadastro). Guardar é tudo o que falta: quem criou o token foi o próprio
     Supabase, ao validar o link — ele JÁ é uma sessão. */
  entrarComToken({ token, refresh, usuarioId }){
    guardarSessao({ token, refresh: refresh || null, usuarioId: usuarioId || null });
  },

  // Código no WhatsApp: quem gera, valida e expira é o Supabase Auth. A
  // entrega passa pelo Send SMS Hook, que chama a Edge Function. Nada disso
  // acontece aqui — é justamente o ponto: o navegador nunca vê o código.
  /* ── ESQUECI MINHA SENHA ────────────────────────────────────────────
     O Supabase manda o e-mail; nós só pedimos. O `redirect_to` é para onde
     o link do e-mail devolve a pessoa, e ele PRECISA estar na lista de
     "Redirect URLs" do projeto — fora dela o Supabase manda para a home e a
     pessoa clica no link, chega no lugar certo sem o token, e conclui que o
     sistema está quebrado.

     Nunca dizemos se o e-mail existe. Uma tela que responde "não achamos
     esse e-mail" é um verificador de contas de graça para quem quiser saber
     quem usa o sistema — e este é o mesmo motivo de o Supabase também
     responder 200 para endereço que não existe. */
  /* ⚠ `redirect_to` vai na QUERY, não no corpo. Estava sendo calculado e
     NÃO ENVIADO — o comentário acima dizia para onde o link devolvia a
     pessoa, e o Supabase nunca ficou sabendo. Sem ele o link do e-mail cai
     no "Site URL" do projeto: a raiz do site, ou `localhost:3000` num
     projeto recém-criado. Ou seja, a pessoa clica no link, chega numa
     página que não tem nada a ver, e "esqueci minha senha" simplesmente não
     funciona — sem erro nenhum, que é o pior jeito de não funcionar. */
  async pedirNovaSenha(email){
    const volta = new URL('nova-senha.html', location.href).href;
    await auth('recover?redirect_to=' + encodeURIComponent(volta),
               { email, gotrue_meta_security: {} });
    return { redirect: volta };
  },

  /* Troca a senha de quem chegou pelo link do e-mail. O token de recuperação
     vem no #fragmento da URL e já É uma sessão — por isso `guardarSessao()`
     antes: sem Authorization, o PUT em /user é recusado. */
  async trocarSenha({ token, refresh, senha }){
    if(token) guardarSessao({ token, refresh: refresh || null, usuarioId: null });
    const r = await auth('user', { password: senha }, 'PUT');
    if(r && r.id) guardarSessao({ token, refresh: refresh || null, usuarioId: r.id });
    return r;
  },

  async pedirCodigo(telefone){
    return auth('otp', { phone: telefone, create_user: true });
  },

  async conferirCodigo(telefone, codigo){
    const r = await auth('verify', { type: 'sms', phone: telefone, token: codigo });
    guardarSessao({ token: r.access_token, refresh: r.refresh_token,
                    usuarioId: r.user && r.user.id, expiraEm: quandoVence(r) });
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

  /* ── FUNÇÃO DE BORDA ──────────────────────────────────────────────────────
     `chamar()` fala com o PostgREST: função dentro do banco, que só enxerga o
     banco. Isto aqui fala com uma função de borda (Deno), que roda num
     servidor e é o único lugar do sistema que enxerga credencial de terceiro
     — o token do Mercado Pago, o do WhatsApp.

     É por isso que existe como caminho separado, e não como mais uma linha do
     `chamar()`: o que passa por aqui sai do banco. E é por isso que manda o
     token da SESSÃO no `Authorization` — a borda não confia no que o corpo
     diz sobre quem está pedindo; ela verifica o token contra o próprio
     Supabase e usa o uuid que voltar de lá.

     O erro vem de `{ erro }`, e é ele que chega na tela. A borda nunca
     devolve a mensagem crua do Mercado Pago: ela ecoa parte do pedido, e o
     pedido carrega e-mail de quem está pagando.
     ─────────────────────────────────────────────────────────────────────── */
  async borda(nome, corpo){
    if(!LIGADO) throw new Error('Sem servidor configurado.');
    if(!sessao || !sessao.token) throw new Error('Faça login de novo.');
    const base = (window.AGENDAPRO.url || '').replace(/\/+$/, '');
    let r;
    try{
      r = await fetch(base + '/functions/v1/' + nome, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: window.AGENDAPRO.chave,
          Authorization: 'Bearer ' + sessao.token,
        },
        body: JSON.stringify(corpo || {}),
      });
    }catch(e){
      // Rede caiu, ou a função nem existe ainda. As duas coisas são "tente de
      // novo", e nenhuma delas é culpa de quem clicou.
      throw new Error('Não consegui falar com o servidor. Tente de novo.');
    }
    const dados = await r.json().catch(() => ({}));
    if(!r.ok) throw new Error(dados.erro || ('Falhou (' + r.status + ')'));
    return dados;
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

  /* ── O QUE É DELA ─────────────────────────────────────────────────────
     Marcar devolve um SEGREDO daquela marcação, e é ele que abre "meus
     horários", cancelar e a lista de espera. Quem tem o segredo é quem
     marcou — ninguém mais o viu passar.

     Os segredos ficam no navegador, e por isso a lista é por APARELHO. É uma
     limitação honesta: quem marcou no computador do trabalho precisa do link
     para cancelar do celular. No dia em que houver SMS, ela cai. */
  /* ── UMA ARMADILHA DO POSTGREST ────────────────────────────────────────
     Função que devolve escalar vem CRUA, sem linha em volta. Estas devolvem
     um array jsonb, então a resposta JÁ É a lista.

     A primeira versão fazia `Array.isArray(r) ? r[0] : r`, copiado do
     `vitrine()` — que devolve um OBJETO e por isso precisa desembrulhar.
     Aqui isso pegava a primeira marcação e chamava de lista: a tela dizia
     "nenhum horário" para quem tinha acabado de marcar. O mesmo padrão, o
     resultado oposto, porque o tipo por dentro é outro. */
  async meusAgendamentos(tokens){
    return listaJsonb(await rest('rpc/meus_agendamentos', {
      method: 'POST', body: JSON.stringify({ p_tokens: tokens || [] }) }));
  },
  async cancelarAgendamento(token){
    return rest('rpc/cancelar_agendamento', {
      method: 'POST', body: JSON.stringify({ p_token: token }) });
  },
  async entrarNaFila(dados){
    // Esta devolve um OBJETO jsonb, e aí sim o desembrulho faz sentido.
    const r = await rest('rpc/entrar_na_fila', {
      method: 'POST', body: JSON.stringify(dados) });
    return (Array.isArray(r) ? r[0] : r) || {};
  },
  async minhaFila(tokens){
    return listaJsonb(await rest('rpc/minha_fila', {
      method: 'POST', body: JSON.stringify({ p_tokens: tokens || [] }) }));
  },
  async sairDaFila(token){
    return rest('rpc/sair_da_fila', {
      method: 'POST', body: JSON.stringify({ p_token: token }) });
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
  async pedirNovaSenha(){ throw new Error('Recuperação de senha só existe no modo nuvem.'); },
  async trocarSenha(){ throw new Error('Recuperação de senha só existe no modo nuvem.'); },
  async reenviarConfirmacao(){ throw new Error('Confirmação de e-mail só existe no modo nuvem.'); },
  entrarComToken(){ /* na demonstração não há token nem sessão */ },
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
  async borda(nome, corpo){
    // Sem servidor não há Mercado Pago. A tela trata isto e explica.
    throw new Error('Na demonstração não há cobrança de verdade.');
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
  'bloqueios','clientes','agendamentos',
  // Logo depois do pai, e não em qualquer lugar: a chave estrangeira exige
  // que o agendamento exista antes das linhas de serviço dele.
  'agendamento_servicos',
  'lista_espera','produtos',
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

/* ── UMA TABELA, SEM DERRUBAR AS OUTRAS ───────────────────────────────────
   Tabela que esta pessoa não alcança não é erro: é o RLS funcionando, e
   seguir com lista vazia é o certo. Mas "não alcança" e "a pergunta estava
   malfeita" chegavam com a mesma cara, e foi assim que quatro 400 passaram
   anos parecendo permissão. Agora o segundo caso grita — porque é defeito
   nosso, e some se ninguém olhar. `falhas` é preenchido por referência para
   sobreviver ao `Promise.all` de baixo. */
async function buscarTabela(t, filtro, falhas){
  try{
    return await Dados.lista(t, filtro);
  }catch(e){
    const cru = String(e.message || '');
    if(/does not exist|malformed|invalid input|400/i.test(cru)){
      console.error('[dados] pergunta malfeita para "' + t + '" — isto é '
        + 'defeito do código, não permissão: ' + cru);
      // E agora sobe até a tela. Este ramo é defeito NOSSO, e ele passou anos
      // parecendo permissão justamente por morrer no console — que ninguém
      // abre no celular, que é onde o salão trabalha.
      falhas.push({ tabela: t, motivo: cru });
    } else {
      console.info('[dados] sem acesso a "' + t + '": ' + cru);
    }
    return [];
  }
}

/* ═══════════════════════════════════════════════════════════════════════════
   TABELA POR TABELA, UMA ATRÁS DA OUTRA — E ERA ESSE O BLANK

   Até quinze requisições, cada uma esperando a anterior terminar para só
   então começar. Numa rede de celular, com uns 150ms de ida e volta cada
   uma, a soma vira dois ou três segundos de tela em branco antes do
   primeiro pixel da agenda: exatamente o "demora, fica em branco e depois
   carrega".

   `perfis` e `vinculos` continuam vindo primeiro, sozinhos: é deles que sai
   quem é a pessoa e a QUAIS salões ela pertence — e só sabendo isso dá para
   decidir, com segurança, o filtro das outras treze. Essas treze, pedidas
   juntas, levam o tempo da mais lenta, não a soma de todas.

   Isto é seguro em paralelo por causa do trabalho já feito na renovação de
   sessão: `comSessaoViva()` deduplica a renovação (`renovando`), então
   quinze requisições simultâneas nunca disparam quinze renovações — no
   máximo uma, e as outras catorze esperam ela. ═══════════════════════════════════════════════════════════════════════════ */
async function baixar(salaoId){
  // Sem sessão não há o que buscar: cada tabela responderia 400 e o console
  // encheria de erro para dizer "você não está logado", que a tela já sabe.
  const vazio = () => {
    const v = {};
    for(const t of TABELAS_SO_LEITURA.concat(TABELAS_SINCRONIZADAS)) v[t] = [];
    return v;
  };
  if(LIGADO && !(sessao && sessao.token)){
    const v = vazio(); v.semSessao = true;
    return v;
  }

  const falhas = [];
  const [perfis, vinculos] = await Promise.all([
    buscarTabela('perfis', {}, falhas),
    buscarTabela('vinculos', {}, falhas),
  ]);

  // Pode ter morrido durante essas duas: a renovação foi tentada e o refresh
  // também foi recusado. Sem esta saída, as treze requisições da fase
  // seguinte sairiam todas sem token — e falhariam todas.
  if(LIGADO && !(sessao && sessao.token)){
    const v = vazio(); v.semSessao = true; v.sessaoExpirou = true;
    return v;
  }

  /* ── A CONTA DA PLATAFORMA NÃO BAIXA O SALÃO DOS OUTROS ──────────────────
     `is_super()` está em toda policy de leitura: quem administra o AgendaPro
     enxerga, pelo banco, TODO salão. É de propósito — sem isso não há como
     dar suporte nem cobrar. Mas sem filtro nenhum, a primeira leitura do
     painel arrastava para dentro do navegador dele a lista de clientes de
     todos os salões, com telefone e observação, de uma vez só. Medido numa
     base de teste: 27 salões e 15 clientes que não são dele.

     Isso não é acesso a mais — o acesso ele tem de qualquer jeito. É
     exposição à toa: dado que ninguém pediu, num aparelho, para uma tela que
     nem vai mostrá-lo (o `sohMeusSaloes()` do app.html descarta tudo logo em
     seguida, e o painel dele é o admin.html, que passa por RPC).

     Então, depois de saber quem é a pessoa, as tabelas de salão só descem
     para os salões a que ela está de fato vinculada. Se não há nenhum — o
     caso da conta de plataforma pura — não desce nada. */
  const eu = sessao && sessao.usuarioId;
  const souDaPlataforma = perfis.some(p => p.id === eu && p.superAdmin);
  const sohDe = souDaPlataforma
    ? vinculos.filter(v => v.perfilId === eu && v.status === 'ativo').map(v => v.salaoId)
    : [];   // dono comum: o RLS já entrega só o que é dele

  if(souDaPlataforma && !sohDe.length){
    const bd = { perfis, vinculos };
    for(const t of TABELAS_SO_LEITURA.concat(TABELAS_SINCRONIZADAS)){
      if(t !== 'perfis' && t !== 'vinculos') bd[t] = [];
    }
    bd.contaDaPlataforma = true;
    return bd;
  }

  /* ── QUEM PODE SER FILTRADA POR SALÃO ────────────────────────────────────
     Aqui havia uma lista escrita à mão — `['saloes','planos','perfis',
     'vinculos']` — com as tabelas que não têm `salao_id`. A lista estava
     incompleta, e faltavam quatro: `jornadas`, `servicos_profissionais`,
     `comanda_itens` e `pagamentos`.

     Nessas quatro o filtro saía como `salaoId=eq.…`, o PostgREST punha em
     minúsculas, procurava a coluna `salaoid`, não achava e devolvia 400. O
     `catch` engolia o 400 e devolvia lista vazia — então o painel na nuvem
     abria sem jornada de trabalho, sem o vínculo serviço↔profissional, e
     com o Caixa zerado. Nenhum teste pegou porque todos abrem o painel em
     `?demo=1`, e no navegador o campo se chama `salaoId` mesmo.

     Lista escrita à mão envelhece calada. O mapa COLUNAS já sabe quem tem
     `salao_id` — e é conferido contra o schema de verdade pelo
     colunas.test.js. Perguntando a ele, tabela nova entra certa sozinha.

     `vinculos` já foi buscada acima, sem filtro de propósito: é por ela que
     se descobre a QUAIS salões a pessoa pertence — filtrar pelo salão atual
     esconderia os outros dela. */
  const alvo = salaoId || (sohDe.length ? sohDe[0] : null);
  const resto = TABELAS_SO_LEITURA.concat(TABELAS_SINCRONIZADAS)
    .filter(t => t !== 'perfis' && t !== 'vinculos');

  const respostas = await Promise.all(resto.map(t => {
    const temSalao = !!(COLUNAS[t] && COLUNAS[t].salaoId);
    const filtro = (alvo && temSalao) ? { salaoId: alvo } : {};
    return buscarTabela(t, filtro, falhas);
  }));

  // A sessão também pode ter morrido DURANTE a fase paralela — mesma saída,
  // com o que já veio de `perfis`/`vinculos` descartado: é tudo ou nada, para
  // a tela nunca misturar um retrato pela metade com um "sua sessão venceu".
  if(LIGADO && !(sessao && sessao.token)){
    const v = vazio(); v.semSessao = true; v.sessaoExpirou = true;
    return v;
  }

  const bd = { perfis, vinculos };
  resto.forEach((t, i) => { bd[t] = respostas[i]; });
  if(falhas.length) bd.falhas = falhas;
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

  // Pelo `comSessaoViva()` como todo o resto: enviar a foto é justamente o
  // tipo de coisa que se faz depois de uma hora de painel aberto, e um 401
  // aqui apagaria a logo do salão sem explicar por quê.
  const resp = await comSessaoViva(() =>
    fetch(cfg.url + '/storage/v1/object/salao/' + caminho, {
      method: 'POST',
      headers: {
        'apikey': cfg.chave,
        'Authorization': 'Bearer ' + ((sessao && sessao.token) || cfg.chave),
        'Content-Type': blob.type || 'image/jpeg',
        'x-upsert': 'true',
      },
      body: blob,
    }));
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
  const resp = await comSessaoViva(() =>
    fetch(cfg.url + '/storage/v1/object/salao/' + caminho, {
      method: 'DELETE',
      headers: {
        'apikey': cfg.chave,
        'Authorization': 'Bearer ' + ((sessao && sessao.token) || cfg.chave),
      },
    }));
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
Dados.NUMERICAS   = NUMERICAS;       // idem

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
