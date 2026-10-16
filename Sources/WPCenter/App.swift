import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "wpc" {
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

    var body: some Scene {
        WindowGroup("WP Center") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 740)
        .windowToolbarStyle(.unified)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { SiteStore.shared.stopAll() }
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
        check(SiteStore.databaseName(for: "O meu site") == "wp_o_meu_site", "nome automático da base de dados")
        check(SiteStore.wpConfig(for: DatabaseConfig(engine: .mysql, name: "a", user: "u", password: "p'x\\")).contains("'p\\'x\\\\'"),
              "wp-config escapa palavras-passe")

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

        print(failures == 0 ? "\nTudo OK" : "\n\(failures) falha(s)")
        store.stopAll()
        return failures == 0
    }

    /// Criar, arrancar, pedir páginas, parar.
    private static func siteRoundTrip(_ store: SiteStore, in tmp: URL, _ config: DatabaseConfig,
                                      _ check: (Bool, String) -> Void) async {
        let label = LocalServer(config).title.trimmingCharacters(in: .whitespaces)
        print("— \(config.engine == .sqlite ? "SQLite" : label)")
        do {
            let site = try await store.create(name: "Selftest \(label)", in: tmp, adminUser: "selftest",
                                              adminPassword: "Selftest-pw1", database: config)
            if config.engine == .sqlite {
                check(FileManager.default.fileExists(atPath: site.path + "/wp-content/database/.ht.sqlite"), "site SQLite instalado")
            } else {
                let probe = try await DatabaseProbe.run(site.database, create: false)
                check(probe.engine == config.engine && probe.version == config.targetVersion && (probe.tables ?? 0) > 0,
                      "tabelas criadas em \(probe.engine?.title ?? "?") \(probe.version ?? "?")")
            }
            check(FileManager.default.fileExists(atPath: site.path + "/WPCENTER.md")
                  && FileManager.default.fileExists(atPath: site.path + "/.claude/skills/rank-me-up/SKILL.md"), "ficheiros para agentes criados")
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

            check(!SiteStore.isPortFree(site.port), "porta em uso é detetada")

            // Parar a partir de "outro processo" (como `wpc stop` com o site iniciado pela app, ou vice-versa).
            let other = SiteStore(storage: store.storage)
            check(other.isRunning(site), "outro processo vê o site a correr")
            other.stop(site)
            try await Task.sleep(for: .milliseconds(800))
            check(!isListening(port: site.port), "parar termina o servidor e os workers")
        } catch {
            check(false, "criar site: \(error.localizedDescription)")
        }
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
