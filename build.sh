#!/bin/zsh
# Compila o WP Center e monta dist/WP Center.app.
# O runtime (PHP nativo, WordPress, plugin SQLite, WP-CLI) vem de Vendor/studio (fora do git), uma cópia das peças do Studio — tudo local, nada é descarregado.
# Para atualizar: instalar o Studio e correr com STUDIO=/Applications/Studio.app/Contents/Resources, ou voltar a copiar as mesmas pastas para Vendor/studio.
set -euo pipefail
cd "${0:A:h}"

STUDIO="${STUDIO:-Vendor/studio}"
APP="dist/WP Center.app"
# ponytail: o Swift 6.3 das Command Line Tools não compila contra o SDK 27; usa o SDK 26 mais recente. Remover quando as CLT forem atualizadas.
export SDKROOT="${SDKROOT:-$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)}"

[[ -d "$STUDIO/cli/wp-files" ]] || { echo "Runtime não encontrado em $STUDIO (copie as peças do Studio para Vendor/studio ou defina STUDIO=…)"; exit 1; }
PHP_DIR=$(ls -d "$STUDIO"/php-bin/*/ | sort -V | tail -1)
# Mailpit (MIT, um só executável sem dependências): vai dentro da app, quem a usa não instala nada.
MAILPIT="${MAILPIT:-$(command -v mailpit || true)}"
[[ -x "$MAILPIT" ]] || { echo "Mailpit não encontrado: brew install mailpit (ou defina MAILPIT=…)"; exit 1; }
# cloudflared (Apache-2.0): links de partilha temporários (Cloudflare Quick Tunnel), também dentro da app.
CLOUDFLARED="${CLOUDFLARED:-$(command -v cloudflared || true)}"
[[ -x "$CLOUDFLARED" ]] || { echo "cloudflared não encontrado: brew install cloudflared (ou defina CLOUDFLARED=…)"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
# swiftc direto: o `swift build` das Command Line Tools atuais falha ao carregar o SwiftPM.
LOCSTR=$(mktemp -d) # textos traduzíveis encontrados pelo compilador (chaves em pt-PT)
swiftc -O -parse-as-library -target arm64-apple-macos14.0 Sources/WPCenter/*.swift -o "$APP/Contents/MacOS/WPCenter" \
  -emit-localized-strings -emit-localized-strings-path "$LOCSTR"

# Línguas: pt-PT e pt (as chaves já são o texto; pt-PT faz o macOS usar os seus textos de Portugal, não do Brasil)
# e en, para qualquer outra língua do Mac.
cp -R Localization/*.lproj "$APP/Contents/Resources/"
# Aviso de textos sem tradução: num Mac noutra língua apareceriam em português.
python3 - "$LOCSTR" Localization/en.lproj/Localizable.strings <<'PY'
import glob, json, subprocess, sys
keys = {e["key"] for f in glob.glob(sys.argv[1] + "/*.stringsdata")
        for e in json.load(open(f))["tables"].get("Localizable", [])}
en = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", sys.argv[2]], capture_output=True, check=True).stdout)
for k in sorted(keys - en.keys()):
    print("Sem tradução em inglês:", json.dumps(k, ensure_ascii=False))
PY

R="$APP/Contents/Resources/runtime"
cp -R "$PHP_DIR" "$R/php"
cp -R "$STUDIO/cli/wp-files/latest/wordpress" "$R/wordpress"
cp -R "$STUDIO/cli/wp-files/sqlite-database-integration" "$R/sqlite-database-integration"
cp "$STUDIO/cli/wp-files/wp-cli/wp-cli.phar" "$R/wp-cli.phar"
cp Runtime/router.php Runtime/db-check.php Runtime/wpvivid-export.php Runtime/wpcenter-access.php Runtime/wpcenter-autologin.php Runtime/wpcenter-collation.php Runtime/wpcenter-mail.php Runtime/wpcenter-share.php Runtime/wpcenter-updates.php "$R/"
cp "$MAILPIT" "$R/mailpit" && chmod u+w "$R/mailpit"
cp "$CLOUDFLARED" "$R/cloudflared" && chmod u+w "$R/cloudflared"

# Skills para agentes de IA: só as que não dependem de ferramentas do Studio nem do WordPress.com.
mkdir -p "$R/skills"
for s in need-for-speed rank-me-up visual-design; do cp -R "$STUDIO/cli/skills/$s" "$R/skills/"; done
# Habilidades de WordPress (WordPress/agent-skills, GPL). A studio-cli fica de fora: o WPCENTER.md ensina o `wpc`.
for s in wp-plugin-development wp-block-development wp-block-themes wp-rest-api wp-wpcli-and-ops; do
  cp -R "$STUDIO/cli/wp-files/skills/$s" "$R/skills/"
done
# A wp-center (nossa) e as do WordPress/agent-skills que o Studio não traz vivem no repositório (Runtime/skills/README.md).
cp -R Runtime/skills/. "$R/skills/"
sed -i '' -e 's/ (auto-submitted to WordPress.com)//' \
  -e 's/local Studio site, so this is purely about preparing the site for production\..*/local WP Center site, so this is purely about preparing the site for production (migrated to cPanel with WPvivid)./' \
  "$R/skills/rank-me-up/SKILL.md"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift Assets/logo.svg "$ICONSET/base.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Assets/logo.svg "$APP/Contents/Resources/logo.svg" # logo usado dentro da app

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>WP Center</string>
	<key>CFBundleDisplayName</key><string>WP Center</string>
	<key>CFBundleIdentifier</key><string>local.wpcenter</string>
	<key>CFBundleExecutable</key><string>WPCenter</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>pt</string><string>pt-PT</string></array>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Pronto: $APP"
