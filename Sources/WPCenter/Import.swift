import Foundation

/// Importar um site a partir do ficheiro de exportação do WordPress Studio ou do Local (.zip ou .tar.gz),
/// sem nenhuma dessas apps instaladas.
/// - Studio: `wp-content/`, `wp-config.php`, `sql/*.sql` (formato MySQL) e `meta.json`; o núcleo do WordPress não vem,
///   usamos o incluído na app.
/// - Local: a pasta do site, com `app/public/` (WordPress completo), `app/sql/*.sql` e `local-site.json`.
/// A base de dados vai para o servidor MariaDB/MySQL gerido (o motor das preferências, se estiver instalado).
extension SiteStore {
    /// Lê o ficheiro, cria o site em `directory`/<slug do nome> e regista-o. Devolve o site novo.
    /// `database`: o servidor gerido a usar (por omissão, o das preferências ou o primeiro instalado).
    func importSite(from archive: URL, name: String, into directory: URL? = nil, database: DatabaseConfig? = nil) async throws -> Site {
        let directory = directory ?? Self.defaultDirectory
        let fm = FileManager.default
        let name = name.trimmingCharacters(in: .whitespaces)
        let slug = Self.slug(name)
        guard !slug.isEmpty else { throw AppError("Indique um nome para o site.") }
        let folder = directory.appendingPathComponent(slug)
        guard !fm.fileExists(atPath: folder.path) else { throw AppError("Já existe uma pasta em \(folder.path).") }
        var db = try database ?? Self.importDatabaseConfig()
        db.managed = true
        db.name = Self.cpanelStyleIdentifier()

        let scratch = fm.temporaryDirectory.appendingPathComponent("wpcenter-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) } // só a pasta temporária criada aqui
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        // O tar do macOS (bsdtar) abre .zip e .tar.gz.
        let (status, out) = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", scratch.path])
        guard status == 0 else { throw AppError("Não foi possível abrir o ficheiro:\n\(String(out.suffix(600)))") }
        let content = try Self.exportContent(in: scratch)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: content.wordpress.appendingPathComponent("wp-includes").path) {
                try fm.moveItem(at: content.wordpress, to: folder)
            } else {
                try fm.copyItem(at: Runtime.wordpress, to: folder)
                try fm.removeItem(at: folder.appendingPathComponent("wp-content"))
                try fm.moveItem(at: content.wordpress.appendingPathComponent("wp-content"), to: folder.appendingPathComponent("wp-content"))
            }
            // Restos do SQLite do Studio: o drop-in levaria o WordPress para a base de dados SQLite (vazia) em vez da nossa.
            let dropIn = folder.appendingPathComponent("wp-content/db.php")
            if (try? String(contentsOf: dropIn, encoding: .utf8))?.contains("SQLite") == true { try? fm.removeItem(at: dropIn) }

            try await prepareDatabase(&db)
            try await Self.load(content.sql, into: db)

            let configURL = folder.appendingPathComponent("wp-config.php")
            let original = content.wpConfig.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let config = original.map { Self.settingDatabase(db, in: $0) }
                ?? Self.wpConfig(for: db).replacingOccurrences(of: "$table_prefix = 'wp_';", with: "$table_prefix = '\(content.tablePrefix)';")
            try Self.addingLocalDefaults(to: config).write(to: configURL, atomically: true, encoding: .utf8)

            // Passos da importação com o PHP incluído e sem plugins: a versão do site pode ainda não estar instalada.
            var site = Site(name: name, path: folder.path, port: nextFreePort(), adminPassword: "",
                            wpVersion: Runtime.wordPressVersion(at: folder), database: db)
            try await replaceURLs(in: site)
            // A palavra-passe de origem é desconhecida: uma nova para o primeiro administrador. Se falhar fica "Repor acesso".
            let password = Self.strongPassword()
            if let result = try? await access(site, "reset", ["WPCENTER_PASS": password]) {
                site.adminUser = result.user ?? site.adminUser
                site.adminPassword = password
            }
            site.phpVersion = content.php
            try add(site)
            return site
        } catch {
            try? fm.removeItem(at: folder) // só a pasta que acabámos de criar (confirmado acima que não existia)
            throw error
        }
    }

    /// Nome sugerido: o do ficheiro, sem extensão nem a data que o Studio e o Local acrescentam.
    nonisolated static func siteName(for archive: URL) -> String {
        var name = archive.lastPathComponent
        for ext in [".zip", ".tar.gz", ".tgz"] where name.lowercased().hasSuffix(ext) { name.removeLast(ext.count) }
        return name.replacing(#/[-_ ]?\d{4}-\d{2}-\d{2}.*$/#, with: "")
    }

    /// O servidor gerido para os sites importados: o das preferências; se for SQLite ou não estiver instalado,
    /// o primeiro instalado (MariaDB primeiro, como no cPanel).
    private static func importDatabaseConfig() throws -> DatabaseConfig {
        let preferred = Prefs.defaultDatabase
        let candidates = [preferred] + [DatabaseEngine.mariadb, .mysql].flatMap { engine in
            (LocalServer.homebrewVersions[engine] ?? []).reversed().map { DatabaseConfig(engine: engine, targetVersion: $0) }
        }
        guard let db = candidates.first(where: { $0.engine.needsServer && LocalServer($0).isInstalled }) else {
            throw AppError("Para importar, instale o MariaDB ou o MySQL em Definições → Avançado.")
        }
        return db
    }

    struct ExportContent {
        /// A pasta com `wp-content` (no Local, `app/public`, com o WordPress completo).
        let wordpress: URL
        let wpConfig: URL?
        let sql: [URL]
        let php: String
        let tablePrefix: String
    }

    /// Encontra o conteúdo do export, também quando o zip tem tudo dentro de uma pasta.
    static func exportContent(in dir: URL) throws -> ExportContent {
        let fm = FileManager.default
        func exists(_ url: URL, _ path: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(path).path) }
        var queue = [dir], base: URL?
        for depth in 0..<3 {
            base = queue.first { exists($0, "wp-content") || exists($0, "app/public/wp-content") }
            if base != nil || depth == 2 { break }
            queue = queue.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
        }
        guard let base else {
            throw AppError("Este ficheiro não parece uma exportação do WordPress Studio ou do Local (não tem wp-content).")
        }
        let isLocal = exists(base, "app/public/wp-content")
        let wordpress = isLocal ? base.appendingPathComponent("app/public") : base
        let sqlDir = base.appendingPathComponent(isLocal ? "app/sql" : "sql")
        let sql = ((try? fm.contentsOfDirectory(at: sqlDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sql" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sql.isEmpty else { throw AppError("O ficheiro não traz a base de dados (.sql). Exporte o site completo.") }

        func json(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: base.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let php = isLocal
            ? ((json("local-site.json")?["services"] as? [String: [String: Any]])?["php"]?["version"] as? String)
            : (json("meta.json")?["phpVersion"] as? String)
        let config = wordpress.appendingPathComponent("wp-config.php")
        return ExportContent(wordpress: wordpress, wpConfig: fm.fileExists(atPath: config.path) ? config : nil, sql: sql,
                             php: phpVersion(php), tablePrefix: tablePrefix(in: sql[0]) ?? "wp_")
    }

    /// "8.2.27" → "8.2"; a incluída se o site usar uma versão que não temos.
    nonisolated static func phpVersion(_ full: String?) -> String {
        let v = (full ?? "").split(separator: ".").prefix(2).joined(separator: ".")
        return PHPVersions.all.contains(v) ? v : PHPVersions.bundled
    }

    /// O prefixo das tabelas, a partir da tabela `<prefixo>options` no SQL (para quando o export não traz wp-config.php).
    private static func tablePrefix(in sql: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: sql) else { return nil }
        defer { try? handle.close() }
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let text = String(decoding: chunk, as: UTF8.self)
            if let match = text.firstMatch(of: #/CREATE TABLE (?:IF NOT EXISTS )?`([A-Za-z0-9_]*)options`/#) { return String(match.1) }
        }
        return nil
    }

    /// Carrega os .sql na base de dados nova pelo socket root do servidor gerido. As colações só do MySQL 8
    /// (`utf8mb4_0900_*`, comuns nos exports do Local) passam a utf8mb4_unicode_ci: o MariaDB do cPanel recusa-as.
    private static func load(_ files: [URL], into db: DatabaseConfig) async throws {
        let server = LocalServer(db)
        guard let client = ["mysql", "mariadb"].compactMap({ server.prefix?.appendingPathComponent("bin/\($0)") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppError("\(server.title) não está instalado neste Mac.")
        }
        for file in files {
            _ = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/sed"),
                                       ["-i", "", "-E", "s/utf8mb4_0900_[a-z_]+/utf8mb4_unicode_ci/g", file.path])
            let (status, out) = try await Runtime.exec(client, ["--no-defaults", "--socket=\(server.socket)", "-uroot",
                                                                "--default-character-set=utf8mb4", db.name, "-e", "source \(file.path)"])
            guard status == 0 else { throw AppError("Não foi possível carregar a base de dados:\n\(String(out.suffix(600)))") }
        }
    }

    /// Troca só as quatro constantes da ligação; o resto do wp-config (prefixo das tabelas, constantes dos plugins) fica.
    static func settingDatabase(_ db: DatabaseConfig, in config: String) -> String {
        let host = db.port == 3306 ? db.host : "\(db.host):\(db.port)"
        var config = config
        for (key, value) in [("DB_NAME", db.name), ("DB_USER", db.user), ("DB_PASSWORD", db.password), ("DB_HOST", host)] {
            let pattern = try! Regex("define\\(\\s*['\"]\(key)['\"]\\s*,\\s*['\"][^'\"]*['\"]\\s*\\)")
            config = config.replacing(pattern, with: "define( '\(key)', \(phpQuote(value)) )")
        }
        return config
    }

    /// Ambiente local (a entrada automática precisa dele) e sem atualizações em segundo plano, como nos sites criados aqui.
    static func addingLocalDefaults(to config: String) -> String {
        let lines = [("WP_ENVIRONMENT_TYPE", "'local'"), ("AUTOMATIC_UPDATER_DISABLED", "true")]
            .filter { !config.contains("'\($0.0)'") && !config.contains("\"\($0.0)\"") }
            .map { "define( '\($0.0)', \($0.1) ); // WP Center" }
        guard !lines.isEmpty, let open = config.range(of: "<?php") else { return config }
        return config.replacingCharacters(in: open, with: "<?php\n" + lines.joined(separator: "\n"))
    }

    /// Troca o endereço antigo (http://zolf.local, http://localhost:8881…) pelo novo. O WP-CLI trata dos dados serializados.
    private func replaceURLs(in site: Site) async throws {
        if site.database.engine.needsServer && site.database.managed { try await ensureRunning(LocalServer(site.database)) }
        func wp(_ args: [String]) async throws -> String {
            try await Runtime.php([Runtime.wpCli.path] + args + ["--skip-plugins", "--skip-themes"], cwd: site.folder)
        }
        var hosts: [String] = []
        for option in ["home", "siteurl"] {
            guard let url = URL(string: try await wp(["option", "get", option])), let host = url.host else { continue }
            let full = url.port.map { "\(host):\($0)" } ?? host
            if !hosts.contains(full) { hosts.append(full) }
        }
        // `(\\*/)\1`: as barras com qualquer número de `\` antes (JSON, JSON dentro de JSON no Breakdance), mantidas na troca.
        for host in hosts where host != "localhost:\(site.port)" {
            let pattern = "https?:(\\\\*/)\\1" + NSRegularExpression.escapedPattern(for: host) + "(?![\\w.-])"
            _ = try await wp(["search-replace", pattern, "http:${1}${1}localhost:\(site.port)", "--regex", "--regex-delimiter=#",
                              "--all-tables-with-prefix", "--skip-columns=guid"])
        }
    }
}
