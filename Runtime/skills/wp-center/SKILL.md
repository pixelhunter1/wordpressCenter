---
name: wp-center
description: Fluxo de trabalho de um site WordPress local do WP Center até ao cPanel. Usar quando o utilizador pede para preparar o site para o cPanel ou para produção, exportar ou fazer backup do site, migrar com o WPvivid, resolver erros de colação (utf8mb4_0900) ou da base de dados, ver os emails enviados pelo site ("onde vejo os emails"), arrancar ou parar o site, ou correr comandos WP-CLI.
user-invokable: true
---

# WP Center: do site local ao cPanel

Este site corre no Mac através do WP Center e acaba num servidor cPanel, restaurado com o plugin WPvivid. O `WPCENTER.md` na raiz do site tem o endereço, a base de dados e o uso básico do `wpc`; esta habilidade cobre o resto do fluxo.

## Regras

- WP-CLI é SEMPRE `wpc wp …` (nunca um `wp` do sistema): usa o PHP e a base de dados deste site. Se `wpc --version` falhar, pede ao utilizador para ativar "Comando wpc no terminal" nas Definições do WP Center.
- `wpc status` mostra estado, endereço, login e base de dados. `wpc start` / `wpc stop` arrancam e param o site; `wpc admin` abre o wp-admin com sessão iniciada.
- Fora da pasta do site: `wpc --path <pasta-do-site> …`. `wpc list` lista os sites.
- Antes de mexer: `wpc context` (tema, construtor, plugins ativos, conteúdo, WooCommerce). Para verificar: `wpc login-url` (entrada no wp-admin de uso único para o teu navegador), `wpc screenshot [página]` (PNG da página para veres o resultado; `--width 390` telemóvel, `wp-admin/…` com sessão), `wpc logs` (erros do PHP), `wpc flush` (caches). Site novo: `wpc create "Nome"`. `--json` em `status`, `list`, `context` e `mail`.
- Não escrevas no código URLs `localhost`/`127.0.0.1` nem caminhos absolutos do Mac: no cPanel o domínio e a pasta são outros. Usa `home_url()`, `plugins_url()`, `get_theme_file_uri()`, `__DIR__`.

## Emails

Todos os emails do site (`wp_mail()`) ficam no Mailpit incluído na app: http://127.0.0.1:8025. Nada sai para a internet. O Mailpit arranca com o site; se a página não abrir, `wpc start`. No terminal: `wpc mail` lista os últimos e `wpc mail <ID>` mostra um.

## Base de dados

- Cada site com MySQL/MariaDB tem a sua base de dados e utilizador no formato do cPanel (`wpc_xxxxxxxxxx`, até 32 caracteres), com palavra-passe própria. É diferente do login do WordPress: não confundas os dois.
- O `wp-config.php` local é gerado pelo WP Center (`WP_ENVIRONMENT_TYPE` = `local`). Não o copies para o servidor nem dependas dele: o restore do WPvivid mantém o `wp-config.php` e o `db.php` do cPanel.
- Sites SQLite servem só para testes rápidos; para migrar, o site deve usar MySQL ou MariaDB.

## Versões no cPanel (cPanel & WHM 136+)

| Sistema | MySQL | MariaDB |
|---|---|---|
| AlmaLinux / CloudLinux 8 e 9 | 8.0, 8.4 | 10.5, 10.6, 10.11, 11.4, 11.8 |
| AlmaLinux / CloudLinux 10 | 8.4 | 10.11, 11.4, 11.8 |
| Ubuntu 24 | 8.0, 8.4 | 10.11, 11.4, 11.8 |

Cada servidor usa MySQL ou MariaDB, nunca os dois. Sem personalização o cPanel instala o MariaDB 10.11. Não uses funcionalidades SQL que a versão do servidor de destino não tenha.

## Preparar e exportar para o cPanel

1. Atualizações: o `wp-config.php` local desliga as automáticas (`AUTOMATIC_UPDATER_DISABLED`), por isso faz-as à mão e testa antes de exportar (`wpc wp core update`, `wpc wp plugin update --all`, `wpc wp theme update --all`).
2. O plugin WPvivid tem de estar instalado e ativo no site: `wpc wp plugin install wpvivid-backuprestore --activate`. Convém ter a mesma versão que no cPanel.
3. Exporta com `wpc export` (ou o botão Exportar da app). O backup vai para as Descargas, ou para a pasta escolhida nas Definições.
4. Colações: o MySQL 8 cria tabelas `utf8mb4_0900_*`, que o MariaDB do cPanel recusa. Se o `wpc export` parar por isso:
   - `wpc export --convert` converte para `utf8mb4_unicode_ci` (recomendado);
   - `wpc export --no-convert` só se o cPanel de destino usar MySQL 8.
5. No cPanel: WPvivid → Backup & Restore → Upload → Restore. Se as páginas derem 404 depois do restore, guarda de novo as ligações permanentes.

Fica de fora do backup, por só fazer sentido no Mac:
- `wp-content/database/`, `mu-plugins/sqlite-database-integration/`, `mu-plugins/99-studio-loader.php` e o `db.php` do SQLite (restos do Studio);
- `mu-plugins/dev-*` e `mu-plugins/wpcenter-*` (ferramentas locais: entrada automática, envio para o Mailpit);
- `AGENTS.md`, `CLAUDE.md`, `WPCENTER.md` e `STUDIO.md` na raiz do site.

Código que tenha de existir em produção não pode viver nesses caminhos: um mu-plugin chamado `dev-…` ou `wpcenter-…` não chega ao cPanel.
