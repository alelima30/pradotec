/* PostgREST caseiro — só o pedaço que o AgendaPro usa.
   Serve para provar que dados.js fala com um Postgres REAL, com o schema
   real e o RLS real, sem precisar de um projeto Supabase no ar.
   Não é para produção: é bancada de teste. */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';

const RAIZ = new URL('../..', import.meta.url).pathname;
/* ── DATA É TEXTO, COMO O POSTGREST DE VERDADE DEVOLVE ────────────────────
   O driver `pg` converte uma coluna `date` em objeto Date do JavaScript, e
   `JSON.stringify` transforma isso em "2026-08-28T00:00:00.000Z". O PostgREST
   do Supabase devolve "2026-08-28", e ponto.

   A diferença não é acadêmica: a tela do plano faz
   `trialAte.split('-')` para contar quantos dias faltam no teste grátis. Com
   o formato do PostgREST, dá 28. Com o formato do driver, o terceiro pedaço
   vira "28T00:00:00.000Z", o Number disso é NaN, e a tela mostra "faltam NaN
   dia(s)".

   Passei um tempo atrás desse defeito no produto. Ele não existe no produto:
   existia AQUI. Bancada que mente é pior que bancada que falta — ela inventa
   defeito e, do outro lado da moeda, esconde os de verdade.

   1082 é o `date`, que sai cru: "2026-08-28", igual ao PostgREST.
   1114 e 1184 são os timestamps. Esses o Postgres devolve com espaço no meio
   ("2026-08-21 09:41:40+00") e o PostgREST devolve em ISO, com o T. Deixar o
   formato do Postgres aqui seria trocar uma infidelidade por outra.
   ──────────────────────────────────────────────────────────────────────── */
pg.types.setTypeParser(1082, v => v);
for(const oid of [1114, 1184]){
  pg.types.setTypeParser(oid, v => (v == null ? v : new Date(v).toISOString()));
}

/* Aqui na máquina de desenvolvimento o Postgres atende num socket em /tmp,
   na porta 5444. No CI ele é um serviço em localhost:5432, com senha. Ler do
   ambiente é o que deixa o mesmo arquivo servir aos dois — e as variáveis são
   as mesmas que o `psql` já entende, então quem roda não aprende nada novo. */
const pool = new pg.Pool({
  host:     process.env.PGHOST     || '/tmp',
  port:     Number(process.env.PGPORT || 5444),
  user:     process.env.PGUSER     || 'postgres',
  password: process.env.PGPASSWORD || undefined,
  database: process.env.PGDATABASE || 'app',
});

const TIPOS = { '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  // .svg entrou quando o logotipo apareceu quebrado no painel da plataforma:
  // sem o tipo certo, o navegador recebe o arquivo e não sabe desenhá-lo.
  '.svg':'image/svg+xml',
  '.css':'text/css', '.png':'image/png', '.webmanifest':'application/manifest+json' };

// token → id do usuário. O Supabase usa JWT assinado; aqui basta o mapa,
// porque quem confere de verdade é o RLS a partir de request.jwt.claim.sub.
const sessoes = new Map();

// e-mail → token de recuperação. Só a bancada tem isto: o Supabase manda por
// e-mail, e aqui não há caixa postal. O teste pesca em /_recuperacao.
const recuperacoes = new Map();

// As imagens enviadas, em memória. O processo é descartável; ninguém precisa
// delas depois que o teste termina.
const arquivos = new Map();
let seq = 0;

const json = (res, code, corpo) => {
  res.writeHead(code, {'Content-Type':'application/json',
    'Access-Control-Allow-Origin':'*',
    'Access-Control-Allow-Headers':'*','Access-Control-Allow-Methods':'*'});
  res.end(JSON.stringify(corpo));
};

/* ── O ERRO DE LOGIN TEM UM FORMATO, E É ESTE ─────────────────────────────
   A bancada respondia `{ error_description: '...' }`, que é a forma ANTIGA
   do GoTrue. O `conferir()` do dados.js lia esse campo, então a suíte inteira
   ficava verde — enquanto o Supabase de verdade respondia

       { "code": 400, "error_code": "invalid_credentials",
         "msg": "Invalid login credentials" }

   com a frase em `msg`, que ninguém lia. Em produção, senha errada virava
   "Não consegui entrar: 400" na cara da pessoa (o `statusText` vem vazio em
   HTTP/2, então nem "Bad Request" sobrava).

   A bancada ser mais fácil que a produção é o erro que mais custou nesta
   base. Aqui ela passa a responder exatamente como o serviço real. */
const erroAuth = (res, codigo, frase, status) =>
  json(res, status || 400, { code: status || 400, error_code: codigo, msg: frase });

function usuarioDo(req){
  const a = (req.headers.authorization || '').replace('Bearer ', '');
  return sessoes.get(a) || null;
}

/* ── A bancada precisa ser tão ESTRITA quanto o Supabase ───────────────────
   O Supabase trocou o formato da chave pública: `sb_publishable_...`, que não
   é JWT. Mandada no `Authorization`, a plataforma tenta lê-la como token e
   recusa a requisição.

   Uma bancada mais permissiva que o real é pior que bancada nenhuma: ela
   aprova código que quebra em produção. Foi assim que as 20 tabelas passaram
   abertas por toda a suíte. Então aqui a mesma coisa é recusada: chave do
   projeto vai no `apikey`, e o `Authorization` só carrega token de gente.

   Devolve o erro em `message` porque é de lá que o `conferir()` do dados.js
   tira a frase — assim a falha chega legível na tela em vez de "401". */
function chaveNoLugarErrado(req){
  const auth = (req.headers.authorization || '').replace('Bearer ', '');
  if(!auth) return null;
  if(auth === (req.headers.apikey || '')) {
    return 'A chave do projeto foi enviada no cabecalho Authorization. '
         + 'Ela vai apenas no apikey; o Authorization carrega o token de '
         + 'quem fez login.';
  }
  return null;
}

async function comPapel(req, fn){
  const erro = chaveNoLugarErrado(req);
  if(erro){ const e = new Error(erro); e.status = 401; throw e; }
  const cli = await pool.connect();
  try{
    await cli.query('begin');
    const uid = usuarioDo(req);
    if(uid){
      await cli.query("set local role authenticated");
      await cli.query("select set_config('request.jwt.claim.sub', $1, true)", [uid]);
    } else {
      await cli.query("set local role anon");
    }
    const r = await fn(cli);
    await cli.query('commit');
    return r;
  }catch(e){ await cli.query('rollback').catch(()=>{}); throw e; }
  finally{ cli.release(); }
}

function corpoDe(req){
  return new Promise(r => { let s=''; req.on('data',c=>s+=c); req.on('end',()=>{
    try{ r(s ? JSON.parse(s) : null); }catch(e){ r(null); } }); });
}

const http_ = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  if(req.method === 'OPTIONS') return json(res, 200, {});

  try{
    // ── AUTH ──
    if(u.pathname.startsWith('/auth/v1/')){
      const acao = u.pathname.replace('/auth/v1/','').split('?')[0];
      const b = await corpoDe(req) || {};

      if(acao === 'signup'){
        /* ── SÓ auth.users, COMO O SUPABASE DE VERDADE ──────────────────────
           Esta parte já inseria em `public.perfis` também, imitando um
           gatilho que não existia no schema. O resultado: a suíte inteira
           verde e o cadastro quebrado em produção — quem se cadastrasse no
           Supabase levaria "Complete seu cadastro antes de criar o salão"
           com a conta metade criada e o e-mail preso.

           Agora a bancada faz o que o Supabase faz: cria a conta com os
           metadados e para. Quem cria o perfil é o gatilho do 08_conta.sql.
           Se ele sumir, os testes caem — que é o ponto. */
        /* E-mail repetido tem nome próprio no Supabase — `user_already_exists`
           — e é a recusa mais comum do cadastro: quem já tentou uma vez volta
           e tenta de novo. Sem isto a bancada criava DUAS contas com o mesmo
           endereço, um estado que a produção não permite, e a tela que traduz
           essa recusa não teria como ser testada. */
        const jaTem = await pool.query(
          'select 1 from auth.users where lower(email) = lower($1)', [b.email || '']);
        if(jaTem.rowCount){
          return erroAuth(res, 'user_already_exists',
            'User already registered', 422);
        }
        const id = await pool.query(
          `insert into auth.users (id, email, raw_user_meta_data, encrypted_password)
                values (gen_random_uuid(), $1, $2::jsonb, $3) returning id`,
          [b.email, JSON.stringify(b.data || {}), b.password || null])
          .then(r => r.rows[0].id);
        const tok = 't' + (++seq); sessoes.set(tok, id);
        return json(res, 200, { access_token: tok, refresh_token: 'r'+seq, user: { id } });
      }

      if(acao === 'otp'){
        // O Supabase manda o código; aqui fixamos 123456 para o teste.
        return json(res, 200, { message_id: 'demo' });
      }

      if(acao === 'verify'){
        if(b.token !== '123456')
          return erroAuth(res, 'otp_expired', 'Token has expired or is invalid');
        let id = await pool.query(
          "select id from public.perfis where telefone = $1", [b.phone])
          .then(r => r.rows[0] && r.rows[0].id);
        if(!id){
          // Como no signup: aqui só nasce a conta, com o telefone nos
          // metadados. Quem cria o perfil é o gatilho do 08_conta.sql — no
          // Supabase de verdade é ele, e a bancada não pode ser mais
          // prestativa que a produção.
          id = await pool.query(
            `insert into auth.users (id, phone, raw_user_meta_data)
                  values (gen_random_uuid(), $1, $2::jsonb) returning id`,
            [b.phone, JSON.stringify({ nome: 'Cliente', telefone: b.phone })])
            .then(r => r.rows[0].id);
        }
        const tok = 't' + (++seq); sessoes.set(tok, id);
        return json(res, 200, { access_token: tok, refresh_token: 'r'+seq, user: { id } });
      }

      if(acao.startsWith('token')){
        /* A senha é CONFERIDA aqui. Antes não era, e isso fazia um teste
           dizer "entra com a senha nova" passando também com a senha errada
           — a asserção parecia forte e não valia nada. Trocar de senha só é
           uma funcionalidade se a velha parar de funcionar. */
        const { rows } = await pool.query(
          `select id, encrypted_password, email_confirmed_at
             from auth.users where lower(email)=lower($1)`, [b.email || '']);
        const u = rows[0];
        if(!u || (u.encrypted_password != null && u.encrypted_password !== b.password)){
          return erroAuth(res, 'invalid_credentials', 'Invalid login credentials');
        }
        if(u.email_confirmed_at == null){
          return erroAuth(res, 'email_not_confirmed', 'Email not confirmed');
        }
        const id = u.id;
        const tok = 't' + (++seq); sessoes.set(tok, id);
        return json(res, 200, { access_token: tok, refresh_token: 'r'+seq, user: { id } });
      }

      /* Reenviar a confirmação. Como o `recover`, responde 200 sempre — dizer
         "esse e-mail não existe" transformaria a tela num verificador de
         contas. Aqui não há caixa postal; o que importa testar é que a tela
         pede, recebe 200 e conta isso para quem está esperando. */
      if(acao === 'resend'){
        return json(res, 200, {});
      }

      if(acao === 'logout'){
        const a = (req.headers.authorization||'').replace('Bearer ','');
        sessoes.delete(a); return json(res, 204, {});
      }

      /* ── ESQUECI MINHA SENHA ─────────────────────────────────────────
         O Supabase responde 200 mesmo para e-mail que não existe, e isso
         não é descuido: uma resposta diferente transformaria a tela num
         verificador de contas para quem quiser saber quem usa o sistema.
         A bancada faz igual — se ela distinguisse, um teste poderia passar
         aqui e vazar lá.

         O e-mail de verdade não é enviado (não há caixa postal nenhuma
         aqui). Em vez disso o token fica guardado, e o teste o pesca por
         `GET /_recuperacao?email=...` — que existe SÓ na bancada. */
      if(acao === 'recover'){
        const { rows } = await pool.query(
          'select id from auth.users where lower(email) = lower($1)', [b.email || '']);
        if(rows[0]){
          const tok = 'rec' + (++seq);
          sessoes.set(tok, rows[0].id);
          recuperacoes.set(String(b.email).toLowerCase(), tok);
        }
        return json(res, 200, {});
      }

      if(acao === 'user' && (req.method === 'PUT' || req.method === 'PATCH')){
        const id = usuarioDo(req);
        if(!id) return erroAuth(res, 'no_authorization', 'não autenticado', 401);
        if(b.password){
          await pool.query(
            'update auth.users set encrypted_password = $2 where id = $1',
            [id, b.password]);
        }
        const { rows } = await pool.query(
          'select id, email from auth.users where id = $1', [id]);
        return json(res, 200, rows[0] || { id });
      }

      return erroAuth(res, 'not_found', 'auth: ' + acao, 404);
    }

    /* Outra porta só da bancada: apaga o carimbo de confirmação de uma conta,
       deixando-a no estado em que o Supabase deixa quem acabou de se
       cadastrar num projeto com "Confirm email" ligado. É o segundo motivo
       de 400 no login, e sem poder produzi-lo aqui a tela que o trata — com
       o botão de reenviar — não teria teste nenhum. */
    if(u.pathname === '/_naoconfirmado'){
      const b = await corpoDe(req) || {};
      await pool.query(
        'update auth.users set email_confirmed_at = null where lower(email) = lower($1)',
        [b.email || '']);
      return json(res, 200, {});
    }

    /* Só a bancada tem esta porta: devolve o token que o Supabase mandaria
       por e-mail. Sem ela, o caminho de recuperar senha ficaria sem teste —
       e é justamente o caminho que a pessoa usa quando já está com pressa. */
    if(u.pathname === '/_recuperacao'){
      const tok = recuperacoes.get(String(u.searchParams.get('email') || '').toLowerCase());
      return json(res, tok ? 200 : 404, tok ? { access_token: tok } : {});
    }

    /* ── STORAGE ────────────────────────────────────────────────────────
       O Supabase guarda imagem noutro serviço, com outro caminho e corpo
       binário. Sem um arremedo dele aqui, TODA foto — logo, capa, serviço,
       profissional — ficava fora de teste no modo nuvem: a bancada respondia
       404 e o teste só sabia dizer "não consegui enviar".

       É o mesmo buraco que já custou caro três vezes nesta semana: o modo em
       que o defeito mora ser justamente o que os testes não visitam.

       Guarda na memória, não em disco: o processo é descartável e ninguém
       precisa da foto depois que o teste termina.

       O caminho `<salao_id>/<arquivo>` é a convenção de que a policy do balde
       depende. Aqui não há policy — mas o teste que confere se um salão
       alcança a pasta do outro é de banco, em 04_imagens.sql, não daqui. */
    if(u.pathname.startsWith('/storage/v1/object/')){
      const chave = decodeURIComponent(
        u.pathname.replace('/storage/v1/object/', '')
                  .replace(/^public\//, ''));

      if(req.method === 'POST' || req.method === 'PUT'){
        const pedacos = [];
        for await (const p of req) pedacos.push(p);
        arquivos.set(chave, { tipo: req.headers['content-type'] || 'image/jpeg',
                              dados: Buffer.concat(pedacos) });
        return json(res, 200, { Key: chave });
      }
      if(req.method === 'GET'){
        const a = arquivos.get(chave);
        if(!a) return json(res, 404, { message: 'nao achei ' + chave });
        res.writeHead(200, { 'Content-Type': a.tipo,
                             'Access-Control-Allow-Origin': '*' });
        return res.end(a.dados);
      }
      if(req.method === 'DELETE'){
        arquivos.delete(chave);
        return json(res, 200, {});
      }
    }

    // ── REST ──
    if(u.pathname.startsWith('/rest/v1/')){
      const alvo = u.pathname.replace('/rest/v1/','');

      if(alvo.startsWith('rpc/')){
        const fn = alvo.slice(4);
        const b = await corpoDe(req) || {};
        const nomes = Object.keys(b);
        const args = nomes.map((n,i) => `${n} => $${i+1}`).join(', ');
        const r = await comPapel(req, cli =>
          cli.query(`select * from public.${fn}(${args})`, nomes.map(n => b[n])));

        /* ── DESEMBRULHAR O ESCALAR ─────────────────────────────────────────
           O PostgREST devolve o VALOR quando a função retorna um escalar:
           `vitrine()` devolve o jsonb cru, `slug_disponivel()` devolve `true`.
           A bancada devolvia a linha inteira — [{"vitrine":{...}}] — e o
           dados.js, que procurava `.salao` ali dentro, achava undefined e
           concluía que o salão não existia.

           Bancada que responde diferente do real é bancada que aprova código
           quebrado, ou reprova código certo. Aqui foi a segunda: o defeito
           era da bancada, e ela acusou a tela. */
        const escalar = r.rows.length === 1
          && r.fields.length === 1
          && r.fields[0].name === fn;
        return json(res, 200, escalar ? r.rows[0][fn] : r.rows);
      }

      const tabela = alvo;
      const filtros = [], valores = [];
      let ordem = null, limite = null;
      for(const [k,v] of u.searchParams){
        if(k === 'select') continue;
        if(k === 'order'){ ordem = v.split('.')[0]; continue; }
        if(k === 'limit'){ limite = parseInt(v,10); continue; }
        if(v.startsWith('eq.')){
          valores.push(v.slice(3));
          filtros.push(`${k} = $${valores.length}`);
        }
      }
      const onde = filtros.length ? ' where ' + filtros.join(' and ') : '';

      if(req.method === 'GET'){
        const sql = `select * from public.${tabela}${onde}`
          + (ordem ? ` order by ${ordem}` : '') + (limite ? ` limit ${limite}` : '');
        const r = await comPapel(req, cli => cli.query(sql, valores));
        return json(res, 200, r.rows);
      }

      if(req.method === 'POST'){
        const b = await corpoDe(req) || {};
        const cols = Object.keys(b);
        const sql = `insert into public.${tabela} (${cols.join(',')})
                     values (${cols.map((_,i)=>'$'+(i+1)).join(',')}) returning *`;
        const r = await comPapel(req, cli => cli.query(sql, cols.map(c => b[c])));
        return json(res, 201, r.rows);
      }

      if(req.method === 'PATCH'){
        const b = await corpoDe(req) || {};
        const cols = Object.keys(b);
        const sets = cols.map((c,i) => `${c} = $${valores.length + i + 1}`).join(', ');
        const sql = `update public.${tabela} set ${sets}${onde} returning *`;
        const r = await comPapel(req, cli =>
          cli.query(sql, [...valores, ...cols.map(c => b[c])]));
        return json(res, 200, r.rows);
      }

      if(req.method === 'DELETE'){
        await comPapel(req, cli =>
          cli.query(`delete from public.${tabela}${onde}`, valores));
        return json(res, 204, {});
      }
    }

    // A bancada serve um config.js próprio, apontando para ela mesma. Assim
    // o config.js do repositório continua vazio (modo demonstração) e o
    // teste em nuvem não depende de ninguém editar arquivo.
    if(u.pathname === '/config.js'){
      res.writeHead(200, {'Content-Type':'text/javascript; charset=utf-8'});
      return res.end(`window.AGENDAPRO = { url:'http://127.0.0.1:8123',
        chave:'chave-de-bancada', ambiente:'bancada' };`);
    }

    // ── Arquivos ──
    let p = u.pathname === '/' ? '/app.html' : u.pathname;
    const arq = path.join(RAIZ, p);
    if(fs.existsSync(arq) && fs.statSync(arq).isFile()){
      res.writeHead(200, {'Content-Type': TIPOS[path.extname(arq)] || 'application/octet-stream'});
      return res.end(fs.readFileSync(arq));
    }
    res.writeHead(404); res.end('nao achei ' + p);

  }catch(e){
    console.error('[erro]', req.method, req.url, '→', e.message);
    return json(res, 400, { message: e.message, code: e.code, hint: e.hint,
                            details: e.detail });
  }
});

http_.listen(8123, '127.0.0.1', () => console.log('bancada em http://127.0.0.1:8123'));
