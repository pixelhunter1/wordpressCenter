import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "wpc" {
            // Como `wpc` o processo não tem o identificador da app: lê as mesmas preferências que ela.
            UserDefaults.standard.addSuite(named: "local.wpcenter")
            Task { @MainActor in exit(await CLI.run()) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in exit(await SelfTest.run() ? 0 : 1) }
            dispatchMain()
        }
        WPCenterApp.main()
    }
}

struct WPCenterApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var store = SiteStore.shared
    @AppStorage(Prefs.showMenuBarKey) private var showMenuBar = false

    var body: some Scene {
        WindowGroup("WP Center", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                MainWindowButton(title: "Novo site…", request: .newSite).keyboardShortcut("n")
                MainWindowButton(title: "Importar site…", request: .importSites)
            }
            CommandGroup(replacing: .appSettings) { MainWindowButton(title: "Definições…", request: .settings).keyboardShortcut(",") }
            SiteCommands()
            CommandGroup(replacing: .help) { MainWindowButton(title: "Versões de bases de dados do cPanel", request: .cpanel) }
        }

        MenuBarExtra("WP Center", systemImage: "globe", isInserted: $showMenuBar) {
            MenuBarContent().environmentObject(store)
        }
    }
}

/// Menu na barra de menus: estado de cada site e ações rápidas.
private struct MenuBarContent: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.sites.isEmpty {
            Text("Ainda não há sites")
        }
        ForEach(store.sites) { site in
            let running = store.isRunning(site)
            Menu {
                if running {
                    Button("Parar") { store.stop(site) }
                } else {
                    Button("Iniciar") { Task { await store.start(site) } }
                }
                Button("Abrir site") { Prefs.openInBrowser(site.url) }
                Button("Abrir WP Admin") { Task { await store.openAdmin(site) } }
                ShareMenuItems(site: site)
                Button("Abrir no editor") { Prefs.openInEditor(site.folder) }
            } label: {
                let state = running ? L("a correr") : L("parado")
                Label(store.shares[site.id] != nil ? L("\(site.name)  ·  \(state)  ·  partilhado") : "\(site.name)  ·  \(state)",
                      systemImage: running ? "circle.fill" : "circle")
            }
        }
        Divider()
        Button("Ver emails (Mailpit)") { Task { await store.openMail() } }
        Button("Abrir o WP Center") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        MainWindowButton(title: "Definições…", request: .settings).keyboardShortcut(",")
        Divider()
        Button("Sair do WP Center") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Com o ícone na barra de menus, fechar a janela não fecha a app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Prefs.showsMenuBar }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await SiteStore.shared.applyLaunchBehavior() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SiteStore.shared.prepareToQuit() }
    }
}

/// `WP Center.app/Contents/MacOS/WPCenter --selftest` — percorre o caminho real de ponta a ponta numa pasta temporária.
@MainActor
enum SelfTest {
    static func run() async -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "✓" : "✗", label)
            if !ok { failures += 1 }
        }

        // Catálogo: as versões do seletor têm de ser exatamente a união da tabela do cPanel.
        let mysql = Set(CPanelSupportRow.all.flatMap(\.mysql)), maria = Set(CPanelSupportRow.all.flatMap(\.mariadb))
        check(mysql == Set(DatabaseEngine.mysql.cpanelVersions), "versões MySQL = tabela cPanel")
        check(maria == Set(DatabaseEngine.mariadb.cpanelVersions), "versões MariaDB = tabela cPanel")
        check(DatabaseConfig.isValidIdentifier("cpuser_wp1") && !DatabaseConfig.isValidIdentifier("x`; DROP"), "validação do nome da BD")
        check(SiteStore.slug("Olá Mundo!") == "ola-mundo", "slug da pasta")
        // Sites guardados antes da escolha de PHP (sem phpVersion) usam o PHP incluído na app.
        let legacy = Site(name: "x", path: "/tmp/x", port: 1, adminPassword: "p", wpVersion: "7", database: DatabaseConfig())
        var legacyJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        legacyJSON["phpVersion"] = nil
        let decoded = try? JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(decoded?.php == PHPVersions.bundled && (try? decoded?.phpExecutable()) == Runtime.php,
              "site antigo sem versão de PHP usa o PHP incluído")
        check(AgentSkill.all.allSatisfy { FileManager.default.fileExists(atPath: Runtime.skills.appendingPathComponent("\($0.id)/SKILL.md").path) },
              "todas as habilidades do catálogo vêm na app")
        let ident = SiteStore.cpanelStyleIdentifier(), pass = SiteStore.strongPassword()
        check(ident.hasPrefix("wpc_") && ident.count <= 32 && DatabaseConfig.isValidIdentifier(ident)
              && ident.filter { $0 == "_" }.count == 1 && ident != SiteStore.cpanelStyleIdentifier(),
              "nome/utilizador da BD aleatório no formato cPanel (≤ 32)")
        check(pass.count == 24 && pass.contains(where: \.isUppercase) && pass.contains(where: \.isLowercase)
              && pass.contains(where: \.isNumber) && pass.contains(where: { !$0.isLetter && !$0.isNumber })
              && !pass.contains("'") && !pass.contains("\\"), "palavra-passe forte com 4 tipos de caracteres")
        check(SiteStore.wpConfig(for: DatabaseConfig(engine: .mysql, name: "a", user: "u", password: "p'x\\")).contains("'p\\'x\\\\'"),
              "wp-config escapa palavras-passe")
        check(SiteStore.wpConfig(for: DatabaseConfig(engine: .sqlite)).contains("define( 'AUTOMATIC_UPDATER_DISABLED', true );"),
              "wp-config desliga as atualizações automáticas")
        // Importação: só as constantes da ligação mudam no wp-config do Local; o resto fica.
        let localConfig = "<?php\ndefine( 'DB_NAME', 'local' );\ndefine('DB_HOST','localhost');\n$table_prefix = 'xy_';\n"
        let imported = SiteStore.addingLocalDefaults(to: SiteStore.settingDatabase(
            DatabaseConfig(engine: .mysql, host: "127.0.0.1", port: 3321, name: "wpc_a", user: "wpc_b", password: "p'1"), in: localConfig))
        check(imported.contains("define( 'DB_NAME', 'wpc_a' )") && imported.contains("define( 'DB_HOST', '127.0.0.1:3321' )")
              && imported.contains("$table_prefix = 'xy_'") && imported.contains("define( 'AUTOMATIC_UPDATER_DISABLED', true );")
              && imported.contains("define( 'WP_ENVIRONMENT_TYPE', 'local' );") && !imported.contains("'local' );\ndefine('DB_HOST'"),
              "importação ajusta o wp-config e mantém o resto")
        check(SiteStore.phpVersion("8.2.27") == "8.2" && SiteStore.phpVersion("7.4.1") == PHPVersions.bundled,
              "versão de PHP do site de origem")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wpcenter-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) } // só a pasta temporária criada aqui
        let store = SiteStore(storage: tmp.appendingPathComponent("support"))

        // MySQL: porta fechada → erro limpo, sem rebentar.
        var db = DatabaseConfig(engine: .mysql, targetVersion: "8.4", port: 1, name: "teste_wp", user: "x")
        let probe = try? await DatabaseProbe.run(db, create: false)
        check(probe?.ok == false && probe?.verdict(for: db).ok == false, "teste de ligação MySQL falha de forma controlada")
        db.name = "bad name"
        check((try? await DatabaseProbe.run(db, create: false)) == nil, "nome de BD inválido é rejeitado")

        // SQLite sempre; MariaDB/MySQL geridos para cada versão já instalada no Mac.
        var configs = [DatabaseConfig(engine: .sqlite, targetVersion: "")]
        for (engine, versions) in LocalServer.homebrewVersions {
            for v in versions {
                let server = LocalServer(DatabaseConfig(engine: engine, targetVersion: v))
                guard server.isInstalled else { continue }
                // Um servidor já ativo pertence à app em uso: não lhe criamos bases de dados de teste.
                guard SiteStore.isPortFree(server.port) else { print("— \(server.title): já está a correr, ignorado"); continue }
                configs.append(DatabaseConfig(engine: engine, targetVersion: v))
            }
        }
        for config in configs { await siteRoundTrip(store, in: tmp, config, check) }
        await importRoundTrip(store, in: tmp, check)
        // SQLite: a exportação da WP Center leva a base de dados dentro do site e mantém o motor.
        do {
            let sqlite = try await store.create(name: "Selftest SQLite Origem", in: tmp, adminUser: "origem", adminPassword: "Origem-pw1",
                                                database: DatabaseConfig(engine: .sqlite, targetVersion: ""))
            await wpcenterRoundTrip(store, sqlite, in: tmp, check)
        } catch {
            check(false, "criar site SQLite para exportar: \(error.localizedDescription)")
        }
        // Outras versões de PHP já instaladas com o Homebrew: um site SQLite com cada uma.
        for php in PHPVersions.all where php != PHPVersions.bundled && PHPVersions.isInstalled(php) {
            await siteRoundTrip(store, in: tmp, DatabaseConfig(engine: .sqlite, targetVersion: ""), php: php, check)
        }

        print(failures == 0 ? "\nTudo OK" : "\n\(failures) falha(s)")
        store.stopAll()
        return failures == 0
    }

    /// Criar, arrancar, pedir páginas, parar.
    private static func siteRoundTrip(_ store: SiteStore, in tmp: URL, _ config: DatabaseConfig, php: String = PHPVersions.bundled,
                                      _ check: (Bool, String) -> Void) async {
        let label = (config.engine == .sqlite ? "SQLite" : LocalServer(config).title.trimmingCharacters(in: .whitespaces))
            + (php == PHPVersions.bundled ? "" : " PHP \(php)")
        print("— \(label)")
        do {
            let site = try await store.create(name: "Selftest \(label)", in: tmp, adminUser: "selftest",
                                              adminPassword: "Selftest-pw1", database: config, php: php)
            if config.engine == .sqlite {
                check(FileManager.default.fileExists(atPath: site.path + "/wp-content/database/.ht.sqlite"), "site SQLite instalado")
            } else {
                let probe = try await DatabaseProbe.run(site.database, create: false)
                check(probe.engine == config.engine && probe.version == config.targetVersion && (probe.tables ?? 0) > 0,
                      "tabelas criadas em \(probe.engine?.title ?? "?") \(probe.version ?? "?")")
                check(site.database.name.hasPrefix("wpc_") && site.database.user.hasPrefix("wpc_")
                      && site.database.user != site.adminUser && site.database.password != site.adminPassword,
                      "BD com utilizador e palavra-passe próprios, separados do login")
                let incompatible = try await store.collation(site, convert: false)
                check(incompatible.isEmpty, "sem colações exclusivas do MySQL 8")
            }
            check(FileManager.default.fileExists(atPath: site.path + "/WPCENTER.md"), "ficheiros para agentes criados")
            check(FileManager.default.fileExists(atPath: site.path + "/.claude/skills/wp-center/SKILL.md")
                  && FileManager.default.fileExists(atPath: site.path + "/.agents/skills/wp-center/SKILL.md"),
                  "habilidade wp-center copiada para o site novo")
            store.syncSkills(for: site, enabled: Set(AgentSkill.all.map(\.id)).subtracting(["rank-me-up"]))
            let skillExists = { (path: String) in FileManager.default.fileExists(atPath: site.path + path) }
            check(skillExists("/.claude/skills/wp-rest-api/SKILL.md") && skillExists("/.agents/skills/wp-rest-api/SKILL.md")
                  && !skillExists("/.claude/skills/rank-me-up") && !skillExists("/.agents/skills/rank-me-up"),
                  "habilidade desligada sai do site; as ativas ficam")
            let agents = site.folder.appendingPathComponent("AGENTS.md"), guide = site.folder.appendingPathComponent("WPCENTER.md")
            try "editado".write(to: agents, atomically: true, encoding: .utf8)
            try "antigo".write(to: guide, atomically: true, encoding: .utf8)
            store.writeAgentFiles(for: site)
            check((try? String(contentsOf: agents, encoding: .utf8)) == "editado"
                  && (try? String(contentsOf: guide, encoding: .utf8))?.contains("wpc login-url") == true,
                  "WPCENTER.md é reescrito pela app; o AGENTS.md editado fica")

            // Ferramentas para agentes (wpc context / wpc flush).
            let tool = { (action: String) in
                try await Runtime.php([Runtime.wpCli.path, "eval-file", Runtime.tools.path], cwd: site.folder,
                                      env: ["WPCENTER_ACTION": action, "WPCENTER_JSON": "1"], using: site.phpExecutable())
            }
            // Aqui stdout e stderr vêm juntos (no PHP 8.5 o WP-CLI avisa antes do JSON); o `wpc` separa-os.
            let output = try await tool("context")
            let context = try JSONSerialization.jsonObject(with: Data(output[(output.range(of: "{\n")?.lowerBound ?? output.startIndex)...].utf8)) as? [String: Any]
            check(context?["url"] as? String == site.url.absoluteString && context?["plugins"] != nil && context?["content"] != nil,
                  "wpc context descreve o site")
            check(try await tool("flush").contains("transients"), "wpc flush limpa as caches")

            // Cartões Estado e Espaço.
            let health = try await store.health(site)
            check(!health.debug, "estado lido do WordPress (debug desligado)")
            let backups = site.folder.appendingPathComponent("wp-content/wpvividbackups")
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            for (name, age) in [("x_wpvivid-aaa111_2026-10-01_backup_all.part001.zip", 200.0), ("x_wpvivid-aaa111_2026-10-01_backup_all.part002.zip", 200),
                                ("x_wpvivid-bbb222_2026-10-16_backup_all.zip", 0)] {
                let file = backups.appendingPathComponent(name)
                try Data(count: 4096).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
            }
            let space = SiteStore.space(of: site.folder, sqlite: config.engine == .sqlite, databaseDir: store.databaseDir(of: site))
            check(space.backupSets.map(\.id) == ["wpvivid-bbb222", "wpvivid-aaa111"] && space.backupSets[1].files.count == 2
                  && space.plugins > 0 && space.backups > 0 && (space.database ?? 0) > 0,
                  "espaço por partes e backups WPvivid agrupados, o mais recente primeiro")
            try FileManager.default.removeItem(at: backups)
            await store.start(site, detached: true) // como o `wpc start`
            var status = 0, body = ""
            for _ in 0..<40 where status != 200 {
                try await Task.sleep(for: .milliseconds(250))
                if let (data, resp) = try? await URLSession.shared.data(from: site.url) {
                    status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    body = String(decoding: data, as: UTF8.self)
                }
            }
            check(status == 200 && body.contains("<title>Selftest"), "página inicial responde 200 (HTTP \(status))")
            if status != 200 || !body.contains("<title>Selftest") { print(body.prefix(600)) }
            let login = try? await URLSession.shared.data(from: site.url.appendingPathComponent("wp-login.php"))
            check((login?.1 as? HTTPURLResponse)?.statusCode == 200, "wp-login.php responde 200")
            let poweredBy = (login?.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Powered-By") ?? ""
            check(poweredBy.hasPrefix("PHP/\(php == PHPVersions.bundled ? Runtime.phpVersion : php + ".")"),
                  "o servidor usa o PHP do site (\(poweredBy))")

            // Emails: o wp_mail() chega ao Mailpit (o incluído na app ou um que já esteja a correr).
            let subject = "selftest-\(UUID().uuidString)"
            try await Runtime.php([Runtime.wpCli.path, "eval", "wp_mail('teste@exemplo.test', '\(subject)', 'corpo');"], cwd: site.folder)
            var delivered = false
            for _ in 0..<20 where !delivered {
                let search = SiteStore.mailpitUI.appendingPathComponent("api/v1/search").appending(queryItems: [.init(name: "query", value: subject)])
                delivered = (try? await URLSession.shared.data(from: search)).map { String(decoding: $0.0, as: UTF8.self).contains(subject) } ?? false
                if !delivered { try await Task.sleep(for: .milliseconds(250)) }
            }
            check(delivered, "wp_mail() chega ao Mailpit")

            check(!SiteStore.isPortFree(site.port), "porta em uso é detetada")

            // Link de partilha: um pedido com o Host do túnel (como o cloudflared faz) recebe o endereço público, sem localhost.
            let shared = Runtime.output("/usr/bin/curl", ["-s", "-H", "Host: teste-wpc.trycloudflare.com", "http://127.0.0.1:\(site.port)/"])
            check(shared.contains("https://teste-wpc.trycloudflare.com") && !shared.contains("localhost:\(site.port)"),
                  "pelo link de partilha o site usa o endereço público")

            // Entrada automática: o código entra uma vez; reutilizado, é recusado.
            let loginURL = try await store.adminLoginURL(site)
            let viaShare = Runtime.output("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{redirect_url}",
                                                            "-H", "CF-Connecting-IP: 203.0.113.9", loginURL.absoluteString])
            check(viaShare.contains("wp-login.php"), "entrada automática recusa pedidos vindos do link de partilha")
            let first = try await URLSession(configuration: .ephemeral).data(from: loginURL)
            check(first.1.url?.absoluteString.hasSuffix("/wp-admin/") == true && String(decoding: first.0, as: UTF8.self).contains("action=logout"),
                  "WP Admin entra com sessão iniciada")
            let again = try await URLSession(configuration: .ephemeral).data(from: loginURL)
            check(again.1.url?.path.hasSuffix("wp-login.php") == true, "o mesmo código não serve duas vezes")

            let validBefore = await store.credentialsAreValid(site)
            check(validBefore == true, "credenciais guardadas são válidas")
            try await store.resetAccess(site)
            let updated = store.sites.first { $0.id == site.id }!
            let validAfter = await store.credentialsAreValid(updated)
            check(updated.adminPassword != site.adminPassword && validAfter == true,
                  "repor acesso gera e guarda uma palavra-passe nova")

            try await store.rename(updated, to: "Renomeado Ção", updateWordPress: true)
            let title = try await Runtime.php([Runtime.wpCli.path, "option", "get", "blogname"], cwd: site.folder)
            check(store.sites.first { $0.id == site.id }?.name == "Renomeado Ção" && title == "Renomeado Ção",
                  "mudar nome atualiza a app e o título no WordPress")

            // Parar a partir de "outro processo" (como `wpc stop` com o site iniciado pela app, ou vice-versa).
            let other = SiteStore(storage: store.storage)
            check(other.isRunning(site), "outro processo vê o site a correr")
            other.stop(site)
            try await Task.sleep(for: .milliseconds(800))
            check(!isListening(port: site.port), "parar termina o servidor e os workers")
            // Os pedidos HTTP acima deixam ligações em TIME_WAIT: o site tem de aparecer parado na mesma.
            check(!store.isRunning(site) && !other.isRunning(site), "site aparece parado logo após parar")
        } catch {
            check(false, "criar site: \(error.localizedDescription)")
        }
    }

    /// Um export no formato do Studio (wp-content, wp-config.php, sql/, meta.json), feito a partir de um site MySQL/MariaDB:
    /// importado, tem o endereço novo (também escapado e em https), responde e entra no wp-admin.
    private static func importRoundTrip(_ store: SiteStore, in tmp: URL, _ check: (Bool, String) -> Void) async {
        print("— Importação de ficheiro (formato Studio)")
        guard let config = configsForImport(store).first else { print("— sem MariaDB/MySQL livre, ignorado"); return }
        do {
            let original = try await store.create(name: "Selftest Origem", in: tmp, adminUser: "origem", adminPassword: "Origem-pw1",
                                                  database: config)
            // JSON dentro de JSON (Breakdance), https, e uma porta que só começa igual e não pode ser trocada.
            let esc = "\\\\\\/", oldHost = "localhost:\(original.port)"
            let mixed = { (host: String) in "a http:\(esc)\(esc)\(host)/x b https://\(host) c http://\(oldHost)0" }
            try await Runtime.php([Runtime.wpCli.path, "option", "update", "wpc_teste", mixed(oldHost)], cwd: original.folder)

            let export = tmp.appendingPathComponent("export")
            try FileManager.default.createDirectory(at: export.appendingPathComponent("sql"), withIntermediateDirectories: true)
            let server = LocalServer(original.database)
            let dump = ["mysqldump", "mariadb-dump"].compactMap { server.prefix?.appendingPathComponent("bin/\($0)") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }!
            _ = try await Runtime.exec(dump, ["--no-defaults", "--socket=\(server.socket)", "-uroot",
                                              "--result-file=\(export.path)/sql/export.sql", original.database.name])
            try FileManager.default.copyItem(at: original.folder.appendingPathComponent("wp-content"), to: export.appendingPathComponent("wp-content"))
            try FileManager.default.copyItem(at: original.folder.appendingPathComponent("wp-config.php"), to: export.appendingPathComponent("wp-config.php"))
            try #"{"siteUrl":"x","phpVersion":"8.4"}"#.write(to: export.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
            let zip = tmp.appendingPathComponent("Selftest Importado-2026-10-16-23-18.zip")
            _ = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"),
                                       ["-a", "-cf", zip.path, "-C", export.path, "wp-content", "wp-config.php", "sql", "meta.json"])
            check(SiteStore.siteName(for: zip) == "Selftest Importado", "nome sugerido a partir do ficheiro")

            let site = try await store.importSite(from: zip, name: SiteStore.siteName(for: zip), into: tmp.appendingPathComponent("importados"),
                                                 database: config)
            let replaced = try await Runtime.php([Runtime.wpCli.path, "option", "get", "wpc_teste"], cwd: site.folder)
            check(replaced == mixed("localhost:\(site.port)").replacingOccurrences(of: "https://", with: "http://"),
                  "URLs escapadas e https trocadas; outras portas ficam (\(replaced))")
            check(site.database.name != original.database.name && site.database.engine.needsServer, "base de dados nova no servidor gerido")
            check(site.adminUser == "origem" && !site.adminPassword.isEmpty, "administrador do site de origem com palavra-passe nova")
            await store.start(site)
            var status = 0
            for _ in 0..<40 where status != 200 {
                try await Task.sleep(for: .milliseconds(250))
                status = ((try? await URLSession.shared.data(from: site.url))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            }
            check(status == 200, "site importado responde 200")
            let valid = await store.credentialsAreValid(site)
            check(valid == true, "credenciais do site importado são válidas")
            store.stop(site)

            await wpcenterRoundTrip(store, original, in: tmp, check)
            await wpvividImport(store, original, in: tmp, check)
        } catch {
            check(false, "importar site: \(error.localizedDescription)")
        }
    }

    /// Um backup WPvivid feito à mão como o do servidor (zips por parte do site, repartidos em .part001/.part002):
    /// escolhida só a primeira parte, entra tudo, com o endereço novo, e responde.
    private static func wpvividImport(_ store: SiteStore, _ original: Site, in tmp: URL, _ check: (Bool, String) -> Void) async {
        print("— Importar backup WPvivid")
        do {
            let fm = FileManager.default
            let src = tmp.appendingPathComponent("vivid-src"), out = tmp.appendingPathComponent("vivid")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let prefix = "exemplo.pt_wpvivid-1a2b3c4d5e6f7_2026-10-17-10-00_backup_"
            let tar = { (args: [String]) async throws in
                let (status, output) = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"), ["-a", "-cf"] + args)
                if status != 0 { throw AppError(verbatim: output) }
            }
            let server = LocalServer(original.database)
            let dump = ["mysqldump", "mariadb-dump"].compactMap { server.prefix?.appendingPathComponent("bin/\($0)") }
                .first { fm.isExecutableFile(atPath: $0.path) }!
            _ = try await Runtime.exec(dump, ["--no-defaults", "--socket=\(server.socket)", "-uroot",
                                              "--result-file=\(src.path)/\(prefix)db.sql", original.database.name])
            try await tar(["\(src.path)/\(prefix)db.zip", "-C", src.path, "\(prefix)db.sql"])
            let content = original.folder.appendingPathComponent("wp-content").path
            try await tar(["\(src.path)/\(prefix)core.zip", "--exclude", "./wp-content", "-C", original.folder.path, "."])
            try await tar(["\(src.path)/\(prefix)plugin.zip", "-C", content, "plugins"])
            try await tar(["\(src.path)/\(prefix)themes.zip", "-C", content, "themes"])
            try await tar(["\(src.path)/\(prefix)content.zip", "--exclude", "./plugins", "--exclude", "./themes", "-C", content, "."])
            try #"{"php_version":"8.4.1","home_url":"https://exemplo.pt"}"#
                .write(to: src.appendingPathComponent("wpvivid_package_info.json"), atomically: true, encoding: .utf8)
            let part1 = out.appendingPathComponent("\(prefix)all.part001.zip")
            try await tar([part1.path, "-C", src.path, "wpvivid_package_info.json", "\(prefix)db.zip", "\(prefix)core.zip"])
            try await tar([out.appendingPathComponent("\(prefix)all.part002.zip").path, "-C", src.path, "wpvivid_package_info.json",
                           "\(prefix)plugin.zip", "\(prefix)themes.zip", "\(prefix)content.zip"])

            let peek = ExportOrigin.peek(part1)
            check(peek.origin == .wpvivid && peek.name == "exemplo.pt", "backup reconhecido como WPvivid (\(peek.name))")
            let site = try await store.importSite(from: part1, name: "Selftest WPvivid", into: tmp.appendingPathComponent("vivid-importados"))
            let plugins = { (dir: String) in Set((try? fm.contentsOfDirectory(atPath: dir + "/plugins")) ?? []) }
            check(!plugins(content).isEmpty && plugins(site.path + "/wp-content") == plugins(content)
                  && fm.fileExists(atPath: site.path + "/wp-content/mu-plugins") && !fm.fileExists(atPath: site.path + "/sql")
                  && !fm.fileExists(atPath: site.path + "/wpvivid_package_info.json"),
                  "as duas partes entram, cada zip no sítio certo e sem restos do backup")
            let value = try await Runtime.php([Runtime.wpCli.path, "option", "get", "wpc_ida_volta"], cwd: site.folder)
            check(value == "\(site.url.absoluteString)/x", "WPvivid: endereço trocado (\(value))")
            await store.start(site)
            var status = 0
            for _ in 0..<40 where status != 200 {
                try await Task.sleep(for: .milliseconds(250))
                status = ((try? await URLSession.shared.data(from: site.url))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            }
            let valid = await store.credentialsAreValid(site)
            check(status == 200 && valid == true, "WPvivid: site responde 200 e entra com a palavra-passe nova")
            store.stop(site)
        } catch {
            check(false, "importar backup WPvivid: \(error.localizedDescription)")
        }
    }

    /// Exportar para outra WP Center e importar de volta: mesmo motor, endereço novo, responde e entra.
    private static func wpcenterRoundTrip(_ store: SiteStore, _ original: Site, in tmp: URL, _ check: (Bool, String) -> Void) async {
        let label = original.database.engine.title
        print("— Exportar e importar entre WP Centers (\(label))")
        do {
            try await Runtime.php([Runtime.wpCli.path, "option", "update", "wpc_ida_volta", "\(original.url.absoluteString)/x"], cwd: original.folder)
            let file = try await store.exportForWPCenter(original, to: tmp.appendingPathComponent("exportacoes"))
            let peek = ExportOrigin.peek(file)
            check(peek.origin == .wpcenter && peek.name == original.name, "\(label): ficheiro reconhecido como WP Center (\(peek.name))")
            let copy = try await store.importSite(from: file, name: "\(original.name) Cópia", into: tmp.appendingPathComponent("copias"))
            check(copy.database.engine == original.database.engine && copy.database.targetVersion == original.database.targetVersion
                  && copy.php == original.php, "\(label): mesmo motor, versão e PHP")
            let value = try await Runtime.php([Runtime.wpCli.path, "option", "get", "wpc_ida_volta"], cwd: copy.folder)
            check(value == "\(copy.url.absoluteString)/x", "\(label): endereço trocado na cópia (\(value))")
            await store.start(copy)
            var status = 0
            for _ in 0..<40 where status != 200 {
                try await Task.sleep(for: .milliseconds(250))
                status = ((try? await URLSession.shared.data(from: copy.url))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            }
            let valid = await store.credentialsAreValid(copy)
            check(status == 200 && valid == true, "\(label): cópia responde 200 e entra com a palavra-passe nova")
            store.stop(copy)

            let dup = try await store.duplicate(original, name: "\(original.name) Duplicado")
            let dupValue = try await Runtime.php([Runtime.wpCli.path, "option", "get", "wpc_ida_volta"], cwd: dup.folder)
            check(dup.folder.deletingLastPathComponent().standardizedFileURL == original.folder.deletingLastPathComponent().standardizedFileURL
                  && dup.database.engine == original.database.engine && dupValue == "\(dup.url.absoluteString)/x",
                  "\(label): duplicar cria a cópia ao lado do original, com o mesmo motor e endereço novo")
        } catch {
            check(false, "\(label): exportar/importar entre WP Centers: \(error.localizedDescription)")
        }
    }

    /// Servidores instalados e livres, ou já arrancados por este teste (um ativo de outra forma pertence à app em uso).
    private static func configsForImport(_ store: SiteStore) -> [DatabaseConfig] {
        [DatabaseEngine.mariadb, .mysql].flatMap { engine in
            (LocalServer.homebrewVersions[engine] ?? []).reversed().map { DatabaseConfig(engine: engine, targetVersion: $0) }
        }
        .filter { LocalServer($0).isInstalled && (SiteStore.isPortFree(LocalServer($0).port) || store.databaseServers[LocalServer($0)] != nil) }
    }

    private static func isListening(port: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "127.0.0.1:\(port)"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
