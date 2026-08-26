/* ===========================================================================
   AgendaPro — o worker das campanhas de WhatsApp
   Supabase Edge Function (Deno). Roda NO SERVIDOR, nunca no navegador.

   ── POR QUE ESTE ARQUIVO NÃO PODE VIRAR JAVASCRIPT DO PAINEL ───────────────
   Ele é o único lugar do projeto que enxerga duas credenciais:

     WHATSAPP_TOKEN            manda mensagem em nome do salão
     SUPABASE_SERVICE_ROLE_KEY passa por cima de TODO o RLS

   Qualquer uma delas no painel é o fim do isolamento entre salões — o painel
   é HTML servido do GitHub Pages, e tudo o que chega nele é público por
   construção. As duas vivem em variáveis de ambiente da função, postas pelo
   painel do Supabase.

   ── O QUE ELE FAZ ──────────────────────────────────────────────────────────
   Uma volta por chamada, e a volta é curta de propósito (função de borda tem
   teto de tempo):

     pega UM da fila  →  manda  →  registra  →  espera  →  repete

   Quem garante que ninguém é pego duas vezes é o banco, não este código:
   `fila_proxima()` marca a linha como 'processando' na MESMA transação em que
   a lê, com `for update skip locked`. Dois workers rodando juntos, ou este
   mesmo reiniciado no meio, não repetem mensagem.

   ── AGENDAMENTO ────────────────────────────────────────────────────────────
   Não há laço infinito aqui. Quem chama de tempos em tempos é o `pg_cron`,
   pela SQL que está no README ao lado. Função de borda que roda para sempre
   é função que morre no meio e leva a fila junto.
   =========================================================================== */

const SUPABASE_URL  = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WA_TOKEN      = Deno.env.get('WHATSAPP_TOKEN')!;
const WA_PHONE_ID   = Deno.env.get('WHATSAPP_PHONE_ID')!;
const WA_VERSAO     = Deno.env.get('WHATSAPP_API_VERSAO') ?? 'v21.0';

/* Teto de tempo por chamada. A função de borda é derrubada quando estoura o
   limite da plataforma; parar sozinho antes disso deixa a fila num estado
   limpo em vez de num 'processando' órfão. */
const TETO_MS = 55_000;

/* Erros da Meta que NÃO adianta tentar de novo. Repetir número inválido ou
   template reprovado é gastar cota e segurar a fila atrás de uma linha que
   nunca vai passar. O resto — rede, 500, limite de taxa — é temporário e
   volta para a fila com espera crescente. */
const PERMANENTES = new Set([
  131026,  // mensagem não entregável (número não tem WhatsApp)
  131047,  // fora da janela de 24h e sem template
  131051,  // tipo de mensagem não suportado
  132000,  // template: número de parâmetros não bate
  132001,  // template não existe naquele idioma
  132007,  // template reprovado
  100,     // parâmetro inválido
]);

type Alvo = {
  destinatario_id: string; campanha_id: string; telefone: string;
  nome: string; salao: string;
  corpo: string | null; template_nome: string | null; template_idioma: string;
  tentativas: number; intervalo_min: number; intervalo_max: number;
};

const rpc = async (nome: string, args: unknown) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  });
  if(!r.ok) throw new Error(`${nome}: ${r.status} ${await r.text()}`);
  return r.json();
};

/* ── O TELEFONE ────────────────────────────────────────────────────────────
   Validado aqui, antes de gastar uma chamada da API com ele. O que a Meta
   quer é o número em formato internacional, só dígitos, sem `+`.

   Brasil: 55 + DDD (2) + 8 ou 9 dígitos. DDD válido começa em 11 — não
   existe DDD 10 nem menor. Número que não passa vira falha PERMANENTE com
   motivo escrito, e não uma tentativa que a Meta recusa três vezes. */
function paraE164(bruto: string): string | null {
  const n = String(bruto || '').replace(/\D/g, '');
  if(!n) return null;
  if(n.startsWith('55')){
    const resto = n.slice(2);
    if(resto.length < 10 || resto.length > 11) return null;
    if(Number(resto.slice(0, 2)) < 11) return null;
    return n;
  }
  if(n.length === 10 || n.length === 11){
    if(Number(n.slice(0, 2)) < 11) return null;
    return '55' + n;
  }
  // Outro país: aceita se tiver cara de internacional, sem tentar adivinhar.
  return n.length >= 11 && n.length <= 15 ? n : null;
}

/* As variáveis do texto livre. `{{nome}}` vira o primeiro nome — "Olá Maria"
   soa como gente, "Olá Maria Aparecida da Silva" soa como cobrança. */
function preencher(texto: string, a: Alvo){
  return texto
    .replace(/\{\{\s*nome\s*\}\}/gi, (a.nome || '').split(' ')[0])
    .replace(/\{\{\s*nome_completo\s*\}\}/gi, a.nome || '')
    .replace(/\{\{\s*salao\s*\}\}/gi, a.salao || '')
    .replace(/\{\{\s*telefone\s*\}\}/gi, a.telefone || '');
}

/* ── A CHAMADA À CLOUD API ─────────────────────────────────────────────────
   Template quando a campanha tem um: é o único caminho que a Meta entrega
   fora da janela de 24 horas, que é o caso de toda campanha de marketing.
   O nome do cliente entra como parâmetro {{1}} do corpo do template.

   Texto livre só chega em quem falou com o número nas últimas 24h. A Meta
   responde 131047 quando não é o caso, e isso já está na lista de erros
   permanentes: falha uma vez, com motivo, em vez de três. */
async function mandar(a: Alvo, para: string){
  const corpo = a.template_nome
    ? {
        messaging_product: 'whatsapp',
        to: para,
        type: 'template',
        template: {
          name: a.template_nome,
          language: { code: a.template_idioma || 'pt_BR' },
          components: [{
            type: 'body',
            parameters: [{ type: 'text', text: (a.nome || '').split(' ')[0] }],
          }],
        },
      }
    : {
        messaging_product: 'whatsapp',
        to: para,
        type: 'text',
        text: { preview_url: false, body: preencher(a.corpo || '', a) },
      };

  const r = await fetch(
    `https://graph.facebook.com/${WA_VERSAO}/${WA_PHONE_ID}/messages`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${WA_TOKEN}`,
      },
      body: JSON.stringify(corpo),
    });

  const resposta = await r.json().catch(() => ({}));
  if(r.ok) return { ok: true, wamId: resposta?.messages?.[0]?.id ?? null };

  const erro = resposta?.error ?? {};
  return {
    ok: false,
    codigo: String(erro.code ?? r.status),
    // `message` da Meta descreve o problema e não traz segredo. O corpo
    // inteiro traria o que a gente mandou — inclusive o telefone — para
    // dentro do log. Fica só a frase.
    msg: String(erro.message ?? 'falha na API'),
    permanente: PERMANENTES.has(Number(erro.code)),
  };
}

const dormir = (ms: number) => new Promise(r => setTimeout(r, ms));

Deno.serve(async (req) => {
  /* Só quem tem a chave de serviço chama isto. Sem esta porta, o endereço da
     função é público e qualquer um dispara a fila de todo mundo. */
  const auth = req.headers.get('Authorization') ?? '';
  if(auth !== `Bearer ${SERVICE_KEY}`){
    return new Response(JSON.stringify({ erro: 'não autorizado' }), {
      status: 401, headers: { 'Content-Type': 'application/json' } });
  }

  const comecou = Date.now();
  let enviadas = 0, falhas = 0;

  try{
    while(Date.now() - comecou < TETO_MS){
      const lote = await rpc('fila_proxima', { p_lote: 1 }) as Alvo[];
      if(!lote?.length) break;                       // fila vazia: acabou
      const a = lote[0];

      const para = paraE164(a.telefone);
      if(!para){
        await rpc('fila_resultado', {
          p_destinatario: a.destinatario_id, p_ok: false,
          p_erro_codigo: 'telefone_invalido',
          p_erro_msg: 'Telefone fora do formato internacional',
          p_permanente: true,
        });
        falhas++;
        continue;                                    // sem esperar: nada saiu
      }

      let r;
      try{
        r = await mandar(a, para);
      }catch(e){
        // Rede caiu, DNS falhou, a Meta não respondeu. Temporário.
        r = { ok: false, codigo: 'rede', msg: String(e).slice(0, 200),
              permanente: false };
      }

      await rpc('fila_resultado', {
        p_destinatario: a.destinatario_id,
        p_ok: r.ok,
        p_wam_id: r.ok ? (r as { wamId: string }).wamId : null,
        p_erro_codigo: r.ok ? null : (r as { codigo: string }).codigo,
        p_erro_msg:    r.ok ? null : (r as { msg: string }).msg,
        p_permanente:  r.ok ? false : (r as { permanente: boolean }).permanente,
      });
      r.ok ? enviadas++ : falhas++;

      /* A espera. Sorteada dentro da faixa da campanha, e não fixa: cadência
         de metrônomo é o padrão que denuncia robô e queima o número. */
      const min = Math.max(a.intervalo_min ?? 5, 3);
      const max = Math.max(a.intervalo_max ?? 12, min);
      await dormir((min + Math.random() * (max - min)) * 1000);
    }

    return new Response(JSON.stringify({ enviadas, falhas }), {
      headers: { 'Content-Type': 'application/json' } });
  }catch(e){
    /* Nunca `console.log` do corpo da requisição nem dos cabeçalhos: os dois
       carregam o token. Só a mensagem. */
    console.error('[campanhas] ' + String(e).slice(0, 300));
    return new Response(JSON.stringify({ erro: 'falha no processamento',
                                         enviadas, falhas }), {
      status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
