---
id: agent-files
type: module-design
status: draft
title: Per-site agent files and skills
parent: architecture
depends-on: [cli]
---

# Per-site agent files and skills

## Responsibility

Make every site a place where an AI agent can work correctly without being told: the instructions, the pointer to
`wpc`, and the skills worth loading.

## Decisions

- **The site's own files are written only when missing.** `AGENTS.md` (the real text), `CLAUDE.md` (one line,
  `@AGENTS.md`) and the skill folders are created when a site is created; the first two are never overwritten, because
  the user may edit them and those edits must survive.
- **`WPCENTER.md` belongs to the app and is rewritten whenever its text changes**, because it carries what the app
  knows and the user does not watch changing — the site's current port after an import or duplicate, the database
  and its credentials, and the current `wpc` commands.
- **They point at `wpc`, never at a system `wp`**: the site's PHP and database are the app's, and a system WP-CLI
  would talk to another database.
- **Skills come from a pinned manifest and are updated, not just installed.** `Runtime/skills/upstreams.json` records,
  per upstream, the repository, the commit and the folder of each skill; `Scripts/update-skills.sh` — run by the
  developer — fetches that commit's tarball and replaces the copies, and the app's *Procurar atualizações* button
  (Definições → Habilidades) does the same thing for the user: it resolves each upstream's latest commit through the
  GitHub API, shows what would change, and only copies when confirmed. The catalogue (which skills we ship at all) is
  ours: a skill absent from the manifest never enters, whatever the upstream offers.
- **Two sources, and the newer one wins.** The bundle (`Resources/runtime/skills/`, stamped with the build's date) is
  the baseline; what the button brings lives in `~/Library/Application Support/WP Center/skills/` (stamped with the
  fetch date), because the app is signed and its bundle is read-only. The app resolves each skill from whichever is
  newer, and a build that supersedes the fetched copy discards it instead of leaving it to rot.
- **Our patches are one list, applied twice.** `Runtime/skills/patches.json` holds the corrections that are ours (the
  `wpc wp` call in `perf_inspect.mjs`, the Studio wording in `rank-me-up`); the build applies them to the bundle and
  the app applies them to whatever it has just fetched — so an in-app update cannot silently undo them. Applying twice
  is harmless, and a rule whose target has disappeared is an error, not a warning.
- **A correction never deletes text without an anchor.** One update applies every rule twice (`check()` corrects the
  copy it fetched so the comparison is fair, `apply()` corrects what it copied), and the only proof that a rule has
  already run is its `replace` text being there. A rule that removed a phrase therefore writes the phrase's
  surroundings into `find` and leaves the rest as `replace` — `rank-me-up` turns
  "at `/sitemap.xml` (auto-submitted to WordPress.com)" into "at `/sitemap.xml`". A rule with an empty `replace` is
  refused by `Scripts/patch-skill.pl` (so the build fails) and by `--selftest` (`selftest`).
- **The engine is text-only territory.** The impeccable skill's compiled engine ships with the build; the button
  never fetches a binary, and a fetched copy of that skill inherits `scripts/bin` from the bundle, so an update
  cannot leave a site without an engine. When a fetched skill asks for a newer engine than the app carries, the
  update says so instead of letting the skill's newer verbs fail later.
- **A patch names its skill.** Each rule in `patches.json` carries the skill id and a path relative to that skill's
  folder, so the same rule serves the bundle, the copy fetched from GitHub (which sits at another depth in the
  tarball) and the folder in a site. Without that, a rule silently applied nowhere.
- **A copy in a site carries a stamp.** Each installed skill gets `.wpcenter-version` with the digest of what was put
  there; on every sync (site creation, a skill toggled, an update applied) a skill whose stamp matches the source is
  left alone and one that does not is replaced. If the folder's content is no longer what the app wrote — the user
  edited it — the old version is kept in `.wpcenter/skills-anteriores/<id>`, outside the skills folder so an agent
  never loads two versions of the same skill. Skills that are not in the catalogue are never touched; turning one off
  removes it everywhere and retired ids are deleted.
- **The provenance of each skill is in `Runtime/skills/README.md`** (upstream table, licences, local patches and the
  update loop), with the pins themselves only in the manifest.
- **Design skills travel with the site.** Any visual work is told to load `impeccable` and the AI-slop filters
  without being asked, so a local site can look made on purpose.
- **The impeccable engine is bundled, not fetched by the skill**: its launcher would otherwise download the engine
  from GitHub, which the app never does. The engine binary is a build input, brought in by the same update script
  (`build`). Each site also gets `.impeccable/config.json` with telemetry and update checks off.
- **These files never go to a server** — the cPanel export leaves them out, together with `.wpcenter/` (`transfer`),
  because an `AGENTS.md` aimed at a local app is wrong on the host.

## Boundary

Written by `site-lifecycle` when a site is created, imported or (re)started — a start is what brings an older
site up to date — and by the skills updater for every site at once; depends on `cli` for the commands it documents
and on `build` for the skill folders. Renaming a site does not rewrite them (`rename` only changes the name in
WordPress and in `sites.json`). Nothing reads them back.
