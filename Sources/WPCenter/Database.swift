import Foundation

/// Motores de base de dados disponíveis num servidor cPanel & WHM, mais o SQLite local.
/// Fonte: docs.cpanel.net — "Supported MySQL/MariaDB Versions" (cPanel & WHM 136+, revisto a 29/07/2026)
/// e "Install or Update PostgreSQL on Your cPanel & WHM Server" (revisto a 08/07/2026).
enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
    case mariadb, mysql, sqlite, postgresql

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sqlite: "SQLite"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        }
    }

    var symbol: String {
        switch self {
        case .sqlite: "doc.circle"
        case .mysql: "cylinder.split.1x2"
        case .mariadb: "cylinder.split.1x2.fill"
        case .postgresql: "cylinder"
        }
    }

    var summary: String {
        switch self {
        case .sqlite: L("Só para testes rápidos. Não recomendado para migrar para o cPanel.")
        case .mysql: L("Igual ao MySQL do cPanel. Pronto a migrar com o WPvivid.")
        case .mariadb: L("Recomendado. Motor por omissão do cPanel, pronto a migrar com o WPvivid.")
        case .postgresql: L("Disponível no cPanel, mas o WordPress não o suporta nativamente.")
        }
    }

    /// O WordPress só fala MySQL/MariaDB (e SQLite através do plugin oficial).
    var isAvailable: Bool { self != .postgresql }
    var needsServer: Bool { self == .mysql || self == .mariadb }

    /// Versões que o cPanel & WHM 136+ permite instalar (união de todos os SO suportados).
    var cpanelVersions: [String] {
        switch self {
        case .mysql: ["8.0", "8.4"]
        case .mariadb: ["10.5", "10.6", "10.11", "11.4", "11.8"]
        case .sqlite, .postgresql: []
        }
    }

    var defaultVersion: String {
        switch self {
        case .mysql: "8.4"
        case .mariadb: "10.11" // instalação por omissão do cPanel
        case .sqlite, .postgresql: ""
        }
    }
}

/// Uma linha da tabela oficial do cPanel: sistema operativo → versões disponíveis.
struct CPanelSupportRow: Identifiable {
    let os: String
    let mysql: [String]
    let mariadb: [String]
    let postgresql: String
    var id: String { os }

    static let all: [CPanelSupportRow] = [
        .init(os: "AlmaLinux 8", mysql: ["8.0", "8.4"], mariadb: ["10.5", "10.6", "10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "AlmaLinux 9", mysql: ["8.0", "8.4"], mariadb: ["10.5", "10.6", "10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "AlmaLinux 10", mysql: ["8.4"], mariadb: ["10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "CloudLinux 8", mysql: ["8.0", "8.4"], mariadb: ["10.5", "10.6", "10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "CloudLinux 9", mysql: ["8.0", "8.4"], mariadb: ["10.5", "10.6", "10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "CloudLinux 10", mysql: ["8.4"], mariadb: ["10.11", "11.4", "11.8"], postgresql: "Versão do SO"),
        .init(os: "Ubuntu 24", mysql: ["8.0", "8.4"], mariadb: ["10.11", "11.4", "11.8"], postgresql: "Não suportado"),
    ]
}

struct DatabaseConfig: Codable, Hashable {
    var engine: DatabaseEngine = .mariadb
    var targetVersion = DatabaseEngine.mariadb.defaultVersion
    /// true: servidor local gerido pela app; false: servidor existente indicado pelo utilizador.
    var managed = true
    var host = "127.0.0.1"
    var port = 3306
    var name = ""
    var user = ""
    var password = ""

    /// O cPanel cria nomes no formato `utilizador_bd`; aceitamos apenas [A-Za-z0-9_] para evitar injeção em CREATE DATABASE.
    static func isValidIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
