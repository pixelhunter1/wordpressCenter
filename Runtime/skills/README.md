# Habilidades incluídas na app

O `build.sh` copia esta pasta para `runtime/skills/`, e a app copia as ativas para `.claude/skills` e
`.agents/skills` de cada site. O catálogo (nome, título e resumo de cada uma) vive em `AgentSkill.all`, no
`Sources/WPCenter/Engine.swift`; aqui só vive o conteúdo.

## De onde vêm

O `upstreams.json` é a única fonte dos pins: repositório, commit fixado e a pasta de cada skill em cada
repositório. Uma skill que não esteja listada ali não entra — o catálogo é uma escolha nossa, não o repositório
todo (as skills de blocos e a `visual-design` do Studio foram retiradas de propósito).

| Upstream | Skills | Licença |
|---|---|---|
| [WordPress/agent-skills](https://github.com/WordPress/agent-skills) | `wordpress-router`, `wp-project-triage`, `wp-plugin-development`, `wp-rest-api`, `wp-wpcli-and-ops`, `wp-performance`, `wp-phpstan` | GPL-2.0-or-later |
| [Automattic/studio](https://github.com/Automattic/studio) (`packages/agent/node/skills`) | `need-for-speed`, `rank-me-up` | GPL-2.0-or-later |
| [MengTo/Skills](https://github.com/MengTo/Skills) | `no-ai-design-slop`, `audit-ai-design-slop`, `animation-systems` | MIT |
| [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | `impeccable` + o motor | Apache-2.0 |

Cada pasta leva a licença do seu upstream; o `LICENSE` na raiz desta pasta é o do WordPress/agent-skills.
`wp-center` é nossa e vive aqui diretamente.

## Atualizar

Duas formas, com as mesmas regras:

- **Na app**: Definições → Habilidades → *Procurar atualizações no GitHub…*. Mostra, por upstream, o commit em que está
  e aquele para onde iria, e o que muda em cada skill; só aplica quando confirmas. O que traz fica em
  `~/Library/Application Support/WP Center/skills/` (o pacote é assinado e só de leitura) e ganha ao pacote enquanto for
  mais recente do que o build. Só texto: o motor do impeccable continua a vir no build, e a app avisa quando a skill
  nova pede um motor mais recente. É a única ligação à rede que a app faz por si — e só nesse clique.
- **No terminal**:

```bash
./Scripts/update-skills.sh --check   # mostra o que mudaria, sem escrever nada
./Scripts/update-skills.sh           # traz o HEAD de cada upstream, copia e fixa os commits
```

O script descarrega o tarball de cada commit (`codeload.github.com`, sem clone e sem histórico), substitui só as
pastas do manifesto, copia a licença do upstream para dentro de cada pasta e grava os commits novos no
`upstreams.json`. Depois:

1. **Rever o `git diff`.** São instruções que os agentes seguem: um `CRITICAL` novo, uma regra que desapareceu ou
   uma ferramenta que passou a pedir rede contam.
2. **Correr `./build.sh`.** Os patches locais (abaixo) são aplicados aqui e o build **falha** se um deles perdeu o
   alvo — uma skill meio corrigida é pior do que um build que para.
3. Commitar as pastas e o `upstreams.json` juntos.

A app nunca vai à rede: quem descarrega é este script, à mão. Para recuar para um commit anterior basta mudar o
`ref` no manifesto e voltar a correr o script.

## Patches locais

As cópias nesta pasta são iguais às do upstream — o diff de uma atualização é só o que veio de lá. O que é nosso vive
em `patches.json`, e é aplicado em dois sítios a partir deste mesmo ficheiro: pelo `build.sh` (com o
`Scripts/patch-skill.pl`, substituição de texto exata que falha se o alvo não existir) e pela app, depois de trazer
uma versão nova. Aplicar duas vezes não estraga nada.

- `wp-performance/scripts/perf_inspect.mjs` — corre `wpc wp` em vez de `wp`, porque o WP-CLI do site é o da app.
- `rank-me-up/SKILL.md` — tira a nota "auto-submitted to WordPress.com" e troca a frase sobre o Studio por uma
  sobre a WP Center e a migração para cPanel.

## O motor do impeccable

A skill é texto; o trabalho pesado é um binário Rust (`scripts/bin/darwin-arm64/impeccable`) que o upstream publica
por versão de motor, emparelhado com o texto (`scripts/VERSION`). O binário **não está no git**: o
`Scripts/update-skills.sh` descarrega o `engine-v<versão>` da release, confere o `.sha256` publicado e instala-o
em `Vendor/impeccable/impeccable`; o `build.sh` copia-o para dentro da app. Sem ele, o lançador da skill iria
buscá-lo ao GitHub em cada site — o que a app não faz.

Cada site recebe `.impeccable/config.json` com `"telemetry": false` e `"updateCheck": false`. O
impeccable continua a pedir a impeccable.style as direções de design ("roll") quando cria trabalho novo; o pedido é
anónimo e, sem rede, a skill continua sem ele.

## Dentro dos sites

Cada pasta copiada leva um `.wpcenter-version` com o digest do conteúdo que a app lá pôs. A cada sincronização
(criar o site, ligar/desligar uma habilidade) a app compara esse carimbo com o do pacote e só substitui o que
mudou. Se o conteúdo da pasta já não for o que ela escreveu — uma edição tua — a versão antiga fica em
`.wpcenter/skills-anteriores/<nome>`, fora da pasta de skills para não haver duas versões da mesma habilidade.
Skills que tu metas no site e não estejam no catálogo nunca são tocadas.
