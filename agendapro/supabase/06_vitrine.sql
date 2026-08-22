-- ===========================================================================
-- AgendaPro — 06: a vitrine de UM salão
--
-- ── O PROBLEMA QUE ESTE ARQUIVO FECHA ──────────────────────────────────────
-- As vistas `saloes_publicos`, `servicos_publicos` e `profissionais_publicos`
-- estavam liberadas para `anon` sem nenhum filtro. Funcionava, e o isolamento
-- entre donos continuava intacto: nenhum salão lia agendamento, cliente ou
-- faturamento de outro — isso o RLS garante e os testes provam.
--
-- Mas havia outra coisa vazando, e não é dado de cliente: é a SUA LISTA DE
-- CLIENTES. Qualquer pessoa com a chave publicável — que fica à vista no
-- código da página, de propósito — pedia
--
--     GET /rest/v1/saloes_publicos
--
-- e recebia TODOS os salões da plataforma, com nome, endereço e WhatsApp. Um
-- concorrente monta com isso uma lista de prospecção pronta: exatamente quem
-- usa o AgendaPro, onde fica e por onde falar. Você levou meses para reunir
-- essa lista; ela sai numa requisição.
--
-- ── O QUE MUDA ─────────────────────────────────────────────────────────────
-- A cliente chega por um link com o apelido do salão. Ela NUNCA precisa de um
-- catálogo — precisa de um salão, o dela. Então o catálogo deixa de existir
-- para quem não fez login, e no lugar entra esta função, que só responde
-- quando alguém já sabe o apelido.
--
-- Isso não torna o apelido secreto: quem tem o link tem o salão, e é assim
-- que deve ser. O que muda é que ninguém mais ENUMERA. Descobrir um salão
-- passa a exigir já conhecê-lo.
--
-- Vem tudo de uma vez — salão, serviços e profissionais — em vez de três
-- idas ao servidor. No 3G da cliente, isso é a diferença entre a tela abrir
-- e a tela demorar.
-- ===========================================================================

create or replace function public.vitrine(p_slug text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'salao', jsonb_build_object(
      'id', s.id, 'slug', s.slug, 'nome', s.nome, 'tipo', s.tipo,
      'logo', s.logo, 'capa', s.capa,
      'telefone', s.telefone, 'whatsapp', s.whatsapp,
      'endereco', s.endereco, 'fuso', s.fuso,
      -- A tela precisa saber até quando desenhar o calendário. Sai daqui
      -- pronto, já com o limite aplicado, para a tela não ter que repetir a
      -- regra — e não ter como discordar dela.
      'diasLiberados', public.dias_liberados(s.id),

      /* ── A APARÊNCIA QUE O SALÃO ESCOLHEU ──────────────────────────────
         Só as três chaves visuais, nomeadas uma a uma — nunca o `cfg`
         inteiro. `cfg` é jsonb e vai crescer; devolvê-lo por atacado
         significa publicar para qualquer visitante toda configuração que
         alguém puser lá no futuro, sem ninguém decidir isso. Chave nova só
         aparece aqui se for escrita aqui, de propósito.

         Nulo quer dizer "não escolheu", e a tela usa o padrão dela — assim
         salão antigo, criado antes disto existir, continua bonito sem
         precisar de migração. */
      'cor',  s.cfg->>'cor',
      'tema', s.cfg->>'tema',
      'precoNaCapa', coalesce((s.cfg->>'precoNaCapa')::boolean, false),
      -- A imagem de fundo da página, que o dono anexa em Identidade visual.
      -- Mora no `cfg` e não numa coluna própria de propósito: `cfg` é jsonb
      -- e já existe, então nenhum salão precisa de migração de tabela.
      'fundo', s.cfg->>'fundo',
      -- O brilho do botão principal. Ausente quer dizer LIGADO: é o padrão, e
      -- assim salão criado antes disto existir já nasce com ele.
      'brilho', coalesce((s.cfg->>'brilho')::boolean, true),
      -- A letra do nome na capa. Nulo = a tela decide pelo tipo do negócio.
      'letra', s.cfg->>'letra',
      /* De onde sai o slide da capa: 'servicos' (as fotos dos serviços) ou
         'galeria' (as mídias que o dono subiu). E a galeria em si — uma
         lista de {url, tipo, legenda}. Vem nomeada, como todo o resto: o
         `cfg` inteiro nunca é devolvido. */
      'slideDe', s.cfg->>'slideDe',
      'galeria', coalesce(s.cfg->'galeria', '[]'::jsonb),
      -- Enquadramento da foto de capa (0 = topo à vista, 100 = pé) e quanto
      -- da imagem de fundo aparece por baixo do véu. Nulo = o padrão da tela.
      'capaFoco', (s.cfg->>'capaFoco')::int,
      'veu', (s.cfg->>'veu')::int
    ),

    'servicos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'nome', v.nome, 'categoria', v.categoria,
               'descricao', v.descricao, 'duracaoMin', v.duracao_min,
               'preco', v.preco, 'foto', v.foto)
             order by v.categoria nulls last, v.nome)
        from public.servicos v
       where v.salao_id = s.id and v.ativo and v.aceita_online), '[]'::jsonb),

    'profissionais', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'nome', coalesce(p.apelido, p.nome),
               'foto', p.foto,
               -- Lista vazia = faz tudo. É como um salão pequeno começa, e a
               -- tela já trata assim.
               'servicos', (select coalesce(jsonb_agg(sp.servico_id), '[]'::jsonb)
                              from public.servicos_profissionais sp
                             where sp.profissional_id = p.id))
             order by p.criado_em, p.id)
        from public.profissionais p
       where p.salao_id = s.id and p.ativo and p.aceita_online
         -- A cota do plano vale aqui também: profissional fora da cota não
         -- pode aparecer como opção, senão a cliente escolhe e leva um erro
         -- do gatilho na cara ao confirmar.
         and public.profissional_na_cota(p.id)), '[]'::jsonb)
  )
  from public.saloes s
  where s.slug = p_slug and s.status = 'ativo'
$$;

-- ---------------------------------------------------------------------------
-- Fechar o catálogo
--
-- As vistas continuam existindo — o painel do dono e relatórios futuros usam
-- —, mas param de ser alcançáveis por quem não fez login. E também por quem
-- fez: criar conta leva dois minutos, então deixar aberto para
-- `authenticated` seria a mesma porta com um degrau na frente.
-- ---------------------------------------------------------------------------
revoke all on public.saloes_publicos        from anon, authenticated;
revoke all on public.servicos_publicos      from anon, authenticated;
revoke all on public.profissionais_publicos from anon, authenticated;

revoke all on function public.vitrine(text) from public;
grant execute on function public.vitrine(text) to anon, authenticated;
