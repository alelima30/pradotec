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
const CORES = ['#3D6B8E','#8A5A83','#4E7C5A','#9A6B45','#5B6E9C','#6B7B54','#7A5E70'];

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
function id(){ return 'x' + Math.random().toString(36).slice(2,10); }

/* ── Dados de demonstração ───────────────────────────────────────────────
   Dois salões de propósito: dá para trocar no seletor lá em cima e conferir
   que um não enxerga o outro — que é a ideia do multi-salão.
   ──────────────────────────────────────────────────────────────────────── */
function semear(){
  const s1 = 'salao-bella', s2 = 'barbearia-ze';
  const comercial = {1:[[540,1140]],2:[[540,1140]],3:[[540,1140]],4:[[540,1140]],5:[[540,1200]],6:[[540,900]]};
  const tarde = {2:[[720,1200]],3:[[720,1200]],4:[[720,1200]],5:[[720,1200]],6:[[540,1020]]};

  const profs = [
    {id:'p1', salaoId:s1, nome:'Ana',     comissaoPct:45, cor:CORES[0], ativo:true, jornada:comercial},
    {id:'p2', salaoId:s1, nome:'Bianca',  comissaoPct:40, cor:CORES[1], ativo:true, jornada:tarde},
    {id:'p3', salaoId:s1, nome:'Carla',   comissaoPct:50, cor:CORES[2], ativo:true, jornada:comercial},
    {id:'p4', salaoId:s2, nome:'Zé',      comissaoPct:60, cor:CORES[3], ativo:true, jornada:comercial},
    {id:'p5', salaoId:s2, nome:'Marcos',  comissaoPct:50, cor:CORES[4], ativo:true, jornada:comercial},
  ];

  const servs = [
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
  ];

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

  return {
    planos: [
      {codigo:'trial',      nome:'Teste grátis', maxProfissionais:1,  precoMes:0},
      {codigo:'individual', nome:'Individual',   maxProfissionais:1,  precoMes:47},
      {codigo:'duo',        nome:'Duo',          maxProfissionais:2,  precoMes:87},
      {codigo:'time',       nome:'Time',         maxProfissionais:3,  precoMes:127},
      {codigo:'equipe',     nome:'Equipe',       maxProfissionais:5,  precoMes:187},
      {codigo:'salao',      nome:'Salão',        maxProfissionais:20, precoMes:297},
    ],
    // O Studio Bella tem 3 profissionais e assina o Time; a barbearia está
    // no teste grátis com 2 — de propósito, para a tela mostrar o aviso de
    // limite estourado, que é o caso que o dono precisa entender.
    assinaturas: [
      {salaoId:s1, plano:'time',  status:'ativa', trialAte:null},
      {salaoId:s2, plano:'trial', status:'trial', trialAte:somarDias(hoje(), 2)},
    ],
    saloes: [
      {id:s1, slug:'studio-bella', nome:'Studio Bella', tipo:'salão',
       endereco:'Rua das Flores, 210 — Itu/SP'},
      {id:s2, slug:'barbearia-do-ze', nome:'Barbearia do Zé', tipo:'barbearia',
       endereco:'Av. Central, 88 — Itu/SP'},
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
    comandas: [],
  };
}

global.CORES = CORES;
global.semearDemo = semear;

})(window);
