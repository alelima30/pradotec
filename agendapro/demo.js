/* ===========================================================================
   AgendaPro — dados de demonstração
   ---------------------------------------------------------------------------
   Os dois aplicativos (o do salão e o do cliente) leem o mesmo `localStorage`,
   então a semente precisa ser uma só. Antes ela morava dentro do `app.html`:
   quem abrisse o link do cliente primeiro — que é exatamente o que acontece
   quando o salão manda o link no WhatsApp — caía numa tela vazia dizendo
   "abra o app.html antes". Aqui ela é um arquivo, e as duas telas semeiam.

   Vale só para a demonstração. Com o `config.js` preenchido, os dados vêm do
   Supabase e nada disto roda.
   =========================================================================== */

(function (global) {
'use strict';

// Cores das colunas da agenda: mesma luminosidade, saturação baixa, para
// distinguir profissionais sem transformar a tela num painel de avisos.
//
// Nenhuma delas puxa para o rosa, e isso é intencional: metade dos salões que
// usam isto é barbearia, e a coluna de um barbeiro pintada de lilás é a
// primeira coisa que ele nota. Sete matizes bem separados em volta do azul,
// do verde e do terroso resolvem a distinção sem esse recado.
const CORES = ['#3D6B8E','#3F7A78','#4E7C5A','#9A6B45','#5B6E9C','#6B7B54','#5F5B6E'];

function iso(d){
  return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0')
       + '-' + String(d.getDate()).padStart(2,'0');
}
function hoje(){ return iso(new Date()); }
function somarDias(dataIso, n){
  const [a,m,dd] = dataIso.split('-').map(Number);
  const d = new Date(a, m-1, dd);
  d.setDate(d.getDate() + n);
  return iso(d);
}
/* Imagens da demonstração.

   São SVG chapado virado `data:` URL, não fotografia — cada uma pesa menos de
   700 bytes, contra os 200 KB de um JPEG de verdade. A demonstração inteira
   cabe folgada no localStorage, e o repositório não carrega binário.

   Servem para mostrar o FORMATO: onde a logo entra, o que a capa ocupa, como
   o card de serviço se comporta com e sem foto. Fingir fotografia de salão
   com imagem de banco seria pior — o dono trocaria tudo no primeiro minuto. */
const LOGO = {
  s1: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cmVjdCB3aWR0aD0iMTI4IiBoZWlnaHQ9IjEyOCIgZmlsbD0iIzJBMjgyMyIvPjx0ZXh0IHg9IjY0IiB5PSI2NCIgZm9udC1mYW1pbHk9IkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmIiBmb250LXNpemU9IjU4IiBmb250LXdlaWdodD0iNjAwIiBmaWxsPSIjRjdGNkY0IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBkb21pbmFudC1iYXNlbGluZT0iY2VudHJhbCI+U0I8L3RleHQ+PC9zdmc+',
  s2: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cmVjdCB3aWR0aD0iMTI4IiBoZWlnaHQ9IjEyOCIgZmlsbD0iIzQwM0QzNyIvPjx0ZXh0IHg9IjY0IiB5PSI2NCIgZm9udC1mYW1pbHk9IkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmIiBmb250LXNpemU9IjU4IiBmb250LXdlaWdodD0iNjAwIiBmaWxsPSIjRjdGNkY0IiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBkb21pbmFudC1iYXNlbGluZT0iY2VudHJhbCI+Qlo8L3RleHQ+PC9zdmc+',
};
const CAPA = {
  s1: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2MDAgNDAwIj48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImciIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAiIHN0b3AtY29sb3I9IiMzRDZCOEUiLz48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiM4QTVBODMiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cmVjdCB3aWR0aD0iNjAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0idXJsKCNnKSIvPjx0ZXh0IHg9IjMwMCIgeT0iMjA1IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjQiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44MiIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Zm90byBkbyBzYWzDo288L3RleHQ+PC9zdmc+',
  s2: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2MDAgNDAwIj48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImciIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAiIHN0b3AtY29sb3I9IiM0MDNEMzciLz48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiM5QTZCNDUiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cmVjdCB3aWR0aD0iNjAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0idXJsKCNnKSIvPjx0ZXh0IHg9IjMwMCIgeT0iMjA1IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjQiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44MiIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Zm90byBkYSBiYXJiZWFyaWE8L3RleHQ+PC9zdmc+',
};
const FOTO_SERVICO = {
  'v1': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzNENkI4RSIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Y29ydGUgZmVtaW5pbm88L3RleHQ+PC9zdmc+',
  'v3': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzhBNUE4MyIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Y29sb3Jhw6fDo288L3RleHQ+PC9zdmc+',
  'v4': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzdBNUU3MCIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+bWVjaGFzPC90ZXh0Pjwvc3ZnPg==',
  'v5': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzRFN0M1QSIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+bWFuaWN1cmU8L3RleHQ+PC9zdmc+',
  'v8': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzlBNkI0NSIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Y29ydGUgbWFzY3VsaW5vPC90ZXh0Pjwvc3ZnPg==',
  'v9': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzVCNkU5QyIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+YmFyYmE8L3RleHQ+PC9zdmc+',
  'v10': 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgMzAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjMwMCIgZmlsbD0iIzZCN0I1NCIvPjx0ZXh0IHg9IjIwMCIgeT0iMTU2IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjEiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44OCIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Y29ydGUgKyBiYXJiYTwvdGV4dD48L3N2Zz4=',
};

function id(){ return 'x' + Math.random().toString(36).slice(2,10); }

/* ── Dados de demonstração ───────────────────────────────────────────────
   Dois salões de propósito: dá para trocar no seletor lá em cima e conferir
   que um não enxerga o outro — que é a ideia do multi-salão.
   ──────────────────────────────────────────────────────────────────────── */
function semear(){
  const s1 = 'salao-bella', s2 = 'barbearia-ze';
  const comercial = {1:[[540,1140]],2:[[540,1140]],3:[[540,1140]],4:[[540,1140]],5:[[540,1200]],6:[[540,900]]};
  const tarde = {2:[[720,1200]],3:[[720,1200]],4:[[720,1200]],5:[[720,1200]],6:[[540,1020]]};

  // `criadoEm` distinto de propósito: é ele que decide quem fica na cota do
  // plano quando o salão tem mais gente do que o plano cobre. Com todo mundo
  // carimbado no mesmo instante, quem decidiria seria o desempate por id — que
  // funciona, mas não é o que o dono espera ver.
  const nascido = n => somarDias(hoje(), -n) + 'T09:00:00Z';
  const profs = [
    {id:'p1', salaoId:s1, nome:'Ana',     comissaoPct:45, cor:CORES[0], ativo:true, jornada:comercial, criadoEm:nascido(120)},
    {id:'p2', salaoId:s1, nome:'Bianca',  comissaoPct:40, cor:CORES[1], ativo:true, jornada:tarde,     criadoEm:nascido(90)},
    {id:'p3', salaoId:s1, nome:'Carla',   comissaoPct:50, cor:CORES[2], ativo:true, jornada:comercial, criadoEm:nascido(60)},
    {id:'p4', salaoId:s2, nome:'Zé',      comissaoPct:60, cor:CORES[3], ativo:true, jornada:comercial, criadoEm:nascido(150)},
    {id:'p5', salaoId:s2, nome:'Marcos',  comissaoPct:50, cor:CORES[4], ativo:true, jornada:comercial, criadoEm:nascido(30)},
  ];

  const comFoto = l => l.map(x => FOTO_SERVICO[x.id]
                                  ? Object.assign({}, x, {foto: FOTO_SERVICO[x.id]}) : x);
  const servs = comFoto([
    {id:'v1', salaoId:s1, nome:'Corte feminino',   categoria:'Cabelo', duracaoMin:60,  intervaloMin:10, preco:90,  comissaoPct:null, ativo:true},
    {id:'v2', salaoId:s1, nome:'Escova',           categoria:'Cabelo', duracaoMin:45,  intervaloMin:0,  preco:70,  comissaoPct:null, ativo:true},
    {id:'v3', salaoId:s1, nome:'Coloração',        categoria:'Química',duracaoMin:120, intervaloMin:15, preco:280, comissaoPct:35,   ativo:true},
    {id:'v4', salaoId:s1, nome:'Mechas',           categoria:'Química',duracaoMin:180, intervaloMin:15, preco:450, comissaoPct:35,   ativo:true},
    {id:'v5', salaoId:s1, nome:'Manicure',         categoria:'Unhas',  duracaoMin:45,  intervaloMin:5,  preco:45,  comissaoPct:null, ativo:true},
    {id:'v6', salaoId:s1, nome:'Pedicure',         categoria:'Unhas',  duracaoMin:60,  intervaloMin:5,  preco:55,  comissaoPct:null, ativo:true},
    {id:'v7', salaoId:s1, nome:'Sobrancelha',      categoria:'Estética',duracaoMin:30, intervaloMin:0,  preco:40,  comissaoPct:null, ativo:true},
    {id:'v8', salaoId:s2, nome:'Corte masculino',  categoria:'Cabelo', duracaoMin:30,  intervaloMin:5,  preco:50,  comissaoPct:null, ativo:true},
    {id:'v9', salaoId:s2, nome:'Barba',            categoria:'Barba',  duracaoMin:30,  intervaloMin:5,  preco:40,  comissaoPct:null, ativo:true},
    {id:'v10',salaoId:s2, nome:'Corte + barba',    categoria:'Combo',  duracaoMin:60,  intervaloMin:5,  preco:80,  comissaoPct:null, ativo:true},
  ]);

  const clis = [
    {id:'c1', salaoId:s1, nome:'Maria Silva',      telefone:'(11) 98888-1111', obs:'Alergia a amônia'},
    {id:'c2', salaoId:s1, nome:'Joana Prado',      telefone:'(11) 98888-2222', obs:'Cor 7.1 + 20 vol'},
    {id:'c3', salaoId:s1, nome:'Rita Nogueira',    telefone:'(11) 98888-3333', obs:''},
    {id:'c4', salaoId:s1, nome:'Beatriz Antunes',  telefone:'(11) 98888-4444', obs:'Prefere a Carla'},
    {id:'c5', salaoId:s2, nome:'João Pereira',     telefone:'(11) 97777-1111', obs:'Máquina 2 dos lados'},
    {id:'c6', salaoId:s2, nome:'Pedro Alves',      telefone:'(11) 97777-2222', obs:''},
  ];

  const prods = [
    {id:'d1', salaoId:s1, nome:'Máscara capilar',  preco:65, comissaoPct:10},
    {id:'d2', salaoId:s1, nome:'Óleo de argan',    preco:48, comissaoPct:10},
    {id:'d3', salaoId:s2, nome:'Pomada modeladora',preco:35, comissaoPct:15},
  ];

  // Agenda de hoje, montada sem chocar: cada profissional em sequência.
  const d = hoje();
  const ags = [];
  const marcar = (cli, prof, sv, ini, status) => {
    const s = servs.find(x => x.id === sv);
    const p = profs.find(x => x.id === prof);
    ags.push({
      id:id(), salaoId:p.salaoId, clienteId:cli, profissionalId:prof, data:d,
      inicio:ini, fim:ini + s.duracaoMin + s.intervaloMin, status,
      origem: status === 'pendente' ? 'online' : 'recepcao',
      servicos:[{servicoId:sv, duracaoMin:s.duracaoMin, preco:s.preco,
                 comissaoPct: s.comissaoPct != null ? s.comissaoPct : p.comissaoPct}],
      obs:'',
    });
  };
  marcar('c1','p1','v1', 9*60,      'concluido');
  marcar('c2','p1','v3', 10*60+30,  'em_atendimento');
  marcar('c3','p1','v2', 14*60,     'confirmado');
  marcar('c4','p3','v4', 9*60,      'confirmado');
  marcar('c1','p3','v7', 14*60,     'pendente');
  marcar('c2','p2','v5', 13*60,     'confirmado');
  marcar('c3','p2','v6', 15*60,     'confirmado');
  marcar('c5','p4','v10', 9*60,     'concluido');
  marcar('c6','p4','v8', 10*60+30,  'confirmado');
  marcar('c5','p5','v9', 11*60,     'confirmado');

  /* ── DOIS MESES DE CAIXA JÁ FECHADO ──────────────────────────────────────
     A demonstração tinha agenda e não tinha história: `comandas: []`. Servia
     enquanto o painel só mostrava o dia — mas o Relatórios abre perguntando
     "quanto eu faturei no mês", e a resposta era uma tela vazia. Quem abre a
     demonstração para decidir se assina veria justamente a tela que mais
     vende parecendo quebrada.

     São 59 dias para trás de propósito: dois meses cheios, então o período
     ANTERIOR também tem movimento e a comparação percentual aparece. Com um
     mês só, o relatório do mês passado voltaria vazio e a variação não teria
     contra o que comparar.
     ─────────────────────────────────────────────────────────────────────── */
  const comandas = [];
  {
    /* Sorteio DETERMINÍSTICO. `Math.random()` faria o faturamento mudar a
       cada F5 — e quem está avaliando o sistema veria o número dançar e
       concluiria, com razão, que não dá para confiar na conta.

       ⚠ E determinístico não basta: tem que ser BEM misturado. A primeira
       versão era o congruente linear clássico (`x*1103515245+12345 % 2^31`),
       que é determinístico e parece aleatório sozinho — mas os valores dele
       caem em hiperplanos, e sorteios vizinhos ficam correlacionados. Aqui
       isso apareceu na tela: a falta que deveria virar cancelamento em 40%
       dos casos virou 1 vez em 12, porque o sorteio do cancelamento vinha
       sempre quatro posições depois do que decidia se havia falta.

       Este é o mulberry32 — mesmo tamanho, mesma reprodutibilidade, e sem a
       estrutura que enviesa sorteios encadeados. */
    let semente = 20260826;
    const sorteio = () => {
      semente = (semente + 0x6D2B79F5) | 0;
      let t = Math.imul(semente ^ (semente >>> 15), 1 | semente);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    const escolher = lista => lista[Math.floor(sorteio() * lista.length)];

    const catalogo = servs.filter(x => x.salaoId === s1);
    const equipe   = profs.filter(x => x.salaoId === s1 && x.ativo !== false);
    const carteira = clis.filter(x => x.salaoId === s1);
    const gondola  = prods.filter(x => x.salaoId === s1);
    let n = 0;

    for(let volta = 59; volta >= 1; volta--){
      const dia = somarDias(d, -volta);
      if(new Date(dia + 'T12:00').getDay() === 0) continue;   // domingo, fechado

      /* Cada comanda do passado ganha o atendimento que a originou. Sem
         isso, o relatório mostrava 73 comandas fechadas ao lado de "1
         atendimento concluído" — as duas contas certas, e a tela mentindo
         por omissão, porque no salão de verdade uma vem da outra.

         A agenda de cada profissional anda em fila: o próximo entra quando o
         anterior acaba. Atendimento em cima de atendimento é um dado que não
         pode existir, nem na demonstração. */
      const livre = {};
      const proximaVaga = (pid, sv) => {
        const ini = livre[pid] == null ? 9*60 : livre[pid];
        livre[pid] = ini + sv.duracaoMin + (sv.intervaloMin || 0);
        return ini;
      };

      const quantas = 2 + Math.floor(sorteio() * 4);
      for(let k = 0; k < quantas; k++){
        const sv  = escolher(catalogo);
        const pro = escolher(equipe);
        const cli = escolher(carteira);
        const ini = proximaVaga(pro.id, sv);
        ags.push({
          id:id(), salaoId:s1, clienteId:cli.id, profissionalId:pro.id,
          data:dia, inicio:ini, fim: ini + sv.duracaoMin + (sv.intervaloMin||0),
          status:'concluido', origem: sorteio() < 0.35 ? 'online' : 'recepcao',
          valorPrevisto: sv.preco,
          servicos:[{ servicoId:sv.id, duracaoMin:sv.duracaoMin, preco:sv.preco,
            comissaoPct: sv.comissaoPct != null ? sv.comissaoPct : pro.comissaoPct }],
          obs:'',
        });
        const itens = [{ tipo:'servico', descricao:sv.nome, qtd:1,
          precoUnit:sv.preco, profissionalId:pro.id,
          comissaoPct: sv.comissaoPct != null ? sv.comissaoPct : pro.comissaoPct }];
        // Uma em cada cinco leva produto. É o que faz "o que mais saiu"
        // misturar serviço e prateleira, como no salão de verdade.
        if(sorteio() < 0.2 && gondola.length){
          const pr = escolher(gondola);
          itens.push({ tipo:'produto', descricao:pr.nome, qtd:1,
            precoUnit:pr.preco, profissionalId:pro.id, comissaoPct:pr.comissaoPct });
        }
        const total = itens.reduce((s,i) => s + i.qtd*i.precoUnit, 0);
        const forma = escolher(['pix','credito','debito','dinheiro','credito']);
        // A maquininha cobra; sem a taxa aqui, a coluna "líquido" do
        // relatório mostraria o bruto e ensinaria a conta errada.
        const taxa = forma === 'credito' ? Math.round(total * 4.49) / 100
                   : forma === 'debito'  ? Math.round(total * 1.99) / 100 : 0;

        comandas.push({
          id:id(), salaoId:s1, clienteId:cli.id, numero: ++n, data: dia,
          status:'fechada', desconto:0,
          // O instante do fechamento é o que diz de que mês é esse dinheiro.
          fechadaEm: dia + 'T19:30:00-03:00',
          itens, pagamentos:[{ forma, valor: total, parcelas:1, taxa }],
        });
      }

      /* E um dia sim, outro não, alguém não aparece. Sem falta nenhuma o
         relatório mostraria "R$ 0,00 ficou na mesa" — que é o número que
         justifica lembrete e sinal, e o único que nenhum salão tem zerado. */
      if(sorteio() < 0.28){
        const sv  = escolher(catalogo);
        const pro = escolher(equipe);
        const cli = escolher(carteira);
        const ini = proximaVaga(pro.id, sv);
        ags.push({
          id:id(), salaoId:s1, clienteId:cli.id, profissionalId:pro.id,
          data:dia, inicio:ini, fim: ini + sv.duracaoMin + (sv.intervaloMin||0),
          status: sorteio() < 0.6 ? 'faltou' : 'cancelado',
          origem:'online', valorPrevisto: sv.preco,
          servicos:[{ servicoId:sv.id, duracaoMin:sv.duracaoMin, preco:sv.preco,
            comissaoPct: sv.comissaoPct != null ? sv.comissaoPct : pro.comissaoPct }],
          obs:'',
        });
      }
    }
  }

  return {
    // Espelha os planos do 01_schema.sql. `recursos` é o que separa o Grátis
    // do Individual: sem ele, um profissional com tudo liberado é exatamente
    // o que o plano de R$ 47 ofereceria, e ninguém assinaria.
    planos: [
      {codigo:'gratuito',   nome:'Grátis',       maxProfissionais:1,  precoMes:0,
       recursos:{agendamentos_mes:40, lembrete_whatsapp:false, agenda_online:true}},
      {codigo:'trial',      nome:'Teste grátis', maxProfissionais:1,  precoMes:0,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
      {codigo:'individual', nome:'Individual',   maxProfissionais:1,  precoMes:47,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
      {codigo:'duo',        nome:'Duo',          maxProfissionais:2,  precoMes:87,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
      {codigo:'time',       nome:'Time',         maxProfissionais:3,  precoMes:127,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
      {codigo:'equipe',     nome:'Equipe',       maxProfissionais:5,  precoMes:187,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
      {codigo:'salao',      nome:'Salão',        maxProfissionais:20, precoMes:297,
       recursos:{lembrete_whatsapp:true, agenda_online:true}},
    ],
    // Três situações de propósito, porque são as três telas que o dono vê:
    // o Studio Bella assina o Time e está no limite; a barbearia está com o
    // teste acabando; e o terceiro caso — o salão que nunca vai assinar —
    // aparece quando o teste da barbearia vence e ela cai no Grátis.
    assinaturas: [
      {salaoId:s1, plano:'time',  status:'ativa', trialAte:null, venceEm:null},
      {salaoId:s2, plano:'trial', status:'trial',
       trialAte:somarDias(hoje(), 2), venceEm:null},
    ],
    saloes: [
      {id:s1, slug:'studio-bella', nome:'Studio Bella', tipo:'salão',
       telefone:'(11) 3322-1100', whatsapp:'(11) 99911-2233',
       endereco:{logradouro:'Rua das Flores', numero:'210', complemento:'',
                 bairro:'Centro', cidade:'Itu', uf:'SP', cep:'13300000'},
       logo:LOGO.s1, capa:CAPA.s1},
      {id:s2, slug:'barbearia-do-ze', nome:'Barbearia do Zé', tipo:'barbearia',
       telefone:'(11) 3344-5500', whatsapp:'(11) 99955-6677',
       endereco:{logradouro:'Av. Central', numero:'88', complemento:'Loja 3',
                 bairro:'Vila Nova', cidade:'Itu', uf:'SP', cep:'13309100'},
       logo:LOGO.s2, capa:CAPA.s2},
    ],
    documentosCobranca: [
      {salaoId:s1, documento:'11222333000181'},
      {salaoId:s2, documento:'11144477735'},
    ],
    profissionais: profs,
    servicos: servs,
    clientes: clis,
    produtos: prods,
    agendamentos: ags,
    bloqueios: [
      // O almoço fica depois dos atendimentos longos da manhã: mecha de 3h
      // começando às 9h só termina 12h15. Bloqueio em cima de atendimento é
      // um dado que não pode existir, nem na demonstração.
      {id:id(), salaoId:s1, profissionalId:'p1', data:d, inicio:13*60, fim:14*60, motivo:'Almoço'},
      {id:id(), salaoId:s1, profissionalId:'p3', data:d, inicio:12*60+15, fim:13*60+15, motivo:'Almoço'},
    ],
    comandas,
  };
}

global.CORES = CORES;
global.semearDemo = semear;

})(window);
