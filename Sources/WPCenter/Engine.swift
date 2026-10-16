import AppKit
import Foundation
import Security

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Tudo o que o motor precisa vem dentro do .app (copiado pelo build.sh). Nenhum download, nenhum serviço externo.
enum Runtime {
    /// Chamado como `wpc` (ligação simbólica) o Bundle.main não é a .app; resolvemos a ligação até ao executável real.
    static let appBundle: Bundle = {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath()
        return Bundle(url: exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? .main
    }()
    static let root = appBundle.resourceURL!.appendingPathComponent("runtime")
    static var php: URL { root.appendingPathComponent("php/php") }
    static var wordpress: URL { root.appendingPathComponent("wordpress") }
    static var sqlitePlugin: URL { root.appendingPathComponent("sqlite-database-integration") }
    static var wpCli: URL { root.appendingPathComponent("wp-cli.phar") }
    static var router: URL { root.appendingPathComponent("router.php") }
    static var dbCheck: URL { root.appendingPathComponent("db-check.php") }
    static var skills: URL { root.appendingPathComponent("skills") }
    static var wpvividExport: URL { root.appendingPathComponent("wpvivid-export.php") }
    static var access: URL { root.appendingPathComponent("wpcenter-access.php") }
    static var autologin: URL { root.appendingPathComponent("wpcenter-autologin.php") }
    static var collation: URL { root.appendingPathComponent("wpcenter-collation.php") }
    static var mailPlugin: URL { root.appendingPathComponent("wpcenter-mail.php") }
    static var mailpit: URL { root.appendingPathComponent("mailpit") }

    static var appVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    /// Corre um comando curto de forma síncrona e devolve o stdout.
    static func output(_ executable: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static let iniArgs = [
        "-d", "memory_limit=512M",
        "-d", "upload_max_filesize=256M",
        "-d", "post_max_size=256M",
        "-d", "max_execution_time=300",
    ]

    /// Corre o PHP incluído e devolve stdout+stderr. Lança erro com a saída se o código de saída não for 0.
    @discardableResult
    static func php(_ args: [String], cwd: URL? = nil, env: [String: String] = [:]) async throws -> String {
        let (status, out) = try await phpStatus(args, cwd: cwd, env: env)
        guard status == 0 else { throw AppError(out.isEmpty ? "O PHP terminou com o código \(status)." : out) }
        return out
    }

    static func phpStatus(_ args: [String], cwd: URL? = nil, env: [String: String] = [:]) async throws -> (Int32, String) {
        try await exec(php, iniArgs + args, cwd: cwd, env: env)
    }

    /// Corre um executável até terminar e devolve (código de saída, stdout+stderr).
    static func exec(_ executable: URL, _ args: [String], cwd: URL? = nil, env: [String: String] = [:]) async throws -> (Int32, String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe // um só pipe: evita bloqueio quando um dos buffers enche
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    static var bundledWordPressVersion: String {
        let file = wordpress.appendingPathComponent("wp-includes/version.php")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.firstMatch(of: #/\$wp_version = '([^']+)'/#).map { String($0.1) } ?? "?"
    }

    static var phpVersion: String {
        let file = root.appendingPathComponent("php/runtime.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "?" }
        return json["phpVersion"] as? String ?? "?"
    }
}

/// Resultado do db-check.php.
struct DatabaseProbe: Decodable {
    let ok: Bool
    var error: String?
    var engine: DatabaseEngine?
    var version: String?
    var tables: Int?

    /// Testa a ligação; com `create`, cria a base de dados se ainda não existir.
    /// Com `rootSocket` (servidor local gerido), cria também o utilizador e dá-lhe acesso à base de dados.
    static func run(_ db: DatabaseConfig, create: Bool, rootSocket: String? = nil) async throws -> DatabaseProbe {
        guard DatabaseConfig.isValidIdentifier(db.name) else {
            throw AppError("Nome da base de dados inválido. Use apenas letras, números e _ (ex.: utilizador_wp).")
        }
        // Credenciais vão por variáveis de ambiente: nunca aparecem na lista de processos (ps).
        let (_, json) = try await Runtime.phpStatus([Runtime.dbCheck.path], env: [
            "DB_HOST": db.host, "DB_PORT": String(db.port), "DB_USER": db.user,
            "DB_PASSWORD": db.password, "DB_NAME": db.name, "DB_CREATE": create ? "1" : "0",
            "DB_ROOT_SOCKET": rootSocket ?? "",
        ])
        guard let probe = try? JSONDecoder().decode(DatabaseProbe.self, from: Data(json.utf8)) else {
            throw AppError("Resposta inesperada do teste de ligação: \(json)")
        }
        return probe
    }

    /// Mensagem para o utilizador, comparando o servidor real com o que foi escolhido.
    func verdict(for db: DatabaseConfig) -> (ok: Bool, text: String) {
        guard ok, let engine, let version else { return (false, error ?? "Falha na ligação.") }
        if engine != db.engine {
            return (false, "O servidor é \(engine.title) \(version), mas escolheu \(db.engine.title).")
        }
        if let tables, tables > 0 {
            return (false, "A base de dados \"\(db.name)\" já tem \(tables) tabelas wp_. Use uma base de dados vazia.")
        }
        if !db.engine.cpanelVersions.contains(version) {
            return (true, "Ligado a \(engine.title) \(version). Atenção: esta versão não está na lista do cPanel.")
        }
        if version != db.targetVersion {
            return (true, "Ligado a \(engine.title) \(version) (escolheu \(db.targetVersion) como alvo).")
        }
        return (true, "Ligado a \(engine.title) \(version).")
    }
}

/// Servidor MariaDB/MySQL local, numa versão da lista do cPanel, gerido pela app.
/// Os binários vêm do Homebrew (fórmulas versionadas); os dados ficam em Application Support/WP Center/Databases.
struct LocalServer: Hashable {
    let engine: DatabaseEngine
    let version: String

    init(_ db: DatabaseConfig) { engine = db.engine; version = db.targetVersion }

    /// Versões da lista do cPanel que o Homebrew disponibiliza (MariaDB 10.5 não existe no Homebrew).
    static let homebrewVersions: [DatabaseEngine: [String]] = [.mariadb: ["10.6", "10.11", "11.4", "11.8"], .mysql: ["8.0", "8.4"]]

    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var title: String { "\(engine.title) \(version)" }
    var formula: String { "\(engine == .mariadb ? "mariadb" : "mysql")@\(version)" }
    var isSupportedOnMac: Bool { Self.homebrewVersions[engine]?.contains(version) == true }
    var prefix: URL? { Self.brew?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("opt/\(formula)") }
    var daemon: URL? { prefix?.appendingPathComponent(engine == .mariadb ? "bin/mariadbd" : "bin/mysqld") }
    var isInstalled: Bool { daemon.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }
    /// Porta fixa por versão, fora da 3306 para não colidir com outro MySQL que já exista no Mac.
    var port: Int { (engine == .mariadb ? 3310 : 3320) + (Self.homebrewVersions[engine]?.firstIndex(of: version) ?? 0) }
    var socket: String { "/tmp/wpcenter-\(formula).sock" } // caminho curto: sockets Unix têm limite de 104 caracteres
}

struct Site: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var port: Int
    var adminUser = "admin"
    var adminPassword: String
    var wpVersion: String
    var database: DatabaseConfig
    var createdAt = Date()

    var url: URL { URL(string: "http://localhost:\(port)")! }
    var folder: URL { URL(fileURLWithPath: path) }
}

@MainActor
final class SiteStore: ObservableObject {
    static let shared = SiteStore(storage: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WP Center"))

    @Published private(set) var sites: [Site] = []
    @Published private(set) var processes: [UUID: Process] = [:]
    @Published var errorMessage: String?

    let storage: URL
    private var file: URL { storage.appendingPathComponent("sites.json") }
    private var logs: URL { storage.appendingPathComponent("Logs") }

    init(storage: URL) {
        self.storage = storage
        if let data = try? Data(contentsOf: file) {
            sites = (try? Self.decoder.decode([Site].self, from: data)) ?? []
        }
    }

    static var defaultDirectory: URL {
        get {
            UserDefaults.standard.url(forKey: "sitesDirectory")
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WP Center")
        }
        set { UserDefaults.standard.set(newValue, forKey: "sitesDirectory") }
    }

    /// Também conta servidores iniciados noutro processo (app ↔ comando `wpc`): a porta do site está ocupada.
    func isRunning(_ site: Site) -> Bool { processes[site.id] != nil || !Self.isPortFree(site.port) }

    /// O site cuja pasta contém `path` (usado pelo `wpc`, que trabalha sobre a pasta atual).
    func site(containing path: String) -> Site? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return sites
            .filter { let root = $0.folder.resolvingSymlinksInPath().path; return target == root || target.hasPrefix(root + "/") }
            .max { $0.path.count < $1.path.count }
    }

    // MARK: Criar

    func create(name: String, in directory: URL, adminUser: String = "admin", adminPassword: String = SiteStore.strongPassword(),
                database: DatabaseConfig) async throws -> Site {
        let name = name.trimmingCharacters(in: .whitespaces)
        let slug = Self.slug(name)
        guard !slug.isEmpty else { throw AppError("Indique um nome para o site.") }
        let adminUser = adminUser.trimmingCharacters(in: .whitespaces)
        guard !adminUser.isEmpty, !adminPassword.isEmpty else { throw AppError("Indique o utilizador e a palavra-passe do site.") }
        var db = database
        if db.name.isEmpty { db.name = Self.cpanelStyleIdentifier() }
        let folder = directory.appendingPathComponent(slug)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw AppError("Já existe uma pasta em \(folder.path).") }
        guard db.engine.isAvailable else { throw AppError("O WordPress não suporta \(db.engine.title).") }

        if db.engine.needsServer {
            var rootSocket: String?
            if db.managed {
                // Como no cPanel: base de dados e utilizador próprios, separados do login do WordPress, gerados ao acaso.
                let server = LocalServer(db)
                try await ensureRunning(server)
                db.host = "127.0.0.1"
                db.port = server.port
                db.user = Self.cpanelStyleIdentifier()
                db.password = Self.strongPassword()
                rootSocket = server.socket
            }
            let verdict = try await DatabaseProbe.run(db, create: true, rootSocket: rootSocket).verdict(for: db)
            guard verdict.ok else { throw AppError(verdict.text) }
        }

        var port = (sites.map(\.port).max() ?? 8900) + 1
        while !Self.isPortFree(port) { port += 1 }
        let site = Site(name: name, path: folder.path, port: port, adminUser: adminUser,
                        adminPassword: adminPassword, wpVersion: Runtime.bundledWordPressVersion, database: db)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: Runtime.wordpress, to: folder)
            if db.engine == .sqlite { try installSQLite(into: folder) }
            try Self.wpConfig(for: db).write(to: folder.appendingPathComponent("wp-config.php"), atomically: true, encoding: .utf8)
            try await Runtime.php([
                Runtime.wpCli.path, "core", "install",
                "--url=\(site.url.absoluteString)", "--title=\(name)",
                "--admin_user=\(site.adminUser)", "--admin_password=\(site.adminPassword)",
                "--admin_email=admin@localhost.test", "--skip-email",
            ], cwd: folder)
        } catch {
            try? fm.removeItem(at: folder) // só apagamos a pasta que nós próprios criámos (confirmado acima que não existia)
            throw error
        }
        sites.append(site)
        try save()
        writeAgentFiles(for: site)
        installLocalHelpers(for: site)
        return site
    }

    /// Instruções para agentes de IA (Claude Code, Codex…) dentro do site, como o Studio faz — mas a apontar para `wpc`.
    /// Só cria o que falta: nunca substitui ficheiros que o utilizador tenha editado.
    func writeAgentFiles(for site: Site) {
        let fm = FileManager.default
        func write(_ name: String, _ text: String) {
            let url = site.folder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let db = site.database
        let dbLine = db.engine.needsServer
            ? "\(db.engine.title) \(db.targetVersion) — base de dados `\(db.name)`, utilizador `\(db.user)`"
            : "\(db.engine.title) — ficheiro `wp-content/database/.ht.sqlite`"

        write("AGENTS.md", """
        # Instruções para agentes de IA

        Este é um site WordPress local gerido pelo WP Center.
        Para trabalhar com este site, segue @WPCENTER.md.
        Se existir um `DESIGN.md`, segue-o em todo o trabalho de design ou conteúdo.

        > Pode editar, acrescentar ou substituir este ficheiro.

        """)
        write("CLAUDE.md", "@AGENTS.md\n")
        write("WPCENTER.md", """
        ## IMPORTANTE: WP-CLI no WP Center

        Quando uma skill ou documentação usar comandos `wp`, corre-os SEMPRE com o prefixo `wpc`:

        - `wp plugin install woocommerce` → `wpc wp plugin install woocommerce`
        - `wp db export` → `wpc wp db export`
        - `wp search-replace` → `wpc wp search-replace`

        Assim usam o PHP e a base de dados deste site. Não uses um `wp` instalado no sistema.

        ## Pré-requisitos

        Antes de usar `wpc`, confirma que existe com `wpc --version`. Se o comando não existir, não corras comandos `wpc` e diz ao utilizador:

        > O comando wpc não está instalado. Abra o WP Center → Definições → ative "Comando wpc no terminal" e abra um novo terminal.

        ## Fluxo de trabalho

        1. `wpc status` — URL, credenciais, versões de PHP/WordPress e base de dados
        2. `wpc start` se o site estiver parado (`wpc stop` para parar)
        3. Edita ficheiros em `wp-content/themes/` ou `wp-content/plugins/`
        4. `wpc wp …` para ativar temas/plugins, limpar caches, etc.
        5. Verifica o resultado no URL do site

        Os comandos usam o site da pasta atual; a partir de outra pasta usa `wpc --path <pasta-do-site> …`.

        ## Este site

        - Endereço: \(site.url.absoluteString)
        - Base de dados: \(dbLine)
        - Produção: o site vai ser migrado para um servidor cPanel com o plugin WPvivid. `wpc export` cria o backup pronto a restaurar lá. Não faças alterações que dependam deste ambiente local (URLs `localhost` escritas à mão, caminhos absolutos do Mac).

        """)
        for dir in [".claude/skills", ".agents/skills"] {
            let target = site.folder.appendingPathComponent(dir)
            guard let skills = try? fm.contentsOfDirectory(at: Runtime.skills, includingPropertiesForKeys: nil) else { continue }
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            for skill in skills where !fm.fileExists(atPath: target.appendingPathComponent(skill.lastPathComponent).path) {
                try? fm.copyItem(at: skill, to: target.appendingPathComponent(skill.lastPathComponent))
            }
        }
    }

    private func installSQLite(into folder: URL) throws {
        let content = folder.appendingPathComponent("wp-content")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Runtime.sqlitePlugin,
                                         to: content.appendingPathComponent("plugins/sqlite-database-integration"))
        let dropIn = try String(contentsOf: Runtime.sqlitePlugin.appendingPathComponent("db.copy"), encoding: .utf8)
            .replacingOccurrences(of: "{SQLITE_IMPLEMENTATION_FOLDER_PATH}", with: "") // o drop-in recorre a wp-content/plugins/…
            .replacingOccurrences(of: "{SQLITE_PLUGIN}", with: "sqlite-database-integration/load.php")
        try dropIn.write(to: content.appendingPathComponent("db.php"), atomically: true, encoding: .utf8)
    }

    static func wpConfig(for db: DatabaseConfig) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        let server = db.engine.needsServer
        let host = db.port == 3306 ? db.host : "\(db.host):\(db.port)"
        let salts = ["AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY",
                     "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT"]
            .map { "define( '\($0)', \(q(randomPassword(length: 64))) );" }
            .joined(separator: "\n")
        return """
        <?php
        // Gerado pelo WP Center. Motor de base de dados: \(db.engine.title)\(db.targetVersion.isEmpty ? "" : " \(db.targetVersion)").
        define( 'DB_NAME', \(q(server ? db.name : "wordpress")) );
        define( 'DB_USER', \(q(server ? db.user : "")) );
        define( 'DB_PASSWORD', \(q(server ? db.password : "")) );
        define( 'DB_HOST', \(q(server ? host : "")) );
        define( 'DB_CHARSET', 'utf8mb4' );
        define( 'DB_COLLATE', '' );

        \(salts)

        $table_prefix = 'wp_';

        define( 'WP_DEBUG', false );
        define( 'WP_ENVIRONMENT_TYPE', 'local' );

        if ( ! defined( 'ABSPATH' ) ) {
        \tdefine( 'ABSPATH', __DIR__ . '/' );
        }
        require_once ABSPATH . 'wp-settings.php';

        """
    }

    // MARK: Servidor

    /// `detached`: usado pelo `wpc start` — o servidor continua a correr depois de o terminal fechar.
    func start(_ site: Site, detached: Bool = false) async {
        guard !isRunning(site) else { return }
        do {
            writeAgentFiles(for: site) // sites criados antes destas funcionalidades também as recebem
            installLocalHelpers(for: site)
            await ensureMailpit()
            if site.database.engine.needsServer && site.database.managed {
                try await ensureRunning(LocalServer(site.database))
            }
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent("\(site.id).log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)

            let p = Process()
            let phpArgs = Runtime.iniArgs + ["-S", "127.0.0.1:\(site.port)", "-t", site.path, Runtime.router.path]
            // nohup faz exec do php (mesmo PID) e ignora o SIGHUP enviado quando o terminal fecha.
            p.executableURL = detached ? URL(fileURLWithPath: "/usr/bin/nohup") : Runtime.php
            p.arguments = detached ? [Runtime.php.path] + phpArgs : phpArgs
            p.currentDirectoryURL = site.folder
            p.environment = ProcessInfo.processInfo.environment.merging(["PHP_CLI_SERVER_WORKERS": "4"]) { $1 }
            p.standardOutput = log
            p.standardError = log
            let id = site.id
            p.terminationHandler = { [weak self] proc in
                try? log.close()
                Task { @MainActor in
                    guard let self, self.processes[id] === proc else { return } // paragem pedida já o removeu
                    self.processes[id] = nil
                    self.errorMessage = "O servidor parou inesperadamente. Registo: \(logURL.path)"
                }
            }
            try p.run()
            processes[id] = p
        } catch {
            errorMessage = "Não foi possível iniciar \(site.name): \(error.localizedDescription)"
        }
    }

    func stop(_ site: Site) {
        if let p = processes.removeValue(forKey: site.id) {
            Self.terminateTree(p)
        } else {
            // Iniciado noutro processo (app ↔ wpc): termina só os PHP que servem esta pasta com o nosso router.
            for pid in Self.serverPIDs(of: site) { kill(pid, SIGTERM) }
        }
        // O PHP demora um instante a libertar a porta: atualiza a interface assim que ela fica livre.
        objectWillChange.send()
        Task {
            for _ in 0..<30 where !Self.isPortFree(site.port) { try? await Task.sleep(for: .milliseconds(100)) }
            objectWillChange.send()
        }
    }

    private static func serverPIDs(of site: Site) -> [pid_t] {
        Runtime.output("/usr/sbin/lsof", ["-t", "-nP", "-iTCP:\(site.port)", "-sTCP:LISTEN"])
            .split(separator: "\n").compactMap { pid_t($0) }
            .filter { pid in
                let command = Runtime.output("/bin/ps", ["-o", "command=", "-p", String(pid)])
                return command.contains(Runtime.router.path) && command.contains(site.path)
            }
    }

    /// Ao sair: guarda que sites estavam a correr (para "Retomar") e para-os, salvo se o utilizador os quiser manter.
    func prepareToQuit() {
        Prefs.lastRunningSites = sites.filter(isRunning).map(\.id)
        if Prefs.quitBehavior == .stop { stopAll() }
    }

    /// Ao abrir: aplica a preferência "Ao abrir o WP Center".
    func applyLaunchBehavior() async {
        let ids: Set<UUID> = switch Prefs.launchBehavior {
        case .none: []
        case .resume: Set(Prefs.lastRunningSites)
        case .all: Set(sites.map(\.id))
        }
        for site in sites where ids.contains(site.id) && !isRunning(site) {
            await start(site)
        }
    }

    func stopAll() {
        processes.values.forEach(Self.terminateTree)
        processes.removeAll()
        databaseServers.values.forEach { $0.terminate() } // SIGTERM: o mysqld/mariadbd encerra de forma limpa
        databaseServers.removeAll()
        mailpit?.terminate()
        mailpit = nil
    }

    // MARK: Emails (Mailpit)

    static let mailpitUI = URL(string: "http://127.0.0.1:8025")!
    private var mailpit: Process?

    /// Arranca o Mailpit incluído na app. Com a porta SMTP já ocupada (o do Homebrew, ou um iniciado pelo `wpc`) usa esse.
    func ensureMailpit() async {
        guard Self.isPortFree(1025) else { return }
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup") // como o `wpc start`: continua depois de o terminal fechar
        p.arguments = [Runtime.mailpit.path, "--smtp", "127.0.0.1:1025", "--listen", "127.0.0.1:8025",
                       "--database", storage.appendingPathComponent("mailpit.db").path,
                       "--disable-version-check", "--block-remote-css-and-fonts"] // nada sai do Mac
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        mailpit = p
        for _ in 0..<30 where Self.isPortFree(8025) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func openMail() async {
        await ensureMailpit()
        Prefs.openInBrowser(Self.mailpitUI)
    }

    // MARK: Servidor de base de dados local

    @Published private(set) var databaseServers: [LocalServer: Process] = [:]

    /// Instala a versão escolhida com o Homebrew (só quando o utilizador carrega em "Instalar").
    func install(_ server: LocalServer) async throws {
        guard let brew = LocalServer.brew else {
            throw AppError("O Homebrew não está instalado. Instale-o em brew.sh e tente novamente.")
        }
        let (status, out) = try await Runtime.exec(brew, ["install", server.formula], env: ["HOMEBREW_NO_ENV_HINTS": "1"])
        guard status == 0, server.isInstalled else {
            throw AppError("A instalação de \(server.title) falhou:\n\(out.suffix(600))")
        }
    }

    /// Inicializa (na primeira vez) e arranca o servidor; não faz nada se já estiver a correr.
    func ensureRunning(_ server: LocalServer) async throws {
        if !Self.isPortFree(server.port), FileManager.default.fileExists(atPath: server.socket) { return }
        guard server.isInstalled, let daemon = server.daemon, let prefix = server.prefix else {
            throw AppError("\(server.title) não está instalado neste Mac.")
        }
        guard Self.isPortFree(server.port) else {
            throw AppError("A porta \(server.port), reservada para \(server.title), está ocupada por outra aplicação.")
        }
        let dir = storage.appendingPathComponent("Databases/\(server.formula)")
        let data = dir.appendingPathComponent("data")
        if !FileManager.default.fileExists(atPath: data.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Utilizador root sem palavra-passe, acessível só pelo socket local; os sites usam utilizadores próprios.
            let (status, out) = server.engine == .mariadb
                ? try await Runtime.exec(prefix.appendingPathComponent("bin/mariadb-install-db"), [
                    "--no-defaults", "--basedir=\(prefix.path)", "--datadir=\(data.path)",
                    "--auth-root-authentication-method=normal", "--skip-test-db",
                ])
                : try await Runtime.exec(daemon, [
                    "--no-defaults", "--initialize-insecure", "--basedir=\(prefix.path)", "--datadir=\(data.path)",
                ])
            guard status == 0 else {
                try? FileManager.default.removeItem(at: data) // só a pasta de dados vazia que acabámos de criar
                throw AppError("Não foi possível preparar \(server.title):\n\(out.suffix(600))")
            }
        }

        let errorLog = dir.appendingPathComponent("error.log")
        let p = Process()
        p.executableURL = daemon
        p.arguments = [
            "--no-defaults", "--basedir=\(prefix.path)", "--datadir=\(data.path)",
            "--port=\(server.port)", "--bind-address=127.0.0.1", "--socket=\(server.socket)",
            "--log-error=\(errorLog.path)", "--pid-file=\(dir.appendingPathComponent("server.pid").path)",
            // Sem isto o MySQL 8 usa utf8mb4_0900_ai_ci (que o MariaDB do cPanel recusa) e o MariaDB usa latin1:
            // plugins que criam tabelas sem colação ficam assim compatíveis com os dois.
            "--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci",
        ] + (server.engine == .mysql ? ["--mysqlx=OFF"] : [])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        databaseServers[server] = p

        for _ in 0..<120 { // até 60 s: a primeira inicialização do MySQL pode demorar
            if !Self.isPortFree(server.port), FileManager.default.fileExists(atPath: server.socket) { return }
            if !p.isRunning { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        p.terminate()
        databaseServers[server] = nil
        throw AppError("\(server.title) não arrancou. Registo: \(errorLog.path)")
    }

    /// Com PHP_CLI_SERVER_WORKERS o `php -S` cria processos filhos que sobrevivem a um SIGTERM ao pai.
    private static func terminateTree(_ p: Process) {
        guard p.isRunning else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-TERM", "-P", String(p.processIdentifier)]
        try? kill.run()
        kill.waitUntilExit()
        p.terminate()
    }

    // MARK: Acesso ao wp-admin

    /// Instala/atualiza os mu-plugins de entrada automática e de emails (só funcionam localmente; nunca vão na exportação).
    func installLocalHelpers(for site: Site) {
        let dir = site.folder.appendingPathComponent("wp-content/mu-plugins")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for helper in [Runtime.autologin, Runtime.mailPlugin] {
            let target = dir.appendingPathComponent(helper.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: helper, to: target)
        }
    }

    private struct AccessResult: Decodable {
        let ok: Bool
        var error: String?
        var user: String?
        var valid: Bool?
    }

    /// Corre wpcenter-access.php no site. Segredos só por variáveis de ambiente.
    private func access(_ site: Site, _ action: String, _ env: [String: String] = [:]) async throws -> AccessResult {
        if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        let (_, output) = try await Runtime.phpStatus([Runtime.wpCli.path, "eval-file", Runtime.access.path], cwd: site.folder,
                                                      env: env.merging(["WPCENTER_ACTION": action, "WPCENTER_USER": site.adminUser]) { $1 })
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(AccessResult.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else { throw AppError("O WordPress não respondeu:\n\(output.suffix(600))") }
        guard result.ok else { throw AppError(result.error ?? "Falhou.") }
        return result
    }

    /// URL de entrada no wp-admin com um código aleatório de uso único, válido 60 s, guardado no site só como hash.
    func adminLoginURL(_ site: Site) async throws -> URL {
        installLocalHelpers(for: site)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError("Sem aleatoriedade segura.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        _ = try await access(site, "login", ["WPCENTER_TOKEN": token])
        var components = URLComponents(url: site.url.appendingPathComponent("wp-admin/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wpcenter_login", value: token)]
        return components.url!
    }

    /// Abre o wp-admin já com sessão iniciada (inicia o site se estiver parado).
    func openAdmin(_ site: Site) async {
        if !isRunning(site) { await start(site) }
        do {
            Prefs.openInBrowser(try await adminLoginURL(site))
        } catch {
            Prefs.openInBrowser(site.url.appendingPathComponent("wp-admin/"))
            errorMessage = "Não foi possível entrar automaticamente: \(error.localizedDescription)"
        }
    }

    /// nil = não foi possível verificar (p.ex. base de dados indisponível).
    func credentialsAreValid(_ site: Site) async -> Bool? {
        try? await access(site, "check", ["WPCENTER_PASS": site.adminPassword]).valid
    }

    /// Nova palavra-passe para o administrador (o guardado, ou o primeiro do site depois de um restauro).
    /// Muda o nome mostrado na app e, opcionalmente, o título do site no WordPress (opção `blogname`).
    /// A pasta mantém-se: mudá-la partiria caminhos guardados e a ligação à base de dados.
    func rename(_ site: Site, to newName: String, updateWordPress: Bool) async throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError("Indique um nome.") }
        if updateWordPress {
            if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
            try await Runtime.php([Runtime.wpCli.path, "option", "update", "blogname", name], cwd: site.folder)
        }
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[index].name = name
        try save()
    }

    func resetAccess(_ site: Site) async throws {
        let password = Self.strongPassword()
        let result = try await access(site, "reset", ["WPCENTER_PASS": password])
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[index].adminUser = result.user ?? site.adminUser
        sites[index].adminPassword = password
        try save()
    }

    // MARK: Exportar para cPanel

    struct ExportResult: Decodable {
        let ok: Bool
        let error: String
        let dir: String
        let files: [String]
        let excluded: [String]

        var folder: URL { URL(fileURLWithPath: dir) }
        var totalBytes: Int64 {
            files.reduce(0) { sum, name in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size]) as? Int64
                return sum + (size ?? 0)
            }
        }
    }

    /// Backup feito pelo próprio WPvivid do site (o mesmo plugin que restaura no cPanel), sem o que só existe no Mac.
    /// Os ficheiros ficam em <pasta de exportações (Descargas por omissão)>/<site>-<data>.
    /// Tabelas com colação exclusiva do MySQL 8 tornam o backup impossível de restaurar num cPanel com MariaDB.
    struct IncompatibleCollationError: LocalizedError {
        let tables: [String]
        var errorDescription: String? {
            "\(tables.count) tabela\(tables.count == 1 ? "" : "s") usa\(tables.count == 1 ? "" : "m") uma colação só do MySQL 8 (utf8mb4_0900_*), "
                + "que o MariaDB do cPanel recusa: \(tables.joined(separator: ", "))."
        }
    }

    private struct CollationResult: Decodable {
        let ok: Bool
        var error: String?
        var tables: [String]?
        var converted: [String]?
    }

    /// check: devolve as tabelas incompatíveis; convert: converte-as para utf8mb4_unicode_ci e devolve as convertidas.
    @discardableResult
    func collation(_ site: Site, convert: Bool) async throws -> [String] {
        if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        let (_, output) = try await Runtime.phpStatus([Runtime.wpCli.path, "eval-file", Runtime.collation.path], cwd: site.folder,
                                                      env: ["WPCENTER_ACTION": convert ? "convert" : "check"])
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(CollationResult.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else { throw AppError("Não foi possível verificar a base de dados:\n\(output.suffix(600))") }
        guard result.ok else { throw AppError(result.error ?? "Falhou.") }
        return (convert ? result.converted : result.tables) ?? []
    }

    /// check: recusa exportar se houver colações só do MySQL 8; convert: converte-as antes; ignore: exporta como está
    /// (para um cPanel com MySQL 8, onde essas colações existem).
    enum CollationPolicy { case check, convert, ignore }

    func exportForCPanel(_ site: Site, collations: CollationPolicy = .check, to directory: URL = Prefs.exportDirectory) async throws -> ExportResult {
        guard site.database.engine.needsServer else {
            throw AppError("Este site usa SQLite. O cPanel precisa de MySQL ou MariaDB: crie o site com MariaDB/MySQL para o poder exportar.")
        }
        if site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        if collations != .ignore {
            let incompatible = try await collation(site, convert: false)
            if !incompatible.isEmpty {
                guard collations == .convert else { throw IncompatibleCollationError(tables: incompatible) }
                try await collation(site, convert: true)
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: Date())
        let target = directory.appendingPathComponent("\(site.folder.lastPathComponent)-\(stamp)")
        let (_, output) = try await Runtime.phpStatus([Runtime.wpCli.path, "eval-file", Runtime.wpvividExport.path],
                                                      cwd: site.folder, env: ["WPCENTER_EXPORT_DIR": target.path])
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(ExportResult.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else {
            throw AppError("O backup do WPvivid falhou:\n\(output.suffix(800))")
        }
        guard result.ok else { throw AppError(result.error) }
        return result
    }

    // MARK: Apagar

    /// Move a pasta para o Lixo (reversível). Bases de dados MySQL/MariaDB nunca são apagadas.
    func delete(_ site: Site) async {
        stop(site)
        if FileManager.default.fileExists(atPath: site.path) {
            do { try await NSWorkspace.shared.recycle([site.folder]) } catch {
                errorMessage = "Não foi possível mover \(site.path) para o Lixo: \(error.localizedDescription)"
                return
            }
        }
        sites.removeAll { $0.id == site.id }
        try? save()
    }

    // MARK: Utilitários

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    private func save() throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Self.encoder.encode(sites).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) // contém palavras-passe
    }

    /// "localhost" pode resolver para 127.0.0.1 ou ::1 — a porta tem de estar livre nos dois (o Studio, p.ex., escuta só em ::1).
    static func isPortFree(_ port: Int) -> Bool {
        func canBind(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            // Sem SO_REUSEADDR, ligações antigas em TIME_WAIT (~30 s depois de parar) fazem a porta parecer ocupada.
            // Com ele, o bind continua a falhar se houver de facto um servidor à escuta.
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = in_port_t(UInt16(port).bigEndian)
                a.sin_addr.s_addr = inet_addr("127.0.0.1")
                return withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
                }
            }
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(UInt16(port).bigEndian)
            a.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
        return canBind(AF_INET) && canBind(AF_INET6)
    }

    /// Regras do cPanel (docs.cpanel.net, "Manage My Databases", v132+): `prefixo_nome`, minúsculas e números;
    /// base de dados ≤ 64 caracteres (cada `_` conta 2), utilizador ≤ 32 no MySQL e ≤ 47 no MariaDB.
    /// "wpc" faz de prefixo da conta; um só `_` e 10 caracteres aleatórios → 15 de 32. Serve para nome e utilizador.
    nonisolated static func cpanelStyleIdentifier() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789") // sem 0/o/1/l, fáceis de confundir
        var rng = SystemRandomNumberGenerator()
        return "wpc_" + String((0..<10).map { _ in chars.randomElement(using: &rng)! })
    }

    /// Palavra-passe forte: maiúsculas, minúsculas, números e símbolos (pelo menos um de cada), sem aspas nem `\`.
    nonisolated static func strongPassword(length: Int = 24) -> String {
        let sets = [Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), Array("abcdefghijkmnpqrstuvwxyz"), Array("23456789"), Array("!#%*()-_=+[]{}.,:;?~@^")]
        var rng = SystemRandomNumberGenerator()
        let all = sets.flatMap { $0 }
        let picked = sets.map { $0.randomElement(using: &rng)! } + (0..<(length - sets.count)).map { _ in all.randomElement(using: &rng)! }
        return String(picked.shuffled(using: &rng))
    }

    /// Utilizador do WordPress sugerido: o nome curto da conta do Mac (evita o "admin", o mais atacado).
    static var defaultAdminUser: String {
        let user = NSUserName().lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return user.isEmpty ? "administrador" : user
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    nonisolated static func randomPassword(length: Int = 20) -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars.randomElement(using: &rng)! })
    }
}
