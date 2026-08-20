/* PostgREST caseiro — só o pedaço que o AgendaPro usa.
   Serve para provar que dados.js fala com um Postgres REAL, com o schema
   real e o RLS real, sem precisar de um projeto Supabase no ar.
   Não é para produção: é bancada de teste. */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';

const RAIZ = new URL('../..', import.meta.url).pathname;
const pool = new pg.Pool({ host:'/tmp', port:5444, user:'postgres', database:'app' });

const TIPOS = { '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  // .svg entrou quando o logotipo apareceu quebrado no painel da plataforma:
  // sem o tipo certo, o navegador recebe o arquivo e não sabe desenhá-lo.
  '.svg':'image/svg+xml',
  '.css':'text/css', '.png':'image/png', '.webmanifest':'application/manifest+json' };

// token → id do usuário. O Supabase usa JWT assinado; aqui basta o mapa,
// porque quem confere de verdade é o RLS a partir de request.jwt.claim.sub.
const sessoes = new Map();
let seq = 0;

const json = (res, code, corpo) => {
  res.writeHead(code, {'Content-Type':'application/json',
    'Access-Control-Allow-Origin':'*',
    'Access-Control-Allow-Headers':'*','Access-Control-Allow-Methods':'*'});
  res.end(JSON.stringify(corpo));
};

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
        const id = await pool.query(
          `insert into auth.users (id, email, raw_user_meta_data)
                values (gen_random_uuid(), $1, $2::jsonb) returning id`,
          [b.email, JSON.stringify(b.data || {})]).then(r => r.rows[0].id);
        const tok = 't' + (++seq); sessoes.set(tok, id);
        return json(res, 200, { access_token: tok, refresh_token: 'r'+seq, user: { id } });
      }

      if(acao === 'otp'){
        // O Supabase manda o código; aqui fixamos 123456 para o teste.
        return json(res, 200, { message_id: 'demo' });
      }

      if(acao === 'verify'){
        if(b.token !== '123456') return json(res, 400, { message: 'Token has expired or is invalid' });
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
        const id = await pool.query("select id from auth.users where email=$1", [b.email])
          .then(r => r.rows[0] && r.rows[0].id);
        if(!id) return json(res, 400, { error_description: 'Invalid login credentials' });
        const tok = 't' + (++seq); sessoes.set(tok, id);
        return json(res, 200, { access_token: tok, refresh_token: 'r'+seq, user: { id } });
      }

      if(acao === 'logout'){
        const a = (req.headers.authorization||'').replace('Bearer ','');
        sessoes.delete(a); return json(res, 204, {});
      }
      return json(res, 404, { message: 'auth: ' + acao });
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
