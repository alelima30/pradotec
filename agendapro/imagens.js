/* ===========================================================================
   AgendaPro — imagens
   ---------------------------------------------------------------------------
   Um lugar só para receber foto de celular e devolver algo utilizável.

   O problema é concreto: a dona do salão tira a foto da fachada com o celular
   e o arquivo tem 4 MB, 4000×3000. Isso não pode chegar cru em lugar nenhum —
   no modo demonstração estoura o `localStorage` (que são ~5 MB no TOTAL, para
   agenda, clientes e tudo mais), e na nuvem vira conta de armazenamento e
   página que demora sete segundos para abrir no 4G do salão.

   Então toda imagem passa por aqui antes: redimensiona no próprio navegador,
   com <canvas>, e sai em JPEG. Nenhuma biblioteca — o navegador já sabe fazer
   isso desde sempre.

   Os três tamanhos saem de onde a imagem aparece, não de gosto:
     logo     256px   quadrado pequeno no topo da vitrine
     capa    1200px   faixa larga, precisa aguentar tablet
     serviço  600px   card em grade de duas colunas no celular
   =========================================================================== */

(function (global) {
'use strict';

const MEDIDAS = {
  logo:    { lado: 256,  qualidade: 0.88, tetoKB: 120 },
  capa:    { lado: 1200, qualidade: 0.82, tetoKB: 420 },
  servico: { lado: 600,  qualidade: 0.82, tetoKB: 220 },
};

const TIPOS_ACEITOS = ['image/jpeg','image/png','image/webp','image/heic','image/heif'];

// Quanto o localStorage aguenta, com folga para o resto do sistema. O limite
// real ronda 5 MB; parar em 4 evita o QuotaExceededError acontecer no meio de
// um salvamento e deixar os dados pela metade.
const TETO_NAVEGADOR = 4 * 1024 * 1024;

function lerArquivo(arquivo){
  return new Promise((ok, erro) => {
    const l = new FileReader();
    l.onload  = () => ok(l.result);
    l.onerror = () => erro(new Error('Não consegui ler o arquivo.'));
    l.readAsDataURL(arquivo);
  });
}

function carregarImagem(url){
  return new Promise((ok, erro) => {
    const im = new Image();
    im.onload  = () => ok(im);
    im.onerror = () => erro(new Error('O arquivo não é uma imagem que o navegador abra.'));
    im.src = url;
  });
}

/* Reduz até caber no lado maior pedido, e depois insiste na qualidade até
   caber no teto de bytes. Duas etapas porque são dois limites diferentes: uma
   foto de tela lisa fica minúscula em 1200px, uma foto de salão cheio não. */
async function reduzir(arquivo, tipo){
  const m = MEDIDAS[tipo];
  if(!m) throw new Error('Tipo de imagem desconhecido: ' + tipo);

  const im = await carregarImagem(await lerArquivo(arquivo));

  let { width: l, height: a } = im;
  if(!l || !a) throw new Error('A imagem veio sem dimensão.');

  const escala = Math.min(1, m.lado / Math.max(l, a));
  l = Math.round(l * escala);
  a = Math.round(a * escala);

  const tela = document.createElement('canvas');
  tela.width = l; tela.height = a;
  const ctx = tela.getContext('2d');
  // Fundo branco: PNG com transparência vira preto ao virar JPEG, e logo de
  // salão quase sempre vem em PNG transparente.
  ctx.fillStyle = '#FFFFFF';
  ctx.fillRect(0, 0, l, a);
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(im, 0, 0, l, a);

  let q = m.qualidade;
  let saida = tela.toDataURL('image/jpeg', q);
  while(bytesDe(saida) > m.tetoKB * 1024 && q > 0.4){
    q -= 0.1;
    saida = tela.toDataURL('image/jpeg', q);
  }
  return { dataUrl: saida, largura: l, altura: a, bytes: bytesDe(saida) };
}

/* Quanto uma imagem custa DENTRO do localStorage — que não é o tamanho dela.

   Uma foto de 213 KB ocupou 568 KB no navegador, 2,66 vezes mais. São dois
   fatores multiplicando: o `data:` URL é base64, que infla 4/3, e o
   localStorage guarda string em UTF-16, que dobra outra vez.

   A primeira versão desta conta comparava os bytes DECODIFICADOS contra o
   teto. O guarda deixava passar quase três vezes mais imagem do que cabia, e
   o estouro só aparecia lá na frente — no meio de um salvamento, com os dados
   já pela metade. Aqui a conta é sobre a string que realmente vai ser gravada.
*/
function custoNoNavegador(dataUrl){
  return dataUrl.length * 2;
}

// Tamanho da imagem em si, decodificada. Serve para mostrar "213 KB" para a
// pessoa — não para calcular espaço.
function bytesDe(dataUrl){
  const virgula = dataUrl.indexOf(',');
  const base64 = dataUrl.slice(virgula + 1);
  const enchimento = (base64.endsWith('==') ? 2 : base64.endsWith('=') ? 1 : 0);
  return Math.floor(base64.length * 3 / 4) - enchimento;
}

function daraUmBlob(dataUrl){
  const [cabeca, base64] = dataUrl.split(',');
  const mime = cabeca.match(/:(.*?);/)[1];
  const bruto = atob(base64);
  const bytes = new Uint8Array(bruto.length);
  for(let i = 0; i < bruto.length; i++) bytes[i] = bruto.charCodeAt(i);
  return new Blob([bytes], { type: mime });
}

// Quanto já está ocupado no navegador. Serve para avisar ANTES de estourar.
function ocupadoNoNavegador(){
  let total = 0;
  try{
    for(let i = 0; i < localStorage.length; i++){
      const k = localStorage.key(i);
      total += (k.length + (localStorage.getItem(k) || '').length) * 2;
    }
  }catch(e){}
  return total;
}

/* A porta de entrada: recebe o arquivo do <input type=file> e devolve o
   ENDEREÇO da imagem — que é o que vai para a coluna do banco.

   Na nuvem, sobe para o Storage e devolve a URL pública.
   Na demonstração, devolve o próprio `data:` — mesma coluna, mesma tela. */
async function guardar(arquivo, tipo, salaoId, chave){
  if(!arquivo) throw new Error('Nenhum arquivo escolhido.');
  if(arquivo.type && !TIPOS_ACEITOS.includes(arquivo.type)){
    throw new Error('Formato não aceito. Use JPG, PNG ou WEBP.');
  }
  const r = await reduzir(arquivo, tipo);
  return await publicar(r.dataUrl, salaoId, chave);
}

/* Separado do `guardar` porque a foto do serviço nasce antes do serviço: ela é
   reduzida no momento em que a pessoa escolhe o arquivo, mas só ganha um nome
   estável depois que o serviço é salvo e tem id. Então a redução acontece
   primeiro e a publicação depois, com o `data:` esperando no meio. */
async function publicar(dataUrl, salaoId, chave){
  if(!dataUrl) return null;
  if(!dataUrl.startsWith('data:')) return dataUrl;   // já é endereço, nada a fazer

  const naNuvem = !!(global.Dados && global.Dados.ligado);
  if(!naNuvem){
    if(ocupadoNoNavegador() + custoNoNavegador(dataUrl) > TETO_NAVEGADOR){
      throw new Error(
        'O navegador está sem espaço para mais imagens nesta demonstração. '
      + 'Apague alguma foto, ou ligue no Supabase para as imagens irem para o '
      + 'servidor em vez de ficarem aqui.');
    }
    return dataUrl;
  }
  return await global.Dados.enviarImagem(salaoId, chave + '.jpg', daraUmBlob(dataUrl));
}

global.Imagens = {
  guardar, publicar, reduzir, bytesDe, custoNoNavegador, ocupadoNoNavegador,
  TETO_NAVEGADOR, MEDIDAS,
};

})(window);
