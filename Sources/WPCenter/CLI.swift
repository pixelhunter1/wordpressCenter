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

    static let help = L("""
    WP Center — sites WordPress locais

    Utilização: wpc [--path <pasta-do-site>] <comando>

    Comandos:
      wpc list               Lista os sites (--json)
      wpc status             Estado, endereço, credenciais e base de dados do site (--json)
      wpc context            Resumo para agentes: tema, construtor, plugins, conteúdo, WooCommerce (--json)
      wpc start              Inicia o site (e o servidor de base de dados, se for preciso)
      wpc stop               Para o site
      wpc admin              Abre o wp-admin já com sessão iniciada
      wpc login-url          Link de entrada no wp-admin, de uso único e válido 60 s (inicia o site se for preciso)
      wpc flush              Limpa as caches: objetos, transients, ligações permanentes, Elementor, plugins de cache
      wpc logs [linhas]      Erros recentes do PHP e do wp-content/debug.log
      wpc mail [ID]          Últimos emails apanhados pelo Mailpit; com ID, mostra o texto de um (--json)
      wpc export             Backup WPvivid pronto a restaurar no cPanel (--convert: corrige colações do MySQL 8)
      wpc export --wpcenter  O site completo num .zip, para importar noutra WP Center
      wpc duplicate          Cria uma cópia completa do site (ficheiros e base de dados); --name "Nome"
      wpc import <ficheiro>  Cria um site a partir de uma exportação da WP Center, do Studio, do Local ou de um backup WPvivid; --name "Nome"
      wpc wp <args…>         WP-CLI com o PHP e a base de dados do site

    Os comandos usam o site da pasta atual, ou o indicado em --path.
    """)

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
        case "list" where args.contains("--json"):
            printJSON(store.sites.map { info($0, store) })
            return 0
        case "list":
            if store.sites.isEmpty { print(L("Ainda não há sites. Crie um na app WP Center.")); return 0 }
            for site in store.sites {
                let status = store.isRunning(site) ? L("● a correr") : L("○ parado  ")
                print("\(status)  \(site.name)  \(site.url.absoluteString)  \(site.database.engine.title) \(site.database.targetVersion)  \(site.path)")
            }
            return 0
        case "mail":
            return await mail(Array(args.dropFirst()))
        case "import":
            var rest = Array(args.dropFirst())
            var name: String?
            if let i = rest.firstIndex(of: "--name"), i + 1 < rest.count { name = rest[i + 1]; rest.removeSubrange(i...(i + 1)) }
            guard let file = rest.first else {
                fail(L("Indique o ficheiro: wpc import <exportação.zip> [--name \"Nome\"]"))
                return 1
            }
            let archive = URL(fileURLWithPath: file)
            print(L("A importar \(archive.lastPathComponent)…"))
            fflush(stdout)
            do {
                let site = try await store.importSite(from: archive, name: name ?? ExportOrigin.peek(archive).name)
                print(L("Pronto: \(site.name) em \(site.url.absoluteString)  —  \(site.path)"))
                print(L("Utilizador: \(site.adminUser)  Palavra-passe: \(site.adminPassword)"))
                store.stopAll() // os servidores de base de dados arrancados só para a importação
                return 0
            } catch {
                fail(error.localizedDescription)
                store.stopAll()
                return 1
            }
        default:
            break
        }

        guard let site = store.site(containing: path) else {
            fail(L("\(path) não pertence a nenhum site do WP Center. Entre na pasta do site ou use --path (veja `wpc list`)."))
            return 1
        }

        switch args[0] {
        case "status" where args.contains("--json"):
            printJSON(info(site, store))
            return 0

        case "status":
            let db = site.database
            let state = store.isRunning(site) ? L("a correr") : L("parado")
            let server = db.engine.needsServer ? L(" — \(db.name) em \(db.host):\(db.port)") : ""
            print(L("""
            Site:           \(site.name)
            Estado:         \(state)
            Endereço:       \(site.url.absoluteString)
            Administração:  \(site.url.absoluteString)/wp-admin/
            Utilizador:     \(site.adminUser)
            Palavra-passe:  \(site.adminPassword)
            Pasta:          \(site.path)
            WordPress:      \(site.wpVersion)
            PHP:            \(PHPVersions.display(site.php))
            Base de dados:  \(db.engine.title) \(db.targetVersion)\(server)
            """))
            return 0

        case "start":
            if store.isRunning(site) { print(L("\(site.name) já está a correr em \(site.url.absoluteString)")); return 0 }
            await store.start(site, detached: true)
            if let error = store.errorMessage { fail(error); return 1 }
            for _ in 0..<40 where SiteStore.isPortFree(site.port) { try? await Task.sleep(for: .milliseconds(250)) }
            print(L("\(site.name) a correr em \(site.url.absoluteString)"))
            return 0

        case "stop":
            guard store.isRunning(site) else { print(L("\(site.name) já está parado.")); return 0 }
            store.stop(site)
            print(L("\(site.name) parado."))
            return 0

        case "admin":
            await store.openAdmin(site)
            if let error = store.errorMessage { fail(error); return 1 }
            print(L("wp-admin de \(site.name) aberto com sessão iniciada."))
            return 0

        case "export" where args.contains("--wpcenter"):
            print(L("A exportar \(site.name) para outra WP Center…"))
            fflush(stdout)
            do {
                let file = try await store.exportForWPCenter(site)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                print(L("Pronto: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"))
                print(file.path)
                print(L("Noutro Mac: WP Center → Ficheiro → Importar site, ou `wpc import <ficheiro>`."))
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case "export":
            print(L("A criar o backup de \(site.name) com o WPvivid…"))
            fflush(stdout) // antes de qualquer erro em stderr
            do {
                let policy: SiteStore.CollationPolicy = args.contains("--convert") ? .convert : args.contains("--no-convert") ? .ignore : .check
                let result = try await store.exportForCPanel(site, collations: policy)
                print(L("Pronto: \(result.files.count) ficheiro(s), \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))"))
                print(result.dir)
                result.files.forEach { print("  \($0)") }
                print(L("No cPanel: WPvivid → Backup & Restore → Upload → Restore."))
                return 0
            } catch let error as SiteStore.IncompatibleCollationError {
                fail(L("\(error.localizedDescription)\nUse `wpc export --convert` para converter (recomendado) ou `wpc export --no-convert` se o cPanel usar MySQL 8."))
                return 1
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case "duplicate":
            var name = L("\(site.name) (cópia)")
            if let i = args.firstIndex(of: "--name"), i + 1 < args.count { name = args[i + 1] }
            print(L("A duplicar \(site.name)…"))
            fflush(stdout)
            do {
                let copy = try await store.duplicate(site, name: name)
                print(L("Pronto: \(copy.name) em \(copy.url.absoluteString)  —  \(copy.path)"))
                print(L("Utilizador: \(copy.adminUser)  Palavra-passe: \(copy.adminPassword)"))
                store.stopAll() // os servidores de base de dados arrancados só para duplicar
                return 0
            } catch {
                fail(error.localizedDescription)
                store.stopAll()
                return 1
            }

        case "context":
            return await wp(site, store, ["eval-file", Runtime.tools.path],
                            env: ["WPCENTER_ACTION": "context", "WPCENTER_JSON": args.contains("--json") ? "1" : "0"])

        case "flush":
            return await wp(site, store, ["eval-file", Runtime.tools.path], env: ["WPCENTER_ACTION": "flush"])

        case "login-url":
            if !store.isRunning(site) {
                await store.start(site, detached: true)
                if let error = store.errorMessage { fail(error); return 1 }
                for _ in 0..<40 where SiteStore.isPortFree(site.port) { try? await Task.sleep(for: .milliseconds(250)) }
            }
            do {
                print(try await store.adminLoginURL(site).absoluteString)
                return 0
            } catch {
                fail(error.localizedDescription)
                return 1
            }

        case "logs":
            let count = args.dropFirst().compactMap { Int($0) }.first ?? 40
            // Só os erros: sem as linhas de cada pedido, os arranques do servidor nem as tentativas de https do navegador.
            let noise = #/ (Accepted|Closing)$|\[[1-4]\d\d\]: [A-Z]+ |Invalid request \(Unsupported SSL request\)|Development Server \(.*\) started/#
            let server = tail(store.logs.appendingPathComponent("\(site.id).log")).filter { !$0.contains(noise) }.suffix(count)
            let debug = tail(site.folder.appendingPathComponent("wp-content/debug.log")).suffix(count)
            if server.isEmpty && debug.isEmpty { print(L("Sem erros registados.")); return 0 }
            if !server.isEmpty { print(L("== Servidor PHP ==")); server.forEach { print($0) } }
            if !debug.isEmpty { print(L("== wp-content/debug.log ==")); debug.forEach { print($0) } }
            return 0

        case "wp":
            return await wp(site, store, Array(args.dropFirst()))

        default:
            fail(L("Comando desconhecido: \(args[0])\n\n\(help)"))
            return 1
        }
    }

    /// WP-CLI com o PHP e a base de dados do site. stdin/stdout/stderr herdados: `wpc wp shell` e prompts interativos funcionam.
    private static func wp(_ site: Site, _ store: SiteStore, _ args: [String], env: [String: String] = [:]) async -> Int32 {
        do {
            if site.database.engine.needsServer && site.database.managed {
                try await store.ensureRunning(LocalServer(site.database))
            }
            let p = Process()
            p.executableURL = try site.phpExecutable()
            // Avisos do PHP para stderr: o stdout fica só com o resultado (JSON limpo para agentes, mesmo com os Deprecated
            // que o WP-CLI dá no PHP 8.5).
            p.arguments = Runtime.iniArgs + ["-d", "display_errors=stderr", Runtime.wpCli.path] + args
            p.currentDirectoryURL = site.folder
            p.environment = ProcessInfo.processInfo.environment.merging(env.merging(["WPCENTER_LANG": Runtime.language]) { $1 }) { $1 }
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    /// Emails do Mailpit (comum a todos os sites): os últimos 20, ou o texto de um pelo ID.
    private static func mail(_ args: [String]) async -> Int32 {
        let id = args.first { !$0.hasPrefix("--") }
        let url = id.map { SiteStore.mailpitUI.appendingPathComponent("api/v1/message/\($0)") }
            ?? SiteStore.mailpitUI.appendingPathComponent("api/v1/messages").appending(queryItems: [.init(name: "limit", value: "20")])
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail(id.map { L("Email não encontrado: \($0)") } ?? L("O Mailpit não está a correr: inicie um site (wpc start)."))
            return 1
        }
        if args.contains("--json") { print(String(decoding: data, as: UTF8.self)); return 0 }
        func from(_ value: Any?) -> String { (value as? [String: Any])?["Address"] as? String ?? "" }
        func to(_ value: Any?) -> String { ((value as? [[String: Any]]) ?? []).compactMap { $0["Address"] as? String }.joined(separator: ", ") }
        if id != nil {
            print(L("De: \(from(json["From"]))"))
            print(L("Para: \(to(json["To"]))"))
            print(L("Assunto: \(json["Subject"] as? String ?? "")"))
            print(L("Data: \(json["Date"] as? String ?? "")"))
            print("")
            print(json["Text"] as? String ?? "")
            return 0
        }
        let messages = json["messages"] as? [[String: Any]] ?? []
        if messages.isEmpty { print(L("Ainda não há emails.")); return 0 }
        for m in messages {
            print("\(m["ID"] as? String ?? "")  \(m["Created"] as? String ?? "")  \(to(m["To"]))  \(m["Subject"] as? String ?? "")")
        }
        print(L("Para ler um: wpc mail <ID>"))
        return 0
    }

    /// As linhas do fim de um ficheiro de registo (só o último MB: os registos do servidor crescem com cada pedido).
    private static func tail(_ file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1 << 20 ? size - (1 << 20) : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    /// Para `--json`: o que o `wpc status` mostra, com nomes estáveis.
    private static func info(_ site: Site, _ store: SiteStore) -> [String: Any] {
        let db = site.database
        var database: [String: Any] = ["engine": db.engine.rawValue, "version": db.targetVersion]
        if db.engine.needsServer { database.merge(["name": db.name, "user": db.user, "host": "\(db.host):\(db.port)"]) { $1 } }
        return [
            "name": site.name, "url": site.url.absoluteString, "adminUrl": site.url.absoluteString + "/wp-admin/",
            "running": store.isRunning(site), "path": site.path, "adminUser": site.adminUser, "adminPassword": site.adminPassword,
            "wordpress": site.wpVersion, "php": site.php, "database": database,
        ]
    }

    private static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("wpc: \(message)\n".utf8))
    }
}
