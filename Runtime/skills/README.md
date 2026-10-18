# Habilidades incluídas na app

O `build.sh` copia esta pasta para `runtime/skills/`, junto das habilidades do Studio, e a app copia as ativas para `.claude/skills` e `.agents/skills` de cada site.

## WordPress

Cópia de [WordPress/agent-skills](https://github.com/WordPress/agent-skills), commit `55cd0f78b996f453c194a1a6ecc5c9a2e0f6cf15` (GPL-2.0-or-later, ver `LICENSE`), das habilidades que o Studio não traz.

Alteração local: `wp-performance/scripts/perf_inspect.mjs` corre `wpc wp` em vez de `wp`.

## Design

Sem alterações em relação ao original; só se acrescentou o `LICENSE` de cada projeto.

- `impeccable/`: `.claude/skills/impeccable` de [pbakaus/impeccable](https://github.com/pbakaus/impeccable), commit `2f46b7a8b059af00d20dd13b64dbe165e7c6a742` (Apache-2.0, ver `impeccable/LICENSE` e `impeccable/NOTICE.md`).
- `no-ai-design-slop/`, `audit-ai-design-slop/`, `animation-systems/`: de [MengTo/Skills](https://github.com/MengTo/Skills), commit `398cd41c86ba42fbb30e944ae507f463648f08b7` (MIT, ver o `LICENSE` de cada uma).

O motor do impeccable (`scripts/bin/darwin-arm64/impeccable`) não está no git. O `build.sh` copia-o de `Vendor/impeccable/impeccable`; sem ele o lançador da skill descarregava-o do GitHub. Para o compilar no mesmo commit:

```bash
git clone https://github.com/pbakaus/impeccable && cd impeccable && git checkout 2f46b7a8b059af00d20dd13b64dbe165e7c6a742
SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk | tail -1) cargo build --release -p impeccable
cp target/release/impeccable <wordpressCenter>/Vendor/impeccable/
```

Cada site recebe um `.impeccable/config.json` com `"telemetry": false` e `"updateCheck": false`. O impeccable continua a pedir a impeccable.style as direções de design ("roll") quando cria trabalho novo; o pedido é anónimo e, sem rede, a skill continua sem ele.
