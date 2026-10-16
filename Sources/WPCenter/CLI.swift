import Foundation

/// O comando `wpc` é o próprio executável da app, chamado através de uma ligação em ~/.local/bin/wpc.
@MainActor
enum CLI {
    static let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/wpc")

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == Bundle.main.executablePath
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? uninstall()
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: Bundle.main.executablePath!)
    }

    /// Só remove a ligação se for nossa: nunca apaga um `wpc` que não tenha sido criado pela app.
    static func uninstall() throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))?.hasSuffix("/Contents/MacOS/WPCenter") == true else { return }
        try FileManager.default.removeItem(at: link)
    }

    static let help = """
    WP Center — sites WordPress locais

    Utilização: wpc [--path <pasta-do-site>] <comando>

    Comandos:
      wpc list            Lista os sites
      wpc status          Estado, endereço, credenciais e base de dados do site
      wpc start           Inicia o site (e o servidor de base de dados, se for preciso)
      wpc stop            Para o site
      wpc admin           Abre o wp-admin já com sessão iniciada
      wpc export          Backup WPvivid pronto a restaurar no cPanel
      wpc wp <args…>      WP-CLI com o PHP e a base de dados do site

    Os comandos usam o site da pasta atual, ou o indicado em --path.
    """

    static func run() async -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        var path = FileManager.default.currentDirectoryPath
        // --path só é nosso antes do subcomando `wp`; depois disso pertence ao WP-CLI.
        let wpIndex = args.firstIndex(of: "wp") ?? args.count
        if let i = args.firstIndex(of: "--path"), i < wpIndex, i + 1 < args.count {
            path = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        let store = SiteStore.shared

        switch args.first {
        case nil, "help", "--help", "-h":
            print(help)
            return 0
        case "--version", "-v":
            print("wpc \(Runtime.appVersion) (WordPress \(Runtime.bundledWordPressVersion), PHP \(Runtime.phpVersion))")
            return 0
        case "list":
            if store.sites.isEmpty { print("Ainda não há sites. Crie um na app WP Center."); return 0 }
            for site in store.sites {
                let status = store.isRunning(site) ? "● a correr" : "○ parado  "
                print("\(status)  \(site.name)  \(site.url.absoluteString)  \(site.database.engine.title) \(site.database.targetVersion)  \(site.path)")
            }
            return 0
        default:
            break
        }

        guard let site = store.site(containing: path) else {
            fail("\(path) não pertence a nenhum site do WP Center. Entre na pasta do site ou use --path (veja `wpc list`).")
            return 1
        }

        switch args[0] {
        case "status":
            let db = site.database
            print("""
            Site:           \(site.name)
            Estado:         \(store.isRunning(site) ? "a correr" : "parado")
            Endereço:       \(site.url.absoluteString)
            Administração:  \(site.url.absoluteString)/wp-admin/
            Utilizador:     \(site.adminUser)
            Palavra-passe:  \(site.adminPassword)
            Pasta:          \(site.path)
            WordPress:      \(site.wpVersion)
            PHP:            \(Runtime.phpVersion)
            Base de dados:  \(db.engine.title) \(db.targetVersion)\(db.engine.needsServer ? " — \(db.name) em \(db.host):\(db.port)" : "")
            """)
            return 0

        case "start":
            if store.isRunning(site) { print("\(site.name) já está a correr em \(site.url.absoluteString)"); return 0 }
            await store.start(site, detached: true)
            if let error = store.errorMessage { fail(error); return 1 }
            for _ in 0..<40 where SiteStore.isPortFree(site.port) { try? await Task.sleep(for: .milliseconds(250)) }
            print("\(site.name) a correr em \(site.url.absoluteString)")
            return 0

        case "stop":
            guard store.isRunning(site) else { print("\(site.name) já está parado."); return 0 }
            store.stop(site)
            print("\(site.name) parado.")
            return 0

        case "admin":
            await store.openAdmin(site)
            if let error = store.errorMessage { fail(error); return 1 }
            print("wp-admin de \(site.name) aberto com sessão iniciada.")
            return 0

        case "export":
            print("A criar o backup de \(site.name) com o WPvivid…")
            do {
                let result = try await store.exportForCPanel(site)
                print("Pronto: \(result.files.count) ficheiro(s), \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))")
                print(result.dir)
                result.files.forEach { print("  \($0)") }
                print("No cPanel: WPvivid → Backup & Restore → Upload → Restore.")
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case "wp":
            do {
                if site.database.engine.needsServer && site.database.managed {
                    try await store.ensureRunning(LocalServer(site.database))
                }
            } catch {
                fail(error.localizedDescription)
                return 1
            }
            // stdin/stdout/stderr herdados: `wpc wp shell` e prompts interativos funcionam.
            let p = Process()
            p.executableURL = Runtime.php
            p.arguments = Runtime.iniArgs + [Runtime.wpCli.path] + args.dropFirst()
            p.currentDirectoryURL = site.folder
            do { try p.run() } catch { fail(error.localizedDescription); return 1 }
            p.waitUntilExit()
            return p.terminationStatus

        default:
            fail("Comando desconhecido: \(args[0])\n\n\(help)")
            return 1
        }
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("wpc: \(message)\n".utf8))
    }
}
