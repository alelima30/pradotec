/* ===========================================================================
   A cota do plano: a tela e o banco têm que concordar

   O `app.html` decide na mão quem está dentro da cota (para desenhar a agenda
   e nomear quem ficou de fora); o banco decide de novo, no gatilho, na hora de
   marcar. Se as duas contas divergirem, o dono vê a coluna de alguém, clica,
   e leva um erro que contradiz a tela.

   Este teste roda as duas contas sobre os mesmos dados e compara.
   Precisa da bancada de pé:  bash tests/bancada/subir.sh
   =========================================================================== */
// `pg` vive em tests/bancada/node_modules, instalado pelo subir.sh — não há
// package.json na raiz, e não vai haver: o projeto não tem build.
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const pg = exigir('./bancada/node_modules/pg');

const cliente = new pg.Client({
  host: process.env.PGHOST || '/tmp', port: +(process.env.PGPORT || 5444),
  user: process.env.PGUSER || 'postgres', database: process.env.PGBANCO || 'app',
});
await cliente.connect();

let ok = 0, falhas = 0;
const diz = (bom, msg, extra) => {
  if(bom){ ok++; console.log('  ✓ ' + msg); }
  else { falhas++; console.log('  ✗ ' + msg + (extra ? '\n      ' + extra : '')); }
};

// A conta da TELA, copiada do app.html. Se você mexer lá, mexa aqui — é
// justamente essa duplicação que o teste existe para vigiar.
function profsNaCotaTela(ativos, limite){
  return ativos.slice()
    .sort((a, b) => (a.criadoEm || '').localeCompare(b.criadoEm || '')
                 || String(a.id).localeCompare(String(b.id)))
    .slice(0, limite);
}

const salao = '99990000-0000-0000-0000-000000000001';
await cliente.query(`delete from public.saloes where id = $1`, [salao]);
await cliente.query(
  `insert into public.saloes (id, slug, nome) values ($1,'salao-cota','Salão Cota')`, [salao]);

console.log('\nA tela e o banco concordam sobre quem está na cota');

for(const [plano, limiteEsperado] of [['salao',20],['time',3],['duo',2],['individual',1]]){
  await cliente.query(`delete from public.profissionais where salao_id = $1`, [salao]);
  await cliente.query(`delete from public.assinaturas where salao_id = $1`, [salao]);
  // Assina o maior primeiro para conseguir cadastrar os 4, depois rebaixa.
  await cliente.query(
    `insert into public.assinaturas (salao_id, plano, status) values ($1,'salao','ativa')`, [salao]);

  // Carimbos fora de ordem alfabética de propósito: se alguma das duas contas
  // ordenar por nome ou por id em vez de por data, o teste pega.
  const gente = [
    { nome:'Dalva',  dias: 10 },
    { nome:'Aline',  dias: 40 },
    { nome:'Carla',  dias: 20 },
    { nome:'Bruna',  dias: 30 },
  ];
  const ativos = [];
  for(const g of gente){
    const r = await cliente.query(
      `insert into public.profissionais (salao_id, nome, criado_em)
       values ($1, $2, now() - ($3 || ' days')::interval)
       returning id, nome, criado_em`, [salao, g.nome, g.dias]);
    ativos.push({ id: r.rows[0].id, nome: r.rows[0].nome,
                  criadoEm: r.rows[0].criado_em.toISOString() });
  }

  await cliente.query(`update public.assinaturas set plano = $2 where salao_id = $1`,
                      [salao, plano]);

  const { rows: [{ limite }] } = await cliente.query(
    `select public.limite_profissionais($1) as limite`, [salao]);
  diz(+limite === limiteEsperado,
      `${plano}: o banco devolve limite ${limiteEsperado}`, `devolveu ${limite}`);

  const daTela = profsNaCotaTela(ativos, +limite).map(p => p.nome).sort();

  const { rows } = await cliente.query(
    `select p.nome from public.profissionais p
      where p.salao_id = $1 and public.profissional_na_cota(p.id)
      order by p.nome`, [salao]);
  const doBanco = rows.map(r => r.nome).sort();

  diz(JSON.stringify(daTela) === JSON.stringify(doBanco),
      `${plano}: as duas contas dão a mesma lista (${doBanco.join(', ') || '—'})`,
      `tela=[${daTela}]  banco=[${doBanco}]`);
}

// E a prova final: marcar com quem a tela diz estar fora tem que ser recusado.
console.log('\nQuem a tela mostra como fora, o banco recusa');
await cliente.query(`update public.assinaturas set plano='individual' where salao_id=$1`, [salao]);
const { rows: dentro } = await cliente.query(
  `select id, nome from public.profissionais
    where salao_id=$1 and public.profissional_na_cota(id)`, [salao]);
const { rows: fora } = await cliente.query(
  `select id, nome from public.profissionais
    where salao_id=$1 and not public.profissional_na_cota(id) and ativo`, [salao]);
diz(dentro.length === 1 && fora.length === 3,
    `no Individual, 1 dentro (${dentro[0]?.nome}) e 3 fora`,
    `dentro=${dentro.length} fora=${fora.length}`);

const cli = (await cliente.query(
  `insert into public.clientes (salao_id, nome) values ($1,'Cliente Cota') returning id`,
  [salao])).rows[0].id;

const marcar = async (prof, quando) => {
  try{
    await cliente.query(
      `insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim)
       values ($1,$2,$3,$4::timestamptz,$4::timestamptz + interval '1 hour')`,
      [salao, cli, prof, quando]);
    return null;
  }catch(e){ return e.message; }
};
diz((await marcar(fora[0].id, '2027-05-10 10:00-03')) !== null,
    `marcar com ${fora[0].nome} (fora) é recusado`);
diz((await marcar(dentro[0].id, '2027-05-10 10:00-03')) === null,
    `marcar com ${dentro[0].nome} (dentro) passa`);

await cliente.query(`delete from public.saloes where id = $1`, [salao]);
await cliente.end();

console.log(falhas
  ? `\n✗ ${falhas} falha(s) em ${ok + falhas} verificações.`
  : `\n✓ ${ok} verificações: a tela e o banco contam a cota do mesmo jeito.`);
process.exit(falhas ? 1 : 0);
