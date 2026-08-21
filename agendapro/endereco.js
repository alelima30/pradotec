/* ===========================================================================
   AgendaPro — endereço
   ---------------------------------------------------------------------------
   `saloes.endereco` é jsonb no banco, e por um bom motivo: o cliente precisa
   ver "Rua das Flores, 210 — Itu/SP" numa linha, o mapa precisa do CEP
   isolado, e a nota fiscal precisa de cada campo separado. Guardar tudo como
   um texto só resolve a primeira e inviabiliza as outras duas.

   O que este arquivo faz é a ponte: monta a linha para a tela e aceita, sem
   quebrar, o formato antigo — quando `endereco` era uma string solta. Salão
   já cadastrado não pode virar tela em branco por causa de uma mudança
   nossa de formato.
   =========================================================================== */

(function (global) {
'use strict';

const UFS = ['AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT',
             'PA','PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO'];

const VAZIO = { logradouro:'', numero:'', complemento:'', bairro:'',
                cidade:'', uf:'', cep:'' };

// Sempre devolve um objeto com os sete campos, venha o que vier.
function normalizar(e){
  if(!e) return Object.assign({}, VAZIO);
  if(typeof e === 'string'){
    // Formato antigo: a linha inteira num campo só. Vai para `logradouro`,
    // que é onde ela some com menos estrago na tela.
    return Object.assign({}, VAZIO, { logradouro: e });
  }
  return Object.assign({}, VAZIO, e);
}

// A linha que o cliente lê. Junta só o que existe — endereço pela metade é
// comum enquanto o dono está cadastrando, e não pode virar "  , — /".
function linha(e){
  const a = normalizar(e);
  const rua = [a.logradouro, a.numero].filter(Boolean).join(', ');
  const comRua = [rua, a.complemento].filter(Boolean).join(' · ');
  const cidadeUf = [a.cidade, a.uf].filter(Boolean).join('/');
  const local = [a.bairro, cidadeUf].filter(Boolean).join(' — ');
  return [comRua, local].filter(Boolean).join(' — ');
}

/* ── O ENDEREÇO NA CAPA, EM DUAS LINHAS ───────────────────────────────────
   A `linha()` acima junta tudo com travessões e serve para lista compacta.
   Na capa do salão ela vira uma tira comprida que quebra em qualquer lugar
   no celular — e é o endereço que a cliente vai usar para chegar lá.

   Aqui saem duas linhas, na ordem em que se lê um endereço:

       Rua Avanhandava, 10
       Bairro Cidade Nova · ITU/SP

   O "Bairro " é acrescentado só quando o campo NÃO começa com uma palavra
   que já diz que tipo de lugar é. "Cidade Nova" vira "Bairro Cidade Nova";
   "Vila Mariana" e "Centro" ficam como estão, porque "Bairro Vila Mariana"
   é o tipo de esperteza automática que estraga o que ia bem. */
const QUALIFICADORES = /^(bairro|vila|vl\.?|jardim|jd\.?|parque|pq\.?|centro|conjunto|cj\.?|n[úu]cleo|ch[áa]cara|s[íi]tio|distrito|setor|quadra|zona|alto|morro|colina|residencial|loteamento)\b/i;

function completo(e){
  const a = normalizar(e);
  const rua = [a.logradouro, a.numero].filter(Boolean).join(', ');
  const primeira = [rua, a.complemento].filter(Boolean).join(' · ');

  const bairro = a.bairro && !QUALIFICADORES.test(a.bairro.trim())
    ? 'Bairro ' + a.bairro.trim() : (a.bairro || '').trim();
  const cidadeUf = [a.cidade, a.uf].filter(Boolean).join('/');
  const segunda = [bairro, cidadeUf].filter(Boolean).join(' · ');

  return [primeira, segunda].filter(Boolean);
}

// Máscara de CEP: 12345-678
function mascaraCep(v){
  const d = String(v || '').replace(/\D/g, '').slice(0, 8);
  return d.length > 5 ? d.slice(0,5) + '-' + d.slice(5) : d;
}

function cepValido(v){
  return /^[0-9]{8}$/.test(String(v || '').replace(/\D/g, ''));
}

/* Formata CPF (11) ou CNPJ (14) só para EXIBIR. A validação de dígito
   verificador mora no criar.html, que é onde o documento entra — aqui ele já
   passou por lá e é só leitura. */
function documento(d){
  const n = String(d || '').replace(/\D/g, '');
  if(n.length === 11)
    return n.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4');
  if(n.length === 14)
    return n.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '$1.$2.$3/$4-$5');
  return d || '';
}

global.Endereco = { normalizar, linha, completo, mascaraCep, cepValido, documento, UFS, VAZIO };

})(window);
