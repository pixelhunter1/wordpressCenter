#!/bin/zsh
# Traz as skills de agente do GitHub para Runtime/skills e fixa o commit de cada upstream no
# Runtime/skills/upstreams.json. Corre-se à mão, quando se quer: a app nunca vai à rede.
#
#   Scripts/update-skills.sh            # traz o HEAD de cada upstream, copia e sobe os commits
#   Scripts/update-skills.sh --check    # só mostra o que mudaria (descarrega para uma pasta temporária)
#
# Depois de correr: rever `git diff` (são instruções que os agentes seguem), correr ./build.sh — que
# falha se um patch local perdeu o alvo — e só então commitar.
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST=Runtime/skills/upstreams.json
DEST=Runtime/skills
CHECK=0
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
  print -u2 "Utilização: Scripts/update-skills.sh [--check]"; exit 2
fi
[[ "${1:-}" == "--check" ]] && CHECK=1

command -v /usr/bin/python3 >/dev/null || { print -u2 "Falta o python3 (vem com as Command Line Tools do Xcode)."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { print -u2 "✗ $1"; exit 1 }

# Consultas ao manifesto. É JSON: lê-se com o python3 em vez de partir texto à mão.
#   skills  → upstream<TAB>repo<TAB>ref<TAB>id<TAB>pasta   (uma linha por skill)
#   engines → upstream<TAB>repo<TAB>id<TAB>asset<TAB>install
#   set_pins <upstream>=<ref> … [<upstream>:engine=<versão>] → grava os pins
manifest() {
  /usr/bin/python3 - "$MANIFEST" "$@" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
ups = doc["upstreams"]
what = sys.argv[2] if len(sys.argv) > 2 else "skills"
if what == "skills":
    for key, up in ups.items():
        for s in up["skills"]:
            print("\t".join([key, up["repo"], up["ref"], s["id"], s["path"]]))
elif what == "engines":
    for key, up in ups.items():
        if "engine" in up:
            skill = next(s["id"] for s in up["skills"] if s.get("engine"))
            print("\t".join([key, up["repo"], skill, up["engine"]["asset"], up["engine"]["install"]]))
elif what == "set_pins":
    for item in sys.argv[3:]:
        name, value = item.split("=", 1)
        if name.endswith(":engine"):
            ups[name[:-len(":engine")]]["engine"]["version"] = value
        else:
            ups[name]["ref"] = value
    with open(path, "w") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
PY
}

# 1. O commit de cada upstream: um HEAD por repositório, não por skill.
typeset -A head key_of repo_of
while IFS=$'\t' read -r key repo ref id where; do
  repo_of[$key]=$repo
  [[ -n "${head[$repo]:-}" ]] && continue
  head[$repo]=$(git ls-remote "https://github.com/$repo" HEAD | cut -f1)
  [[ -n "${head[$repo]}" ]] || fail "não consegui ler o HEAD de $repo (sem rede?)"
  key_of[$repo]=$key
  [[ "$CHECK" == 1 ]] && print "$key  ${ref[1,7]} → ${head[$repo][1,7]}  ($repo)"
done < <(manifest skills)

# 2. Descarregar tudo primeiro: um upstream em baixo não deixa as pastas a meio caminho.
#    Um tarball por commit, não um clone: o resultado só depende do commit.
typeset -A src
while IFS=$'\t' read -r key repo ref id where; do
  sha=${head[$repo]}
  [[ -n "${src[$sha]:-}" ]] && continue
  curl -fsSL --retry 2 "https://codeload.github.com/$repo/tar.gz/$sha" -o "$tmp/$sha.tgz" \
    || fail "não consegui descarregar $repo@${sha[1,7]}"
  mkdir -p "$tmp/$sha"
  tar -xzf "$tmp/$sha.tgz" -C "$tmp/$sha" --strip-components 1 || fail "tarball inválido de $repo"
  src[$sha]="$tmp/$sha"
done < <(manifest skills)

# 3. Copiar as pastas listadas — e só essas: o catálogo é uma escolha nossa, não o repositório todo.
count=0
while IFS=$'\t' read -r key repo ref id where; do
  from="${src[${head[$repo]}]}/$where"
  [[ -d "$from" ]] || fail "$repo já não tem $where (mudou de sítio? corrija o manifesto)"
  if [[ "$CHECK" == 1 ]]; then
    if [[ ! -d "$DEST/$id" ]]; then
      print "  + $id  (novo)"
    elif diff -rq -x LICENSE -x NOTICE.md "$DEST/$id" "$from" >/dev/null 2>&1; then
      print "  = $id"
    else
      print "  ↑ $id  ($(diff -rq -x LICENSE -x NOTICE.md "$DEST/$id" "$from" 2>/dev/null | wc -l | tr -d ' ') ficheiros diferentes)"
    fi
    continue
  fi
  rm -rf "$DEST/$id"
  cp -R "$from" "$DEST/$id"
  # Atribuição: estas skills são redistribuídas dentro da app, por isso cada pasta leva a licença (e o NOTICE,
  # quando o upstream tem um) — mesmo quando o upstream os guarda só na raiz do repositório.
  for legal in LICENSE NOTICE.md; do
    if [[ ! -f "$DEST/$id/$legal" && -f "${src[${head[$repo]}]}/$legal" ]]; then
      cp "${src[${head[$repo]}]}/$legal" "$DEST/$id/$legal"
    fi
  done
  count=$((count + 1))
done < <(manifest skills)

if [[ "$CHECK" == 1 ]]; then
  print "\n--check: nada foi escrito. Sem --check, o manifesto sobe para estes commits."
  exit 0
fi

# 4. O motor do impeccable é um binário, emparelhado com a versão do texto (scripts/VERSION).
#    A skill traz a lista de digests dos motores publicados (engine-checksums.txt, desde a 4.8.0): é essa a
#    referência, e não o .sha256 que vem ao lado do ficheiro — o sidecar só serve de recurso nas versões antigas.
typeset -A engine_version
while IFS=$'\t' read -r key repo id asset install_dir; do
  version=$(<"$DEST/$id/scripts/VERSION") || fail "$id não traz scripts/VERSION"
  base="https://github.com/$repo/releases/download/engine-v$version"
  curl -fsSL --retry 2 "$base/$asset" -o "$tmp/engine" || fail "não há $asset para o motor $version"
  expected=""
  if [[ -f "$DEST/$id/scripts/engine-checksums.txt" ]]; then
    expected=$(awk -v v="$version" -v a="$asset" '$1 == v && $2 == a { print $3 }' "$DEST/$id/scripts/engine-checksums.txt")
  fi
  if [[ -z "$expected" ]]; then
    curl -fsSL --retry 2 "$base/$asset.sha256" -o "$tmp/engine.sha256" || fail "o motor $version não traz .sha256"
    expected=$(cut -d' ' -f1 < "$tmp/engine.sha256")
  fi
  actual=$(shasum -a 256 "$tmp/engine" | cut -d' ' -f1)
  [[ "$expected" == "$actual" ]] || fail "o motor $version não confere com o digest publicado"
  install -d "$install_dir"
  install -m 755 "$tmp/engine" "$install_dir/impeccable"
  engine_version[$key]=$version
  print "  motor $id: $version → $install_dir/impeccable"
done < <(manifest engines)

# 5. Fixar os commits (e a versão do motor) no manifesto: é o que reproduz isto daqui a meses.
pins=()
for repo in ${(k)head}; do pins+=("${key_of[$repo]}=${head[$repo]}"); done
for key in ${(k)engine_version}; do pins+=("${key}:engine=${engine_version[$key]}"); done
manifest set_pins $pins

print "\n✓ $count pastas de skills atualizadas."
git --no-pager diff --stat -- Runtime/skills
print "A seguir: rever o diff, correr ./build.sh (falha se um patch local perdeu o alvo) e commitar."
