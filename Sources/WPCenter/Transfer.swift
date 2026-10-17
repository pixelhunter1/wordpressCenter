import Foundation

/// Levar sites para dentro e para fora da WP Center por ficheiro, sem outras apps instaladas.
/// - Exportar para outra WP Center: `<pasta>-<data>.zip` com `site/` (o WordPress completo), `database.sql` (MariaDB/MySQL;
///   no SQLite a base de dados já vai em `site/wp-content/database`) e `wpcenter.json` (nome, PHP, motor e versão).
/// - Exportar para o cPanel: backup WPvivid (em `Engine.swift`, `exportForCPanel`).
/// - Importar: exportações da WP Center, do WordPress Studio (`wp-content/`, `wp-config.php`, `sql/*.sql`, `meta.json`; sem o
///   núcleo do WordPress, usamos o incluído), do Local (a pasta do site: `app/public/`, `app/sql/*.sql`, `local-site.json`)
///   e backups do WPvivid feitos no servidor (zips dentro do zip, ver `unpackWPvivid`).
///   Os da WP Center mantêm o motor; os outros vão para o MariaDB/MySQL gerido.

/// De onde vem um ficheiro de exportação.
enum ExportOrigin: String {
    case wpcenter = "WP Center", studio = "WordPress Studio", local = "Local", wpvivid = "WPvivid"

    /// O ficheiro que identifica cada formato, na raiz do arquivo.
    var marker: String {
        switch self {
        case .wpcenter: "wpcenter.json"
        case .studio: "meta.json"
        case .local: "local-site.json"
        case .wpvivid: "wpvivid_package_info.json"
        }
    }

    /// Origem e nome do site, lidos do índice do .zip sem o abrir todo (num .tar.gz só o nome do ficheiro).
    static func peek(_ archive: URL) -> (origin: ExportOrigin?, name: String) {
        let fallback = SiteStore.siteName(for: archive)
        guard archive.pathExtension.lowercased() == "zip" else { return (nil, fallback) }
        let entries = Runtime.output("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n").map(String.init)
        // Na raiz, ou dentro de uma única pasta (zip refeito à mão).
        func entry(_ name: String) -> String? {
            entries.first { $0 == name || ($0.hasSuffix("/" + name) && $0.filter { $0 == "/" }.count == 1) }
        }
        for origin in [ExportOrigin.wpcenter, .wpvivid, .local, .studio] {
            guard let marker = entry(origin.marker) else { continue }
            let json = Runtime.output("/usr/bin/unzip", ["-p", archive.path, marker])
            let name = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["name"] as? String
            return (origin, name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        }
        return (nil, fallback)
    }
}

extension SiteStore {
    // MARK: Exportar para outra WP Center

    /// Cria `<pasta do site>-<data>.zip` em `directory` e devolve-o.
    func exportForWPCenter(_ site: Site, to directory: URL = Prefs.exportDirectory) async throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let folderName = site.folder.lastPathComponent
        let file = directory.appendingPathComponent("\(folderName)-\(formatter.string(from: Date())).zip")
        let scratch = fm.temporaryDirectory.appendingPathComponent("wpcenter-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) } // só a pasta temporária criada aqui
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        var extras = ["wpcenter.json"]
        let db = site.database
        if db.engine.needsServer {
            if db.managed { try await ensureRunning(LocalServer(db)) }
            try await Self.dump(db, to: scratch.appendingPathComponent("database.sql"))
            extras.append("database.sql")
        }
        let info: [String: Any] = [
            "format": 1, "app": Runtime.appVersion, "name": site.name, "php": site.php, "wordpress": site.wpVersion,
            "url": site.url.absoluteString, "database": ["engine": db.engine.rawValue, "version": db.targetVersion],
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: scratch.appendingPathComponent("wpcenter.json"))

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // A pasta do site entra como `site/` sem a copiar; os backups do WPvivid já exportados ficam de fora (podem ser enormes).
        let pattern = NSRegularExpression.escapedPattern(for: folderName)
        let (status, out) = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"), [
            "-a", "-cf", file.path, "--exclude", "\(folderName)/wp-content/wpvividbackups",
            "-s", ",^\(pattern),site,", "-C", site.folder.deletingLastPathComponent().path, folderName,
            "-C", scratch.path,
        ] + extras)
        guard status == 0 else {
            try? fm.removeItem(at: file)
            throw AppError("Não foi possível criar o ficheiro:\n\(String(out.suffix(600)))")
        }
        return file
    }

    /// mysqldump do servidor gerido (pelo socket root) ou de um servidor existente (com as credenciais do site).
    private static func dump(_ db: DatabaseConfig, to file: URL) async throws {
        let servers = [LocalServer(db)] + LocalServer.homebrewVersions.flatMap { engine, versions in
            versions.map { LocalServer(DatabaseConfig(engine: engine, targetVersion: $0)) }
        }
        guard let dump = servers.compactMap(\.prefix).flatMap({ [$0.appendingPathComponent("bin/mysqldump"), $0.appendingPathComponent("bin/mariadb-dump")] })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AppError("Para exportar, instale o MariaDB ou o MySQL em Definições → Avançado.")
        }
        let connection = db.managed ? ["--socket=\(LocalServer(db).socket)", "-uroot"] : ["--host=\(db.host)", "--port=\(db.port)", "-u\(db.user)"]
        let (status, out) = try await Runtime.exec(dump, ["--no-defaults"] + connection + [
            "--single-transaction", "--routines", "--triggers", "--no-tablespaces", "--default-character-set=utf8mb4",
            "--result-file=\(file.path)", db.name,
        ], env: db.managed ? [:] : ["MYSQL_PWD": db.password]) // a palavra-passe nunca vai nos argumentos
        guard status == 0 else { throw AppError("Não foi possível exportar a base de dados:\n\(String(out.suffix(600)))") }
    }

    // MARK: Importar

    /// Lê o ficheiro, cria o site em `directory`/<slug do nome> e regista-o. Devolve o site novo.
    /// `database`: o servidor gerido a usar em vez do escolhido automaticamente.
    func importSite(from archive: URL, name: String, into directory: URL? = nil, database: DatabaseConfig? = nil) async throws -> Site {
        let directory = directory ?? Self.defaultDirectory
        let fm = FileManager.default
        let name = name.trimmingCharacters(in: .whitespaces)
        let slug = Self.slug(name)
        guard !slug.isEmpty else { throw AppError("Indique um nome para o site.") }
        let folder = directory.appendingPathComponent(slug)
        guard !fm.fileExists(atPath: folder.path) else { throw AppError("Já existe uma pasta em \(folder.path).") }

        let scratch = fm.temporaryDirectory.appendingPathComponent("wpcenter-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) } // só a pasta temporária criada aqui
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await Self.extract(archive, to: scratch)
        try await Self.unpackWPvivid(archive, in: scratch)
        let content = try Self.exportContent(in: scratch)

        // Da WP Center: o mesmo motor e versão, se estiverem instalados. Das outras origens: MariaDB/MySQL.
        var db = try database ?? content.database.flatMap { $0.engine == .sqlite || LocalServer($0).isInstalled ? $0 : nil }
            ?? Self.importDatabaseConfig()
        if db.engine.needsServer {
            db.managed = true
            db.name = Self.cpanelStyleIdentifier()
        }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: content.wordpress.appendingPathComponent("wp-includes").path) {
                try fm.moveItem(at: content.wordpress, to: folder)
            } else {
                try fm.copyItem(at: Runtime.wordpress, to: folder)
                try fm.removeItem(at: folder.appendingPathComponent("wp-content"))
                try fm.moveItem(at: content.wordpress.appendingPathComponent("wp-content"), to: folder.appendingPathComponent("wp-content"))
            }

            let configURL = folder.appendingPathComponent("wp-config.php")
            let original = content.wpConfig.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            var config = original ?? Self.wpConfig(for: db)
                .replacingOccurrences(of: "$table_prefix = 'wp_';", with: "$table_prefix = '\(content.tablePrefix)';")
            if db.engine.needsServer {
                // Restos do SQLite do Studio: o drop-in levaria o WordPress para uma base de dados SQLite vazia em vez da nossa.
                let dropIn = folder.appendingPathComponent("wp-content/db.php")
                if (try? String(contentsOf: dropIn, encoding: .utf8))?.contains("SQLite") == true { try? fm.removeItem(at: dropIn) }
                try await prepareDatabase(&db)
                try await Self.load(content.sql, into: db)
                config = Self.settingDatabase(db, in: config)
            }
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

    /// Nome sugerido: o do ficheiro, sem extensão nem a data que as apps acrescentam.
    nonisolated static func siteName(for archive: URL) -> String {
        var name = archive.lastPathComponent
        for ext in [".zip", ".tar.gz", ".tgz"] where name.lowercased().hasSuffix(ext) { name.removeLast(ext.count) }
        // WPvivid: `<domínio>_wpvivid-<id>_<data>_backup_all.part001.zip` → o domínio.
        return name.replacing(#/(_wpvivid-[0-9a-f]+)?[-_ ]?\d{4}-\d{2}-\d{2}.*$/#, with: "")
    }

    /// O tar do macOS (bsdtar) abre .zip e .tar.gz.
    private static func extract(_ archive: URL, to dir: URL) async throws {
        let (status, out) = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", dir.path])
        guard status == 0 else { throw AppError("Não foi possível abrir o ficheiro:\n\(String(out.suffix(600)))") }
    }

    /// Os backups do WPvivid trazem um zip por parte do site (`…_backup_core.zip`, `…_backup_db.zip`, `…_backup_plugin.zip`…),
    /// às vezes repartidos por `….part001.zip`, `….part002.zip`. Junta as partes que estão ao lado da escolhida e abre cada
    /// zip no sítio certo: `sql/` (a base de dados), `site/wp-content/` (plugins, temas, uploads, resto do wp-content) e `site/`
    /// (o núcleo e outras pastas). Não faz nada noutros formatos.
    private static func unpackWPvivid(_ archive: URL, in scratch: URL) async throws {
        let fm = FileManager.default
        let marker = ExportOrigin.wpvivid.marker
        guard fm.fileExists(atPath: scratch.appendingPathComponent(marker).path) else { return }
        let chosen = archive.lastPathComponent
        if let match = chosen.firstMatch(of: #/^(.+\.part)\d+\.zip$/#) {
            let siblings = (try? fm.contentsOfDirectory(at: archive.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            for part in siblings where part.lastPathComponent != chosen && part.lastPathComponent.hasPrefix(match.1)
                && part.pathExtension.lowercased() == "zip" {
                try await extract(part, to: scratch)
            }
        }
        let inner = ((try? fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "zip" }
        for zip in inner {
            let file = zip.lastPathComponent
            let dest = file.contains("_backup_db") ? "sql"
                : ["_backup_plugin", "_backup_themes", "_backup_uploads", "_backup_content"].contains(where: file.contains) ? "site/wp-content"
                : "site"
            let target = scratch.appendingPathComponent(dest)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try await extract(zip, to: target)
            try fm.removeItem(at: zip) // só o zip interior já aberto, dentro da pasta temporária
            try? fm.removeItem(at: target.appendingPathComponent(marker)) // cada zip traz uma cópia
        }
    }

    /// O servidor gerido para sites do Studio, do Local e do WPvivid: o das preferências; se for SQLite ou não estiver instalado,
    /// o primeiro instalado (MariaDB primeiro, como no cPanel).
    private static func importDatabaseConfig() throws -> DatabaseConfig {
        let candidates = [Prefs.defaultDatabase] + [DatabaseEngine.mariadb, .mysql].flatMap { engine in
            (LocalServer.homebrewVersions[engine] ?? []).reversed().map { DatabaseConfig(engine: engine, targetVersion: $0) }
        }
        guard let db = candidates.first(where: { $0.engine.needsServer && LocalServer($0).isInstalled }) else {
            throw AppError("Para importar, instale o MariaDB ou o MySQL em Definições → Avançado.")
        }
        return db
    }

    struct ExportContent {
        let origin: ExportOrigin
        /// A pasta com `wp-content` (na WP Center `site/`, no Local `app/public/`, com o WordPress completo).
        let wordpress: URL
        let wpConfig: URL?
        let sql: [URL]
        let php: String
        let tablePrefix: String
        /// Só nas exportações da WP Center: o motor e a versão de origem.
        var database: DatabaseConfig?
    }

    /// Encontra o conteúdo do export, também quando o zip tem tudo dentro de uma pasta.
    static func exportContent(in dir: URL) throws -> ExportContent {
        let fm = FileManager.default
        func exists(_ url: URL, _ path: String) -> Bool { fm.fileExists(atPath: url.appendingPathComponent(path).path) }
        func json(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func sqlFiles(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "sql" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var queue = [dir], base: URL?
        for depth in 0..<3 {
            base = queue.first {
                exists($0, ExportOrigin.wpcenter.marker) || exists($0, ExportOrigin.wpvivid.marker) || exists($0, "wp-content")
                    || exists($0, "app/public/wp-content")
            }
            if base != nil || depth == 2 { break }
            queue = queue.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] }
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
        }
        guard let base else {
            throw AppError("Este ficheiro não parece uma exportação da WP Center, do WordPress Studio ou do Local, nem um backup do WPvivid (não tem wp-content).")
        }

        let origin: ExportOrigin = exists(base, ExportOrigin.wpcenter.marker) ? .wpcenter
            : exists(base, ExportOrigin.wpvivid.marker) ? .wpvivid
            : exists(base, "app/public/wp-content") ? .local : .studio
        let wordpress: URL, sql: [URL], php: String?
        var database: DatabaseConfig?
        switch origin {
        case .wpcenter:
            let info = json(base.appendingPathComponent(origin.marker)) ?? [:]
            wordpress = base.appendingPathComponent("site")
            sql = exists(base, "database.sql") ? [base.appendingPathComponent("database.sql")] : []
            php = info["php"] as? String
            if let source = info["database"] as? [String: String], let engine = DatabaseEngine(rawValue: source["engine"] ?? "") {
                database = DatabaseConfig(engine: engine, targetVersion: source["version"] ?? "")
            }
        case .local:
            wordpress = base.appendingPathComponent("app/public")
            sql = sqlFiles(in: base.appendingPathComponent("app/sql"))
            php = (json(base.appendingPathComponent(origin.marker))?["services"] as? [String: [String: Any]])?["php"]?["version"] as? String
        case .studio:
            wordpress = base
            sql = sqlFiles(in: base.appendingPathComponent("sql"))
            php = json(base.appendingPathComponent(origin.marker))?["phpVersion"] as? String
        case .wpvivid: // já aberto por `unpackWPvivid`
            wordpress = base.appendingPathComponent("site")
            sql = sqlFiles(in: base.appendingPathComponent("sql"))
            php = json(base.appendingPathComponent(origin.marker))?["php_version"] as? String
        }
        guard fm.fileExists(atPath: wordpress.appendingPathComponent("wp-content").path) else {
            throw AppError("O ficheiro não traz os ficheiros do site (wp-content), só a base de dados. Faça um backup completo.")
        }
        guard database?.engine == .sqlite || !sql.isEmpty else {
            throw AppError("O ficheiro não traz a base de dados (.sql). Exporte o site completo.")
        }
        let config = wordpress.appendingPathComponent("wp-config.php")
        return ExportContent(origin: origin, wordpress: wordpress, wpConfig: fm.fileExists(atPath: config.path) ? config : nil, sql: sql,
                             php: phpVersion(php), tablePrefix: sql.first.flatMap(tablePrefix) ?? "wp_", database: database)
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
