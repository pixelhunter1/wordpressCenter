import AppKit
import Foundation
import Security

/// Habilidades para agentes de IA copiadas para cada site (Definições → Habilidades). O build.sh copia-as do Studio
/// e de Runtime/skills: a wp-center (nossa) e as do WordPress/agent-skills que o Studio não traz.
struct AgentSkill: Identifiable {
    let id: String // nome da pasta em runtime/skills e em .claude|.agents/skills
    let title: String
    let summary: String

    static let all = [
        AgentSkill(id: "wp-center", title: L("WP Center e cPanel"), summary: L("wpc, emails no Mailpit, colações e exportação para o cPanel")),
        AgentSkill(id: "wordpress-router", title: L("Encaminhamento WordPress"), summary: L("Classifica o projeto e escolhe a habilidade certa")),
        AgentSkill(id: "wp-project-triage", title: L("Diagnóstico do projeto"), summary: L("Relatório do tipo de projeto, ferramentas e testes")),
        AgentSkill(id: "wp-plugin-development", title: L("Desenvolvimento de plugins"), summary: L("Hooks, Settings API, segurança e empacotamento")),
        AgentSkill(id: "wp-block-development", title: L("Desenvolvimento de blocos"), summary: L("block.json, atributos, renderização e deprecações")),
        AgentSkill(id: "wp-block-themes", title: L("Temas de blocos"), summary: L("theme.json, templates, padrões e variações de estilo")),
        AgentSkill(id: "wp-rest-api", title: "REST API", summary: L("Rotas, endpoints, schema e autenticação")),
        AgentSkill(id: "wp-wpcli-and-ops", title: L("WP-CLI e operações"), summary: L("Comandos, automação e search-replace, através do wpc wp")),
        AgentSkill(id: "wp-performance", title: L("Desempenho do servidor"), summary: L("Perfis com WP-CLI, consultas, autoload, cache e cron")),
        AgentSkill(id: "wp-phpstan", title: "PHPStan", summary: L("Análise estática: phpstan.neon, baselines e tipos do WordPress")),
        AgentSkill(id: "need-for-speed", title: L("Desempenho"), summary: L("Auditoria de velocidade do site com recomendações")),
        AgentSkill(id: "rank-me-up", title: "SEO", summary: L("Auditoria de SEO on-page com recomendações")),
        AgentSkill(id: "visual-design", title: L("Design visual"), summary: L("Direção visual: layout, tipografia, cor e imagens")),
    ]
}

/// Texto traduzido para a língua do Mac (en.lproj; em português a própria chave).
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Runtime.strings)
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String.LocalizationValue) { self.message = L(message) }
    /// Texto que já vem pronto (saída de um comando, erro já traduzido).
    init(verbatim message: String) { self.message = message }
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

    /// "pt" num Mac em português, "en" em qualquer outra língua. Escolhida à mão: como `wpc`, o Bundle.main não tem
    /// línguas e o macOS alinharia o bundle da app por ele, ficando sempre em inglês.
    static let language = Bundle.preferredLocalizations(from: appBundle.localizations, forPreferences: Locale.preferredLanguages).first ?? "en"
    static let strings = appBundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? appBundle
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
    static var sharePlugin: URL { root.appendingPathComponent("wpcenter-share.php") }
    static var updatesPlugin: URL { root.appendingPathComponent("wpcenter-updates.php") }
    static var tools: URL { root.appendingPathComponent("wpcenter-tools.php") }
    static var cloudflared: URL { root.appendingPathComponent("cloudflared") }

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

    /// Corre o PHP (o incluído, ou o do site) e devolve stdout+stderr. Lança erro com a saída se o código de saída não for 0.
    @discardableResult
    static func php(_ args: [String], cwd: URL? = nil, env: [String: String] = [:], using php: URL = Runtime.php) async throws -> String {
        let (status, out) = try await phpStatus(args, cwd: cwd, env: env, using: php)
        guard status == 0 else { throw out.isEmpty ? AppError("O PHP terminou com o código \(status).") : AppError(verbatim: out) }
        return out
    }

    static func phpStatus(_ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                          using php: URL = Runtime.php) async throws -> (Int32, String) {
        try await exec(php, iniArgs + args, cwd: cwd, env: env)
    }

    /// Corre um executável até terminar e devolve (código de saída, stdout+stderr).
    static func exec(_ executable: URL, _ args: [String], cwd: URL? = nil, env: [String: String] = [:]) async throws -> (Int32, String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            p.currentDirectoryURL = cwd
            // WPCENTER_LANG: os scripts respondem na língua da app (en ou pt).
            p.environment = ProcessInfo.processInfo.environment
                .merging(["WPCENTER_LANG": Runtime.language]) { $1 }
                .merging(env) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe // um só pipe: evita bloqueio quando um dos buffers enche
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    static var bundledWordPressVersion: String { wordPressVersion(at: wordpress) }

    static func wordPressVersion(at root: URL) -> String {
        let file = root.appendingPathComponent("wp-includes/version.php")
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
        guard ok, let engine, let version else { return (false, error ?? L("Falha na ligação.")) }
        if engine != db.engine {
            return (false, L("O servidor é \(engine.title) \(version), mas escolheu \(db.engine.title)."))
        }
        if let tables, tables > 0 {
            return (false, L("A base de dados \"\(db.name)\" já tem \(tables) tabelas wp_. Use uma base de dados vazia."))
        }
        if !db.engine.cpanelVersions.contains(version) {
            return (true, L("Ligado a \(engine.title) \(version). Atenção: esta versão não está na lista do cPanel."))
        }
        if version != db.targetVersion {
            return (true, L("Ligado a \(engine.title) \(version) (escolheu \(db.targetVersion) como alvo)."))
        }
        return (true, L("Ligado a \(engine.title) \(version)."))
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
    /// nil nos sites criados antes da escolha de PHP: usam o incluído na app.
    var phpVersion: String?

    var url: URL { URL(string: "http://localhost:\(port)")! }
    var folder: URL { URL(fileURLWithPath: path) }
    var php: String { phpVersion ?? PHPVersions.bundled }

    /// O executável do PHP do site; erro claro se essa versão ainda não estiver instalada neste Mac.
    func phpExecutable() throws -> URL {
        guard let url = PHPVersions.binary(php) else {
            throw AppError("O PHP \(php) não está instalado neste Mac. Instale-o em Definições → Avançado.")
        }
        return url
    }
}

/// Versões de PHP para os sites: as do cPanel (EasyApache 4). A 8.4 vem dentro da app; as outras instalam-se
/// com o Homebrew só quando o utilizador as pede, como os servidores de base de dados.
enum PHPVersions {
    static let bundled = "8.4"
    static let all = ["8.1", "8.2", "8.3", "8.4", "8.5"]

    static func formula(_ version: String) -> String { "php@\(version)" }

    /// "8.4.26" para a incluída (versão exata), "8.3" para as do Homebrew.
    static func display(_ version: String) -> String { version == bundled ? Runtime.phpVersion : version }

    static func binary(_ version: String) -> URL? {
        if version == bundled { return Runtime.php }
        guard let opt = LocalServer.brew?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("opt") else {
            return nil
        }
        // A versão mais recente (p.ex. 8.5) é a fórmula "php", e php@8.5 só um alias: pode só existir opt/php.
        for name in [formula(version), "php"] {
            let bin = opt.appendingPathComponent("\(name)/bin/php")
            guard FileManager.default.isExecutableFile(atPath: bin.path) else { continue }
            if name == "php", !opt.appendingPathComponent("php").resolvingSymlinksInPath().lastPathComponent.hasPrefix(version + ".") {
                continue
            }
            return bin
        }
        return nil
    }

    static func isInstalled(_ version: String) -> Bool { binary(version) != nil }
}

@MainActor
final class SiteStore: ObservableObject {
    static let shared = SiteStore(storage: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WP Center"))

    @Published private(set) var sites: [Site] = []
    @Published private(set) var processes: [UUID: Process] = [:]
    @Published var errorMessage: String?
    /// Pedido de um menu para a janela principal: Definições (⌘,), Novo site (⌘N), importar, referência do cPanel (Ajuda).
    enum WindowRequest { case settings, newSite, importSites, connectLive, cpanel }
    @Published var windowRequest: WindowRequest?

    let storage: URL
    private var file: URL { storage.appendingPathComponent("sites.json") }
    var logs: URL { storage.appendingPathComponent("Logs") }

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
                database: DatabaseConfig, php: String = PHPVersions.bundled) async throws -> Site {
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

        if db.engine.needsServer { try await prepareDatabase(&db) }

        let site = Site(name: name, path: folder.path, port: nextFreePort(), adminUser: adminUser,
                        adminPassword: adminPassword, wpVersion: Runtime.bundledWordPressVersion, database: db, phpVersion: php)
        let phpBinary = try site.phpExecutable()
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
            ], cwd: folder, using: phpBinary)
        } catch {
            try? fm.removeItem(at: folder) // só apagamos a pasta que nós próprios criámos (confirmado acima que não existia)
            throw error
        }
        try add(site)
        return site
    }

    /// Cria a base de dados vazia. Num servidor gerido, como no cPanel: base de dados e utilizador próprios,
    /// separados do login do WordPress, gerados ao acaso.
    func prepareDatabase(_ db: inout DatabaseConfig) async throws {
        var rootSocket: String?
        if db.managed {
            let server = LocalServer(db)
            try await ensureRunning(server)
            db.host = "127.0.0.1"
            db.port = server.port
            db.user = Self.cpanelStyleIdentifier()
            db.password = Self.strongPassword()
            rootSocket = server.socket
        }
        let verdict = try await DatabaseProbe.run(db, create: true, rootSocket: rootSocket).verdict(for: db)
        guard verdict.ok else { throw AppError(verbatim: verdict.text) }
    }

    func nextFreePort() -> Int {
        var port = (sites.map(\.port).max() ?? 8900) + 1
        while !Self.isPortFree(port) { port += 1 }
        return port
    }

    /// Acrescenta um site já pronto na pasta (usado pela importação).
    func add(_ site: Site) throws {
        sites.append(site)
        try save()
        writeAgentFiles(for: site)
        installLocalHelpers(for: site)
    }

    /// Instruções para agentes de IA (Claude Code, Codex…) dentro do site, como o Studio faz — mas a apontar para `wpc`.
    /// Só cria o que falta (nunca substitui o que o utilizador editou), exceto o WPCENTER.md: é da app e é reescrito
    /// quando muda (comandos novos, outro endereço depois de importar ou duplicar).
    func writeAgentFiles(for site: Site) {
        let fm = FileManager.default
        func write(_ name: String, _ text: String, replace: Bool = false) {
            let url = site.folder.appendingPathComponent(name)
            let current = try? String(contentsOf: url, encoding: .utf8)
            if replace ? current != text : !fm.fileExists(atPath: url.path) {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
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
        > Gerido pelo WP Center: a app reescreve este ficheiro. Instruções próprias vão no AGENTS.md.

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

        1. `wpc context` — tema, construtor, plugins ativos, conteúdo e WooCommerce: lê-o antes de mexer no site
        2. `wpc status` — URL, credenciais, versões de PHP/WordPress e base de dados
        3. `wpc start` se o site estiver parado (`wpc stop` para parar)
        4. Edita ficheiros em `wp-content/themes/` ou `wp-content/plugins/`
        5. `wpc wp …` para ativar temas/plugins, criar conteúdo, etc.
        6. `wpc flush` se uma alteração não aparecer (caches de objetos, transients, ligações permanentes, Elementor, plugins de cache)
        7. Verifica o resultado no URL do site

        Os comandos usam o site da pasta atual; a partir de outra pasta usa `wpc --path <pasta-do-site> …`.

        ## Verificar o trabalho

        - `wpc login-url [página]` — link de entrada no wp-admin já com sessão iniciada (p.ex. `wpc login-url plugins.php`), de uso único e válido 60 s; inicia o site se for preciso. Abre-o no navegador que controlas para ver ou testar o painel.
        - `wpc logs` — erros recentes do PHP e do `wp-content/debug.log`. Para registar tudo: `wpc wp config set WP_DEBUG true --raw`, `wpc wp config set WP_DEBUG_LOG true --raw` e `wpc wp config set WP_DEBUG_DISPLAY false --raw`; no fim volta a pôr `WP_DEBUG` a `false`.
        - `wpc mail` — emails enviados pelos sites (formulários, encomendas), apanhados neste Mac; `wpc mail <ID>` mostra o texto de um.
        - `wpc duplicate --name "…"` — cópia completa do site (ficheiros e base de dados) antes de uma alteração arriscada.
        - `--json` em `wpc status`, `wpc list`, `wpc context` e `wpc mail` dá um resultado fácil de ler num script.

        ## Este site

        - Endereço: \(site.url.absoluteString)
        - Base de dados: \(dbLine)
        - Produção: o site vai ser migrado para um servidor cPanel com o plugin WPvivid. `wpc export` cria o backup pronto a restaurar lá. Não faças alterações que dependam deste ambiente local (URLs `localhost` escritas à mão, caminhos absolutos do Mac).

        """, replace: true)
        syncSkills(for: site)
    }

    /// Copia para o site as habilidades ativas que faltam e apaga as desligadas, como o Studio.
    /// Só mexe nas do catálogo: habilidades que o utilizador tenha posto no site ficam intactas.
    func syncSkills(for site: Site, enabled: Set<String> = Prefs.enabledSkills) {
        let fm = FileManager.default
        for dir in [".claude/skills", ".agents/skills"] {
            let target = site.folder.appendingPathComponent(dir)
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            for skill in AgentSkill.all {
                let dest = target.appendingPathComponent(skill.id)
                if !enabled.contains(skill.id) {
                    try? fm.removeItem(at: dest)
                } else if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: Runtime.skills.appendingPathComponent(skill.id), to: dest)
                }
            }
        }
    }

    /// Depois de ligar/desligar uma habilidade nas Definições: aplica a todos os sites.
    func syncSkillsInAllSites() { sites.forEach { syncSkills(for: $0) } }

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

    /// Texto entre plicas para um ficheiro PHP.
    static func phpQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }

    static func wpConfig(for db: DatabaseConfig) -> String {
        let q = phpQuote
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
        // Sem atualizações em segundo plano: contactam o wordpress.org e deixam o site em 503 "Maintenance" a meio.
        // Continua a ser possível atualizar à mão no Painel. O wp-config não vai no backup WPvivid.
        define( 'AUTOMATIC_UPDATER_DISABLED', true );

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

            let php = try site.phpExecutable()
            let p = Process()
            let phpArgs = Runtime.iniArgs + ["-S", "127.0.0.1:\(site.port)", "-t", site.path, Runtime.router.path]
            // nohup faz exec do php (mesmo PID) e ignora o SIGHUP enviado quando o terminal fecha.
            p.executableURL = detached ? URL(fileURLWithPath: "/usr/bin/nohup") : php
            p.arguments = detached ? [php.path] + phpArgs : phpArgs
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
                    self.errorMessage = L("O servidor parou inesperadamente. Registo: \(logURL.path)")
                }
            }
            try p.run()
            processes[id] = p
        } catch {
            errorMessage = L("Não foi possível iniciar \(site.name): \(error.localizedDescription)")
        }
    }

    func stop(_ site: Site) {
        stopSharing(site) // o link nunca fica aberto para um site parado
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
        stopAllSharing() // mesmo com "Manter os sites a correr": nada fica público sem a app aberta
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
        stopAllSharing()
        processes.values.forEach(Self.terminateTree)
        processes.removeAll()
        databaseServers.values.forEach { $0.terminate() } // SIGTERM: o mysqld/mariadbd encerra de forma limpa
        databaseServers.removeAll()
        mailpit?.terminate()
        mailpit = nil
    }

    // MARK: Partilha (Cloudflare Quick Tunnel)

    /// Link público de um site. `url` fica nil enquanto o link ainda não existe no DNS.
    struct SiteShare {
        let process: Process
        var url: URL?
    }

    @Published private(set) var shares: [Site.ID: SiteShare] = [:]

    /// Abre um link https://….trycloudflare.com para o site, iniciando-o se estiver parado.
    /// É a única ligação para fora do Mac, e só a pedido: sem conta, termina com stopSharing, ao parar o site ou ao sair.
    func share(_ site: Site) async {
        guard shares[site.id] == nil else { return }
        if !isRunning(site) { await start(site) }
        guard isRunning(site) else { return }
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent("\(site.id)-partilha.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL) // num ficheiro: um pipe por ler encheria e bloquearia o túnel

            let p = Process()
            p.executableURL = Runtime.cloudflared
            p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(site.port)"]
            p.standardOutput = log
            p.standardError = log
            let id = site.id, name = site.name
            p.terminationHandler = { [weak self] proc in
                try? log.close()
                Task { @MainActor in
                    guard let self, self.shares[id]?.process === proc else { return } // terminada a pedido
                    self.shares[id] = nil
                    self.errorMessage = L("O link de partilha de \(name) fechou inesperadamente. Registo: \(logURL.path)")
                }
            }
            try p.run()
            shares[id] = SiteShare(process: p)

            var url: URL?
            for _ in 0..<120 where url == nil && shares[id]?.process === p { // até 30 s
                try? await Task.sleep(for: .milliseconds(250))
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                url = text.firstMatch(of: #/https://[a-z0-9-]+\.trycloudflare\.com/#).flatMap { URL(string: String($0.output)) }
            }
            guard shares[id]?.process === p else { return } // terminada enquanto abria
            guard let url, let host = url.host else {
                stopSharing(site)
                errorMessage = L("Não foi possível criar o link de partilha. Confirme a ligação à internet. Registo: \(logURL.path)")
                return
            }
            // Perguntar ao DNS do sistema antes de o nome existir deixa a resposta "não existe" em cache uns minutos
            // (o "Abrir" falhava): espera que o DNS público da Cloudflare já o conheça.
            for _ in 0..<30 where shares[id]?.process === p {
                if await Self.resolvesPublicly(host) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard shares[id]?.process === p else { return }
            shares[id]?.url = url
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        } catch {
            stopSharing(site)
            errorMessage = L("Não foi possível partilhar \(site.name): \(error.localizedDescription)")
        }
    }

    func stopSharing(_ site: Site) {
        shares.removeValue(forKey: site.id)?.process.terminate()
    }

    private func stopAllSharing() {
        shares.values.forEach { $0.process.terminate() }
        shares.removeAll()
    }

    /// DNS-over-HTTPS no 1.1.1.1: não passa pela cache do Mac nem do router.
    private static func resolvesPublicly(_ host: String) async -> Bool {
        var components = URLComponents(string: "https://1.1.1.1/dns-query")!
        components.queryItems = [.init(name: "name", value: host), .init(name: "type", value: "A")]
        var request = URLRequest(url: components.url!, timeoutInterval: 5)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["Answer"] as? [Any])?.isEmpty == false
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
        let (status, out) = try await brew(["install", server.formula])
        guard status == 0, server.isInstalled else {
            throw AppError("A instalação de \(server.title) falhou:\n\(String(out.suffix(600)))")
        }
    }

    func installPHP(_ version: String) async throws {
        let (status, out) = try await brew(["install", PHPVersions.formula(version)])
        guard status == 0, PHPVersions.isInstalled(version) else {
            throw AppError("A instalação do PHP \(version) falhou:\n\(String(out.suffix(600)))")
        }
    }

    /// Sites que usam este servidor: enquanto houver algum, não se pode remover.
    func isInUse(_ server: LocalServer) -> Bool {
        sites.contains { $0.database.engine.needsServer && $0.database.managed && LocalServer($0.database) == server }
    }

    func isInUse(php version: String) -> Bool { sites.contains { $0.php == version } }

    /// Remove os binários; a pasta de dados (Databases/<fórmula>) fica, com as bases de dados já criadas.
    func uninstall(_ server: LocalServer) async throws {
        guard !isInUse(server) else { throw AppError("\(server.title) ainda é usado por um site.") }
        guard Self.isPortFree(server.port) else { throw AppError("\(server.title) está a correr. Pare os sites que o usam primeiro.") }
        let (status, out) = try await brew(["uninstall", server.formula])
        guard status == 0 else { throw AppError("Não foi possível remover \(server.title):\n\(String(out.suffix(600)))") }
    }

    func uninstallPHP(_ version: String) async throws {
        guard version != PHPVersions.bundled else { return } // vem dentro da app
        guard !isInUse(php: version) else { throw AppError("O PHP \(version) ainda é usado por um site.") }
        let (status, out) = try await brew(["uninstall", PHPVersions.formula(version)])
        guard status == 0 else { throw AppError("Não foi possível remover o PHP \(version):\n\(String(out.suffix(600)))") }
    }

    /// Só corre quando o utilizador carrega em Instalar ou Remover.
    private func brew(_ args: [String]) async throws -> (Int32, String) {
        guard let brew = LocalServer.brew else {
            throw AppError("O Homebrew não está instalado. Instale-o em brew.sh e tente novamente.")
        }
        defer { objectWillChange.send() } // estado de instalado/por instalar
        return try await Runtime.exec(brew, args, env: ["HOMEBREW_NO_ENV_HINTS": "1"])
    }

    /// Inicializa (na primeira vez) e arranca o servidor; não faz nada se já estiver a correr.
    func ensureRunning(_ server: LocalServer) async throws {
        let dir = storage.appendingPathComponent("Databases/\(server.formula)")
        let pidFile = dir.appendingPathComponent("server.pid")
        // A porta e o socket são fixos por versão: só reutilizamos o servidor se for desta pasta de estado (o pid-file
        // está vivo). Sem isto o --selftest criava as suas bases de dados no servidor da app, se este arrancasse a meio.
        if !Self.isPortFree(server.port), FileManager.default.fileExists(atPath: server.socket),
           let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
           kill(pid, 0) == 0 { return }
        guard server.isInstalled, let daemon = server.daemon, let prefix = server.prefix else {
            throw AppError("\(server.title) não está instalado neste Mac.")
        }
        guard Self.isPortFree(server.port) else {
            throw AppError("A porta \(server.port), reservada para \(server.title), está ocupada por outra aplicação.")
        }
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
                throw AppError("Não foi possível preparar \(server.title):\n\(String(out.suffix(600)))")
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
        for helper in [Runtime.autologin, Runtime.mailPlugin, Runtime.sharePlugin, Runtime.updatesPlugin] {
            let target = dir.appendingPathComponent(helper.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: helper, to: target)
        }
    }

    struct AccessResult: Decodable {
        let ok: Bool
        var error: String?
        var user: String?
        var valid: Bool?
    }

    /// Corre wpcenter-access.php no site. Segredos só por variáveis de ambiente.
    func access(_ site: Site, _ action: String, _ env: [String: String] = [:]) async throws -> AccessResult {
        if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        let (_, output) = try await Runtime.phpStatus([Runtime.wpCli.path, "eval-file", Runtime.access.path], cwd: site.folder,
                                                      env: env.merging(["WPCENTER_ACTION": action, "WPCENTER_USER": site.adminUser]) { $1 },
                                                      using: site.phpExecutable())
        let result: AccessResult = try Self.decodeResult(output)
        guard result.ok else { throw result.error.map { AppError(verbatim: $0) } ?? AppError("Falhou.") }
        return result
    }

    /// A linha "WPCENTER_RESULT {json}" que os scripts PHP escrevem no fim.
    static func decodeResult<T: Decodable>(_ output: String) throws -> T {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(T.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else { throw AppError("O WordPress não respondeu:\n\(String(output.suffix(600)))") }
        return result
    }

    /// URL de entrada no wp-admin com um código aleatório de uso único, válido 60 s, guardado no site só como hash.
    /// `page`: a página do wp-admin onde entrar (p.ex. "update-core.php").
    func adminLoginURL(_ site: Site, page: String = "") async throws -> URL {
        installLocalHelpers(for: site)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError("Sem aleatoriedade segura.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        _ = try await access(site, "login", ["WPCENTER_TOKEN": token])
        var components = URLComponents(url: site.url.appendingPathComponent("wp-admin/" + page), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wpcenter_login", value: token)]
        return components.url!
    }

    /// Abre o wp-admin já com sessão iniciada (inicia o site se estiver parado).
    func openAdmin(_ site: Site, page: String = "") async {
        if !isRunning(site) { await start(site) }
        do {
            Prefs.openInBrowser(try await adminLoginURL(site, page: page))
        } catch {
            Prefs.openInBrowser(site.url.appendingPathComponent("wp-admin/" + page))
            errorMessage = L("Não foi possível entrar automaticamente: \(error.localizedDescription)")
        }
    }

    // MARK: Estado e espaço

    /// O que o próprio WordPress já sabe sobre atualizações (sem contactar a internet) e se o modo debug está ligado.
    struct SiteHealth: Decodable {
        var core: String?
        var plugins: [String]
        var themes: [String]
        /// "slug (língua)" de cada pacote de idioma por atualizar.
        var translations: [String]
        /// false se o WordPress ainda não verificou atualizações (ou as caches foram limpas).
        var checked: Bool
        var debug: Bool
    }

    func health(_ site: Site) async throws -> SiteHealth {
        try Self.decodeResult(try await tools(site, ["WPCENTER_ACTION": "health"]))
    }

    /// Corre wpcenter-tools.php no site, com a base de dados a correr.
    private func tools(_ site: Site, _ env: [String: String]) async throws -> String {
        if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        return try await Runtime.phpStatus([Runtime.wpCli.path, "eval-file", Runtime.tools.path], cwd: site.folder,
                                           env: env, using: site.phpExecutable()).1
    }

    /// Um backup do WPvivid guardado no site: as partes partilham o id (`…_wpvivid-<id>_<data>_backup_all.part001.zip`).
    struct WPvividBackup {
        let id: String
        var files: [URL]
        var date: Date
    }

    /// Espaço de um site em disco, por partes. `database` é nil numa base de dados que não está neste Mac.
    struct SiteSpace {
        var uploads: Int64 = 0, plugins: Int64 = 0, backups: Int64 = 0, rest: Int64 = 0
        var database: Int64?
        var backupSets: [WPvividBackup] = []
        var total: Int64 { uploads + plugins + backups + rest + (database ?? 0) }
    }

    /// Lento em sites grandes (percorre todos os ficheiros): chamar fora da thread principal.
    nonisolated static func space(of folder: URL, sqlite: Bool, databaseDir: URL?) -> SiteSpace {
        var space = SiteSpace()
        // O percurso devolve caminhos sem atalhos (/var → /private/var) e os prefixos têm de bater: realpath, porque o
        // resolvingSymlinksInPath volta a tirar o /private.
        let folder = realpath(folder.path, nil).map { path in defer { free(path) }; return URL(fileURLWithPath: String(cString: path)) } ?? folder
        let content = folder.appendingPathComponent("wp-content").path + "/"
        if sqlite { space.database = 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        while let file = files?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0), path = file.path
            if path.hasPrefix(content + "uploads/") { space.uploads += size }
            else if path.hasPrefix(content + "plugins/") { space.plugins += size }
            else if path.hasPrefix(content + "wpvividbackups/") { space.backups += size }
            else if sqlite && path.hasPrefix(content + "database/") { space.database! += size }
            else { space.rest += size }
        }
        if let databaseDir, FileManager.default.fileExists(atPath: databaseDir.path) {
            space.database = Self.space(of: databaseDir, sqlite: false, databaseDir: nil).rest
        }
        space.backupSets = wpvividBackups(in: folder)
        return space
    }

    /// Mais recente primeiro.
    nonisolated static func wpvividBackups(in folder: URL) -> [WPvividBackup] {
        let dir = folder.appendingPathComponent("wp-content/wpvividbackups")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var sets: [String: WPvividBackup] = [:]
        for file in files where file.pathExtension.lowercased() == "zip" {
            let id = file.lastPathComponent.firstMatch(of: #/_(wpvivid-[0-9a-f]+)_/#).map { String($0.1) } ?? file.lastPathComponent
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            sets[id, default: WPvividBackup(id: id, files: [], date: date)].files.append(file)
            sets[id]!.date = max(sets[id]!.date, date)
        }
        return sets.values.sorted { $0.date > $1.date }
    }

    /// A pasta da base de dados do site no servidor gerido (fica fora da pasta do site).
    func databaseDir(of site: Site) -> URL? {
        let db = site.database
        guard db.engine.needsServer, db.managed else { return nil }
        return storage.appendingPathComponent("Databases/\(LocalServer(db).formula)/data/\(db.name)")
    }

    /// Manda para o Lixo os backups WPvivid do site, menos o mais recente, e tira-os da lista do WPvivid. Devolve quantos.
    func trashOldWPvividBackups(_ site: Site) async throws -> Int {
        let old = Self.wpvividBackups(in: site.folder).dropFirst()
        for file in old.flatMap(\.files) { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
        if !old.isEmpty { _ = try? await tools(site, ["WPCENTER_ACTION": "wpvivid-forget", "WPCENTER_IDS": old.map(\.id).joined(separator: ",")]) }
        return old.count
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
            try await Runtime.php([Runtime.wpCli.path, "option", "update", "blogname", name], cwd: site.folder, using: site.phpExecutable())
        }
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[index].name = name
        try save()
    }

    /// Muda o PHP do site; se estiver a correr, reinicia-o já com a versão nova.
    func setPHP(_ site: Site, to version: String) async throws {
        guard let index = sites.firstIndex(where: { $0.id == site.id }), sites[index].php != version else { return }
        guard PHPVersions.isInstalled(version) else { throw AppError("O PHP \(version) não está instalado neste Mac. Instale-o em Definições → Avançado.") }
        sites[index].phpVersion = version
        try save()
        guard isRunning(site) else { return }
        stop(site)
        for _ in 0..<30 where !Self.isPortFree(site.port) { try? await Task.sleep(for: .milliseconds(100)) }
        await start(sites[index])
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
            let list = tables.joined(separator: ", ")
            return tables.count == 1
                ? L("1 tabela usa uma colação só do MySQL 8 (utf8mb4_0900_*), que o MariaDB do cPanel recusa: \(list).")
                : L("\(tables.count) tabelas usam uma colação só do MySQL 8 (utf8mb4_0900_*), que o MariaDB do cPanel recusa: \(list).")
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
                                                      env: ["WPCENTER_ACTION": convert ? "convert" : "check"], using: site.phpExecutable())
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(CollationResult.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else { throw AppError("Não foi possível verificar a base de dados:\n\(String(output.suffix(600)))") }
        guard result.ok else { throw result.error.map { AppError(verbatim: $0) } ?? AppError("Falhou.") }
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
                                                      cwd: site.folder, env: ["WPCENTER_EXPORT_DIR": target.path],
                                                      using: site.phpExecutable())
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("WPCENTER_RESULT ") }),
              let result = try? JSONDecoder().decode(ExportResult.self, from: Data(line.dropFirst("WPCENTER_RESULT ".count).utf8))
        else {
            throw AppError("O backup do WPvivid falhou:\n\(String(output.suffix(800)))")
        }
        guard result.ok else { throw AppError(verbatim: result.error) }
        return result
    }

    // MARK: Apagar

    /// Move a pasta para o Lixo (reversível). Bases de dados MySQL/MariaDB nunca são apagadas.
    func delete(_ site: Site) async {
        stop(site)
        if FileManager.default.fileExists(atPath: site.path) {
            do { try await NSWorkspace.shared.recycle([site.folder]) } catch {
                errorMessage = L("Não foi possível mover \(site.path) para o Lixo: \(error.localizedDescription)")
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

    nonisolated static func slug(_ name: String) -> String {
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
