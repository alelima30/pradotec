# AgendaPro

Sistema de agendamento para salão de beleza, barbearia, manicure e estética.
Irmão do [AdminPro](https://github.com/alelima30/adminpro): mesma stack —
HTML/CSS/JS puro, sem build, backend Supabase, PWA instalável — com as dívidas
daquele projeto corrigidas de saída.

**Estado: completo para testar.** Roda sozinho no navegador, e liga no
Supabase preenchendo dois campos no `config.js`. Os dois caminhos foram
verificados de ponta a ponta.

---

## O que já está aqui

| Arquivo | O que faz |
|---|---|
| `app.html` | O salão: agenda, clientes, serviços, equipe e caixa |
| `agendar.html` | O cliente: capa do salão, escolha, código no WhatsApp, meus horários |
| `index.html` | Encaminha a raiz para o app |
| `sw.js` + `manifest.webmanifest` | PWA — instala no celular e no computador |
| `supabase/01_schema.sql` | 20 tabelas, as duas travas da agenda, comanda e comissão |
| `supabase/02_rls.sql` | Isolamento entre salões e entre papéis — a segurança de verdade |
| `config.js` | **o único arquivo a editar** para ligar no Supabase |
| `dados.js` | a camada de dados: localStorage ou Supabase, escolhido pelo config |
| `supabase/00_tudo.sql` | instalação completa, para colar de uma vez no SQL Editor |
| `estilo.css` | o sistema visual: paleta, tipografia e componentes, num lugar só |
| `icones.js` | 30 ícones em SVG traçado, no lugar de emoji |
| `demo.js` | a semente da demonstração, compartilhada pelas duas telas |
| `criar.html` | o cadastro do dono: plano, dados e link pronto |
| `tests/` | 274 verificações: banco, colunas, camada de dados, cota do plano e imagens |

> **Para instalar e testar de ponta a ponta, siga o
> [COMO-TESTAR.md](COMO-TESTAR.md).** Este arquivo explica as decisões; aquele
> explica os passos.

## Como testar

### Os dois lados

São dois aplicativos sobre o mesmo banco:

| | Quem usa | Onde |
|---|---|---|
| **Recepção** | dono, recepção, profissional | `app.html` |
| **Cliente** | quem marca horário | `agendar.html?salao=<slug>` |

### Como o cliente chega no salão certo

Pelo `slug` — a coluna `saloes.slug`, que é o apelido do salão no endereço:

```
agendar.html?salao=studio-bella
agendar.html?salao=barbearia-do-ze
```

É esse link que o salão manda no WhatsApp, cola na bio do Instagram ou imprime
como QR no espelho. Cada salão tem o seu, e ele é a única porta de entrada
do cliente — quem abre um link não enxerga o outro salão.

Dentro do `app.html`, na aba **Ver como cliente**, o link aparece pronto com
botão de copiar. Sem o parâmetro, `agendar.html` mostra a lista de salões:
isso existe só para a demonstração; em produção o link sempre traz um.

**A tela** — abra `app.html` **ou** `agendar.html?salao=studio-bella` no
navegador. Qualquer uma das duas cria os dados de demonstração se ainda não
existirem: dois salões, cinco profissionais, dez serviços e a agenda de hoje
preenchida. (O app do cliente semeia também porque, na vida real, o link do
WhatsApp costuma ser a primeira porta que a pessoa abre.) Tudo fica no
`localStorage`; o botão **Recomeçar** devolve ao estado inicial.

Para instalar como aplicativo é preciso servir por http, porque navegador não
registra service worker em `file://`:

```bash
cd agendapro && python3 -m http.server 8000
# abra http://localhost:8000  →  botão "Instalar app"
```

**O banco** — precisa de um Postgres alcançável:

```bash
bash tests/rodar.sh
PGHOST=localhost PGPORT=5432 bash tests/rodar.sh
```

**No Supabase** — rode `01_schema.sql` e `02_rls.sql` no SQL Editor, depois
cole `tests/conferir_instalacao.sql` e clique em Run. Ele devolve onze linhas
✓/✗ dizendo se a instalação ficou de pé (RLS ligado, trava presente, vitrine
aberta, nenhuma tabela exposta para quem não fez login).

## O que dá para conferir na tela

- **Multi-salão** — troque de salão no seletor do topo: agenda, clientes e
  serviços mudam junto, e um não enxerga o outro
- **A grade entende serviço** — mecha ocupa 3h, corte ocupa 1h; o listrado
  marca fora da jornada e o hachurado marca almoço
- **Conflito** — tente marcar em cima de alguém e o aviso aparece antes de salvar
- **Ver como cliente** — a mesma agenda vista de fora: só os horários livres,
  sem nome nem telefone de ninguém. Dia cheio sugere os próximos com vaga
- **Comanda** — clique num atendimento, abra a comanda, some produto e veja a
  comissão sair por item

## As três decisões que definem o projeto

**1. Um login, vários salões.** No AdminPro a pessoa pertence a um condomínio
— uma coluna `condominio_id` resolve. Aqui não: a mesma cliente corta o cabelo
na barbearia e faz unha no salão da esquina, com o mesmo telefone. Então a
identidade é global (`perfis`, uma linha por telefone) e o pertencimento é uma
tabela à parte (`vinculos`), com papel por salão. As policies perguntam *"você
tem vínculo com este salão, e em que papel?"*, não *"qual é o seu salão?"*.

**2. Horário duplicado é impossível, e não por educação do JavaScript.** O
AdminPro confere conflito no navegador (`hrConflita`), então duas recepcionistas
clicando junto marcam o mesmo horário — nenhuma das duas telas sabe da outra.
Aqui a recusa é do banco, por uma constraint `EXCLUDE USING gist` sobre
`tstzrange`. Não fura por corrida, nem chamando a API direto, nem com o
JavaScript desligado.

O almoço, o médico e o feriado moram noutra tabela (`bloqueios`), e `EXCLUDE`
não atravessa duas tabelas — então essa metade é um par de gatilhos, um de
cada lado. Sem eles dava para marcar mecha de três horas por cima do almoço,
ou bloquear em cima de quem já estava marcado invertendo a ordem.

**3. Nada de `modulo_dados`.** O AdminPro guarda metade do sistema como um
bloco JSON por módulo, e a própria documentação dele reconhece o custo: dois
admins salvando junto, o último apaga o trabalho do primeiro, e nada disso tem
teste. Aqui tudo é tabela, coluna e chave desde o primeiro dia.

## O que o cliente enxerga (e o que não enxerga)

O ponto mais fácil de errar. Uma policy do tipo `using (tem_acesso(salao_id))`
parece certa na tela e vaza a clientela inteira: basta chamar a API REST do
Supabase pelo navegador, sem passar pelo nosso app.

| Quem | Alcança |
|---|---|
| Cliente | Os agendamentos **dele**, a ficha **dele**, a conta **dele**. Horário livre vem de função que devolve horários, não linhas. |
| Profissional | A agenda dele e a comissão dele. Não vê o que a colega ganhou. |
| Recepção / dono | Tudo do próprio salão. |
| Outro salão | Nada. Nem uma linha. |
| Sem login | Só a vitrine: nome, serviços, preços e quem atende. |

Cada uma dessas linhas é um teste em `tests/02_rls.test.sql`, rodando com
`set role authenticated` — que é como o Supabase trata um JWT. Sem trocar o
papel, o teste rodaria como superusuário e passaria por cima do RLS: verde
mentiroso, o pior tipo.

## As fotos do salão

Três imagens, e cada uma resolve um problema diferente na hora de o cliente
abrir o link vindo do WhatsApp:

| | Onde aparece | Tamanho final |
|---|---|---|
| **Logo** | selo no topo da vitrine e na lista de salões | 256 px, até 120 KB |
| **Foto do salão** | a faixa larga logo abaixo do nome | 1200 px, até 420 KB |
| **Foto do serviço** | o card que o cliente escolhe | 600 px, até 220 KB |

A foto do serviço é a que mais muda conversão: "corte navalhado" não diz nada
para quem nunca cortou ali; a imagem diz. Quando nenhum serviço tem foto, a
grade vira lista sozinha — um card alto e vazio seria pior que uma linha.

### Foto de celular tem 16 MB. Isto não pode chegar cru em lugar nenhum

Toda imagem passa pelo `imagens.js` antes de existir: redimensiona no próprio
navegador, com `<canvas>`, e sai em JPEG. Sem biblioteca — o navegador faz isso
desde sempre. Um PNG de 16,7 MB e 3000×2000 sai com 213 KB e 1200×800.

Fundo branco antes de desenhar, porque PNG transparente vira preto ao virar
JPEG — e logo de salão quase sempre vem em PNG transparente.

**Onde os bytes ficam.** Em produção, no Supabase Storage, e a coluna guarda a
URL. Na demonstração, a própria `data:` URL no `localStorage`. Coluna `text`
nos dois casos, então a tela não sabe a diferença.

**O guarda de espaço erra por 2,66× se for ingênuo.** Uma imagem de 213 KB
ocupou 568 KB no navegador: o `data:` é base64, que infla 4/3, e o
`localStorage` guarda string em UTF-16, que dobra outra vez. A primeira versão
comparava os bytes *decodificados* contra o teto — deixava passar quase três
vezes mais imagem do que cabia, e o estouro só aparecia lá na frente, no meio
de um salvamento, com os dados já pela metade. A conta agora é sobre a string
que vai ser gravada.

### O balde é público para ler, e só para ler

As fotos existem para aparecer na vitrine, que abre antes de qualquer login —
imagem atrás de autenticação numa página pública é imagem que não carrega.

A escrita é outra história. O caminho é sempre `<salao_id>/arquivo.jpg`, e a
policy tira dali de quem é o arquivo. Sem isso, qualquer dono logado troca a
logo do concorrente. Quatro testes em `tests/02_rls.test.sql` cercam os quatro
caminhos: a própria pasta, a do vizinho, a raiz do balde e uma pasta com nome
inventado — esta última importa porque um `::uuid` que levanta exceção dentro
de uma policy derruba a consulta inteira em vez de simplesmente negar.

## Como o dinheiro entra (e o que acontece com quem não paga)

Nem todo salão vai assinar, e o sistema foi desenhado sabendo disso. Quem não
assina fica no **Grátis** — plano de verdade, sem prazo — e quem cresce esbarra
num teto que cresce junto:

| | Grátis | Individual | Duo → Salão |
|---|---|---|---|
| Profissionais na agenda | 1 | 1 | 2 a 20 |
| Horários por mês | 40 | sem teto | sem teto |
| Link de agendamento | sim | sim | sim |
| Lembrete no WhatsApp | não | sim | sim |
| Preço | R$ 0 | R$ 47 | R$ 87 a R$ 297 |

As duas linhas do meio são o que faz o Individual existir. Sem elas, um
profissional com tudo liberado é exatamente o que o Grátis já dá, e ninguém
sairia dele — o plano de R$ 47 seria invendável por aritmética, não por preço.
O lembrete fica de fora do Grátis por caixa: cada mensagem é dinheiro que sai
por salão que não paga.

Os números moram na tabela `planos`, coluna `recursos`. Mudar o teto de 40 é um
`UPDATE`, não um deploy.

### Onde a regra é aplicada

Toda a cobrança passa por `plano_efetivo(salao)`, que responde *"qual plano vale
hoje"* — considerando `trial_ate` e `vence_em`. Fora de vigor, o salão cai no
Grátis; nunca em ilimitado, e nunca em nada.

Três coisas que custaram uma reescrita cada:

**A validade estava só no teste grátis.** Uma assinatura `ativa` com `vence_em`
há dois meses valia o plano inteiro. Quem parasse de pagar ficava com tudo, para
sempre, esperando alguém marcar `inadimplente` na mão — e não havia nada que
marcasse.

**Prender a troca de plano era o lugar errado.** A primeira versão recusava o
rebaixamento enquanto sobrasse gente ativa. Estava errado duas vezes: quem troca
de plano é a plataforma (a policy não deixa o dono escrever em `assinaturas`),
então a trava só atrapalhava cancelamento e fim de contrato; e não pegava o caso
mais comum, porque **teste grátis vence sozinho** — a data passa e não existe
`UPDATE` nenhum para interceptar. O salão seguia com 3 pessoas atendendo num
plano de 1.

A regra certa é sobre **usar** a vaga, não sobre contratá-la: profissional fora
da cota não recebe agendamento (`profissional_na_cota`). Uma regra só cobre
expiração, rebaixamento e chamada direta na API, e a plataforma nunca fica presa.
Quem está na cota são os mais antigos entre os ativos — estável, e na prática
guarda a vaga de quem começou.

**A tela contava diferente do banco.** O `app.html` refaz a conta da cota para
desenhar a agenda e nomear quem ficou de fora. Se as duas divergirem, o dono vê
uma coluna, clica, e leva um erro que contradiz o que está escrito na frente
dele. `tests/cota.test.mjs` roda as duas contas sobre os mesmos dados e compara.

### O que o dono NÃO pode fazer

Provado em `tests/02_rls.test.sql`, com `set role authenticated`:

- escrever na própria assinatura (`permission denied`) — senão assina o plano
  maior em dois cliques
- inventar um plano na tabela `planos`
- passar do limite cadastrando profissional
- marcar na agenda de quem está fora da cota

O botão **Assinar** na tela do dono sabe disso: em modo nuvem ele não finge
trocar o plano. Antes ele mexia no `bd` local e repintava — em demonstração
parecia funcionar, e ligado no Supabase a tela dizia "Time · 3 de 3" enquanto o
banco seguia no Grátis de 1.

## O visual

Uma paleta só, num arquivo só (`estilo.css`), e as três telas herdam dela.
As decisões que sustentam o resto:

- **Neutros quentes, não cinza azulado.** Uma escala de onze degraus faz todo
  o trabalho de fundo, borda e texto.
- **Uma cor de destaque, com significado.** O verde-azulado marca *seleção*:
  o dia escolhido, o horário escolhido, o plano escolhido. Ele nunca é
  decoração.
- **A ação primária é quase preta**, não colorida. Contraste máximo, e sobra
  o destaque para carregar informação. O plano recomendado usa a mesma cor de
  ação — recomendar é empurrar, não é uma escolha já feita.
- **Nada de degradê e nada de emoji.** Emoji cada sistema desenha do seu
  jeito, não aceita cor nem espessura e envelhece junto com a moda do teclado;
  os ícones são SVG traçado de 1,75 (`icones.js`), herdam a cor do texto.
- **Algarismo tabular** em horário, dinheiro e contagem, para as colunas
  alinharem.

Duas coisas saíram no caminho, e vale registrar por quê:

**O tema preto-e-dourado da barbearia.** A ideia era o cliente reconhecer a
casa ao abrir o link. Na prática viraram dois produtos — a mesma pessoa marcava
unha num lugar claro e barba num lugar escuro, com outro botão e outra
tipografia — e o dourado sobre preto derrubava o contraste do texto pequeno.
Quem identifica a casa é o nome, o monograma e a lista de serviços, que é como
Fresha, Booksy e Square resolvem. O vocabulário continua mudando com o tipo do
salão ("quem corta" x "quem atende"); o que saiu foi a segunda paleta.

**A página de cadastro preta.** Mesma história: o dono assinava numa tela preta
e caía num sistema claro no minuto seguinte.

## Dois bugs que os testes pegaram antes de existir tela

Ficam registrados porque são armadilhas que voltam.

**`for all` reabre a leitura restrita.** Uma policy `for all` vale também para
SELECT, e o Postgres soma as permissivas com OU. Uma policy de escrita da
equipe ao lado de uma policy de leitura restrita anula a restrição — a
profissional voltava a ver a agenda das colegas e a comissão delas. Escrita vai
separada por verbo: `for insert`, `for update`, `for delete`.

**Policies que se citam entram em recursão.** A de `comandas` consultava
`comanda_itens`, cuja policy consultava `comandas` de volta:
`infinite recursion detected in policy`. O ciclo se rompe com funções
`security definer`, que não passam pelo RLS.

## O que falta

1. **Cobrança.** Não há como um salão pagar. A troca de plano acontece à mão,
   pelo `admin.html`. É o que separa isto de um negócio.
2. **Entrega do código pelo WhatsApp.** O login por telefone depende do
   *Send SMS Hook* do Supabase apontando para uma Edge Function com a Cloud
   API da Meta. O login por email e senha (o do dono) já funciona.
3. **"Meus horários" da cliente, no modo nuvem.** Ver, cancelar e remarcar
   mexem em dado de alguém, então precisam de prova de identidade — e a
   verificação por código ainda é simulada. Falta a função pública que
   devolva os horários de um telefone JÁ verificado. Enquanto não existe, a
   tela diz isso em vez de mostrar lista vazia: cliente que lê "nenhum
   horário" depois de marcar, marca de novo.
4. **Lista de espera, no modo nuvem.** Mesma história: `lista_espera` não tem
   função pública de escrita, então o botão não é oferecido — em vez de
   gravar num vetor da memória e prometer um aviso que nunca sai.
5. **Lembretes automáticos.** `lembrete_whatsapp: true` nos cinco planos
   pagos, e nada envia. Depende de `pg_cron` e Edge Function.
6. CI com Postgres de serviço, rodando `tests/tudo.sh` a cada envio.
7. Sinal por Pix, pacotes e fidelidade — os campos de sinal já existem na
   tabela `agendamentos`, vazios.

### O que deixou de faltar

- **`agendar.html` no modo nuvem.** O link que o cadastro entrega abre a
  vitrine do banco, mostra os horários que `horarios_livres_periodo()`
  calcula e marca por `agendar()`. Duração e preço saem do banco, nunca do
  navegador. Coberto por `tests/cliente-nuvem.test.mjs`, que vai do cadastro
  da dona até o horário existir na tabela.
- **`horarios_livres()` e `agendar()` no banco**, em `05_agenda.sql`.

## Onde este código vai morar

Hoje ele está numa pasta do repositório `pradotec`, numa branch de trabalho —
não encosta no site que está no ar. É tudo arquivo estático: quando virar
produto, é copiar a pasta para um repositório próprio e apontar o Pages.
