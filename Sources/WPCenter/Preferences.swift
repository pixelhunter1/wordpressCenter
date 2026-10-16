import AppKit
import ServiceManagement

enum LaunchBehavior: String, CaseIterable, Identifiable {
    case none, resume, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Não iniciar nenhum site"
        case .resume: "Retomar os sites que estavam a correr"
        case .all: "Iniciar todos os sites"
        }
    }
}

enum QuitBehavior: String, CaseIterable, Identifiable {
    case stop, keep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stop: "Parar todos os sites"
        case .keep: "Manter os sites a correr"
        }
    }
}

/// Navegador, editor ou terminal instalado no Mac.
struct ExternalApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Preferências do utilizador (UserDefaults). Chaves usadas também com @AppStorage nas vistas.
enum Prefs {
    static let launchBehaviorKey = "launchBehavior"
    static let quitBehaviorKey = "quitBehavior"
    static let showMenuBarKey = "showMenuBar"
    static let browserKey = "browser"
    static let editorKey = "editor"
    static let terminalKey = "terminal"
    static let defaultEngineKey = "defaultEngine"
    static let defaultVersionKey = "defaultVersion"
    static let defaultAdminUserKey = "defaultAdminUser"
    static let lastRunningSitesKey = "lastRunningSites"
    static let exportDirectoryKey = "exportDirectory"
    static let askExportLocationKey = "askExportLocation"
    static let disabledSkillsKey = "disabledSkills"

    private static var defaults: UserDefaults { .standard }

    static var launchBehavior: LaunchBehavior { LaunchBehavior(rawValue: defaults.string(forKey: launchBehaviorKey) ?? "") ?? .none }
    static var quitBehavior: QuitBehavior { QuitBehavior(rawValue: defaults.string(forKey: quitBehaviorKey) ?? "") ?? .stop }
    static var showsMenuBar: Bool { defaults.bool(forKey: showMenuBarKey) }

    static var lastRunningSites: [UUID] {
        get { (defaults.stringArray(forKey: lastRunningSitesKey) ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: lastRunningSitesKey) }
    }

    // MARK: Habilidades

    /// Guardam-se as desligadas, para que habilidades novas venham ligadas.
    static var enabledSkills: Set<String> {
        Set(AgentSkill.all.map(\.id)).subtracting(defaults.stringArray(forKey: disabledSkillsKey) ?? [])
    }

    static func setSkill(_ id: String, enabled: Bool) {
        var disabled = Set(defaults.stringArray(forKey: disabledSkillsKey) ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: disabledSkillsKey)
    }

    // MARK: Exportações

    /// Pasta das exportações para o cPanel: Descargas por omissão.
    static var exportDirectory: URL {
        get {
            defaults.string(forKey: exportDirectoryKey).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { defaults.set(newValue.path, forKey: exportDirectoryKey) }
    }

    static var asksExportLocation: Bool { defaults.bool(forKey: askExportLocationKey) }

    // MARK: Novos sites

    /// Motor e versão por omissão (p.ex. os do servidor cPanel do utilizador).
    static var defaultDatabase: DatabaseConfig {
        var db = DatabaseConfig()
        if let engine = DatabaseEngine(rawValue: defaults.string(forKey: defaultEngineKey) ?? ""), engine.isAvailable {
            db.engine = engine
            db.targetVersion = engine.defaultVersion
        }
        if let version = defaults.string(forKey: defaultVersionKey), db.engine.cpanelVersions.contains(version) {
            db.targetVersion = version
        }
        return db
    }

    /// nil quando o utilizador não definiu nenhum.
    static var customAdminUser: String? {
        let user = defaults.string(forKey: defaultAdminUserKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return user.isEmpty ? nil : user
    }

    // MARK: Aplicações

    static let knownEditors = [
        ExternalApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        ExternalApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        ExternalApp(bundleID: "dev.zed.Zed", name: "Zed"),
        ExternalApp(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        ExternalApp(bundleID: "com.jetbrains.PhpStorm", name: "PhpStorm"),
        ExternalApp(bundleID: "com.panic.Nova", name: "Nova"),
    ]
    static let knownTerminals = [
        ExternalApp(bundleID: "com.apple.Terminal", name: "Terminal"),
        ExternalApp(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        ExternalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        ExternalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
    ]

    static func installed(_ apps: [ExternalApp]) -> [ExternalApp] {
        apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Todos os navegadores que o macOS conhece para abrir páginas web.
    static var browsers: [ExternalApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://wordpress.org")!).compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return ExternalApp(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var preferredEditor: ExternalApp? {
        let editors = installed(knownEditors)
        return editors.first { $0.bundleID == defaults.string(forKey: editorKey) } ?? editors.first
    }

    /// Abre com a aplicação escolhida; sem escolha (ou se já não existir), usa a predefinição do sistema.
    private static func open(_ urls: [URL], with bundleID: String?) {
        if let bundleID, !bundleID.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    static func openInBrowser(_ url: URL) { open([url], with: defaults.string(forKey: browserKey)) }
    static func openInTerminal(_ folder: URL) { open([folder], with: defaults.string(forKey: terminalKey) ?? "com.apple.Terminal") }
    static func openInEditor(_ folder: URL) { open([folder], with: preferredEditor?.bundleID) }

    // MARK: Abrir ao iniciar sessão

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    static var loginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
