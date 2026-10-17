import AppKit
import Foundation
import Security

// MARK: - Sites live

/// Um site WordPress publicado, ligado pelo plugin WP Center Ligação (Plugin/wpcenter-ligacao).
/// Guardado em live-sites.json (0600), como as palavras-passe dos sites locais no sites.json.
struct LiveSite: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    /// Raiz da API: "https://site/wp-json" ou, sem ligações permanentes, "https://site/?rest_route=".
    var restBase: String
    var user: String
    /// Palavra-passe de aplicação. Nil nas ligações antigas, que a tinham no Porta-chaves (ver `password(for:)`).
    var password: String?

    var adminURL: URL { url.appendingPathComponent("wp-admin/") }
}

/// O que o plugin devolve em /wpcenter/v1/status (e /update, com os erros).
struct LiveStatus: Decodable {
    struct Item: Decodable, Identifiable {
        let file: String?  // plugins
        let slug: String?  // temas
        let name: String
        let version: String
        let active: Bool
        let update: String?
        var id: String { file ?? slug ?? name }
    }

    let plugin: String
    let name: String
    /// Ícone do site a 128 px (plugin 1.1+); sem ele usa-se o /favicon.ico, que o WordPress redireciona para o mesmo ícone.
    let icon: URL?
    let wordpress: String
    let php: String
    let core: String?
    let plugins: [Item]
    let themes: [Item]
    let checked: Date?
    let debug: Bool
    let writable: Bool
    let errors: [String: String]?

    var pluginUpdates: [Item] { plugins.filter { $0.update != nil } }
    var themeUpdates: [Item] { themes.filter { $0.update != nil } }
    var updateCount: Int { pluginUpdates.count + themeUpdates.count + (core == nil ? 0 : 1) }
}

/// Porque é que um site não respondeu, com o texto a mostrar.
enum LiveProblem: Error, Equatable {
    case noPlugin, unauthorized, forbidden
    case message(String)

    var text: String {
        switch self {
        case .noPlugin: L("O plugin WP Center Ligação não está ativo neste site.")
        case .unauthorized: L("A ligação foi recusada: a palavra-passe de aplicação foi revogada ou o servidor não deixa passar a autenticação.")
        case .forbidden: L("O utilizador ligado não é administrador deste site.")
        case .message(let text): text
        }
    }
}

/// Os sites live e o seu estado. Única parte da app que fala com servidores fora do Mac, e só quando o utilizador pede.
@MainActor
final class LiveStore: ObservableObject {
    static let shared = LiveStore(storage: SiteStore.shared.storage)

    @Published private(set) var sites: [LiveSite] = []
    @Published private(set) var status: [LiveSite.ID: LiveStatus] = [:]
    @Published private(set) var problems: [LiveSite.ID: LiveProblem] = [:]
    /// A ler ou a atualizar: os botões desses sites ficam desligados.
    @Published private(set) var busy: Set<LiveSite.ID> = []
    /// Ligação à espera da aprovação no navegador.
    @Published private(set) var pending: Pending?
    /// Site acabado de ligar: a janela seleciona-o.
    @Published var justConnected: LiveSite.ID?

    struct Pending {
        let nonce: String
        let name: String
        let home: URL
        let restBase: String
        var failure: String?
    }

    private let file: URL

    init(storage: URL) {
        file = storage.appendingPathComponent("live-sites.json")
        if let data = try? Data(contentsOf: file) {
            sites = (try? JSONDecoder().decode([LiveSite].self, from: data)) ?? []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(sites).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) // contém palavras-passe
    }

    /// Fora do Porta-chaves: numa app assinada ad hoc cada compilação é outra app para o macOS, que pedia a palavra-passe
    /// do Mac por cada site a cada atualização.
    private func password(for site: LiveSite) -> String? {
        if let saved = site.password ?? sites.first(where: { $0.id == site.id })?.password { return saved }
        // ponytail: migração das ligações feitas com o Porta-chaves (o macOS pede acesso uma vez por site). Apagar quando já não houver nenhuma.
        guard let old = Keychain.get(site.id), let index = sites.firstIndex(where: { $0.id == site.id }) else { return nil }
        sites[index].password = old
        save()
        return old
    }

    // MARK: Ligar

    /// Encontra a API do site e abre no navegador a página do WordPress onde o utilizador aprova a ligação.
    func connect(address: String) async throws {
        pending = nil
        let origin = try Self.origin(from: address)
        let (index, restBase) = try await Self.discover(origin)
        guard let auth = ((index["authentication"] as? [String: Any])?["application-passwords"] as? [String: Any])?["endpoints"]
                as? [String: Any], let authorize = (auth["authorization"] as? String).flatMap(URL.init(string:)),
              Self.isSecure(authorize) else {
            throw AppError("Este site não aceita palavras-passe de aplicação. Confirme que tem HTTPS e que nenhum plugin de segurança (p.ex. Wordfence) as desligou.")
        }
        let home = (index["home"] as? String).flatMap(URL.init(string:)) ?? origin
        let nonce = UUID().uuidString
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "app_name", value: "WP Center"),
            URLQueryItem(name: "app_id", value: "6f1c5a52-6d3e-4a7e-9a55-5c3f0f6d1e2b"),
            // O pedido volta com este código: um link wpcenter:// vindo de outro lado é ignorado.
            URLQueryItem(name: "success_url", value: "wpcenter://ligar?pedido=\(nonce)"),
        ]
        pending = Pending(nonce: nonce, name: index["name"] as? String ?? home.host() ?? address, home: home, restBase: restBase)
        Prefs.openInBrowser(components.url!)
    }

    func cancelConnect() { pending = nil }

    /// wpcenter://ligar?pedido=…&site_url=…&user_login=…&password=… (ou success=false), enviado pelo WordPress.
    func handle(_ url: URL) {
        guard url.scheme == "wpcenter", url.host() == "ligar" else { return }
        // O WordPress usa o urlencode do PHP: espaço vira "+" (p.ex. "Miguel+Carneiro"), que o URLComponents não descodifica.
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?.map {
            ($0.name, ($0.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        }
        let query = Dictionary(pairs ?? [], uniquingKeysWith: { a, _ in a })
        guard let request = pending, query["pedido"] == request.nonce else { return }
        guard query["success"] != "false", let user = query["user_login"], let password = query["password"], !password.isEmpty else {
            pending?.failure = L("A ligação não foi aprovada no navegador.")
            return
        }
        let site = LiveSite(name: request.name, url: request.home, restBase: request.restBase, user: user, password: password)
        Task {
            do {
                // Confirma já a palavra-passe; sem o plugin a ligação fica guardada e o detalhe explica como instalá-lo.
                do {
                    status[site.id] = try await call(site, "/wpcenter/v1/status")
                } catch LiveProblem.noPlugin {
                    problems[site.id] = .noPlugin
                }
                // Ligar de novo o mesmo site substitui a ligação antiga (e a sua chave).
                for old in sites where old.restBase == site.restBase && old.user == site.user { disconnect(old) }
                sites.append(site)
                sites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                save()
                pending = nil
                justConnected = site.id
            } catch {
                pending?.failure = (error as? LiveProblem)?.text ?? error.localizedDescription
            }
        }
    }

    /// Esquece o site neste Mac. A palavra-passe de aplicação continua no site até ser revogada no perfil.
    func disconnect(_ site: LiveSite) {
        sites.removeAll { $0.id == site.id }
        status[site.id] = nil
        problems[site.id] = nil
        save()
    }

    // MARK: Estado e atualizações

    func refresh(_ site: LiveSite, force: Bool = false) async {
        await run(site) { try await self.call(site, "/wpcenter/v1/status", query: force ? "force=1" : nil) }
    }

    func refreshAll(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for site in sites { group.addTask { await self.refresh(site, force: force) } }
        }
    }

    /// Devolve os erros por item (plugin, tema ou "wordpress") que o WordPress reportou.
    @discardableResult
    func update(_ site: LiveSite, plugins: [String] = [], themes: [String] = [], core: Bool = false) async -> [String: String] {
        let body: [String: Any] = ["plugins": plugins, "themes": themes, "core": core]
        await run(site) { try await self.call(site, "/wpcenter/v1/update", body: body, timeout: 900) }
        return status[site.id]?.errors ?? [:]
    }

    /// Plugins e temas de todos os sites, em paralelo (servidores diferentes). O WordPress fica de fora: atualiza-se site a site.
    func updateAll() async {
        await withTaskGroup(of: Void.self) { group in
            for site in sites {
                guard let current = status[site.id], current.pluginUpdates.count + current.themeUpdates.count > 0 else { continue }
                group.addTask {
                    await self.update(site, plugins: current.pluginUpdates.compactMap(\.file), themes: current.themeUpdates.compactMap(\.slug))
                }
            }
        }
    }

    private func run(_ site: LiveSite, _ work: @escaping () async throws -> LiveStatus) async {
        busy.insert(site.id)
        defer { busy.remove(site.id) }
        do {
            status[site.id] = try await work()
            problems[site.id] = nil
        } catch {
            problems[site.id] = error as? LiveProblem ?? .message(error.localizedDescription)
        }
    }

    // MARK: Plugin

    static var pluginZip: URL? { Runtime.appBundle.url(forResource: "wpcenter-ligacao", withExtension: "zip") }

    /// Copia o zip do plugin para a pasta de exportação (Transferências por omissão) e mostra-o no Finder.
    func revealPlugin() throws {
        guard let zip = Self.pluginZip else { throw AppError("O plugin não está dentro da app. Volte a compilar com o build.sh.") }
        let target = Prefs.exportDirectory.appendingPathComponent(zip.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: zip, to: target)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: Rede

    private func call(_ site: LiveSite, _ path: String, query: String? = nil, body: [String: Any]? = nil,
                      timeout: TimeInterval = 120) async throws -> LiveStatus {
        guard let password = password(for: site) else { throw LiveProblem.unauthorized }
        let separator = site.restBase.contains("?") ? "&" : "?"
        guard let url = URL(string: site.restBase + path + (query.map { separator + $0 } ?? "")) else { throw LiveProblem.message(L("Endereço inválido.")) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Basic " + Data("\(site.user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            do { return try decoder.decode(LiveStatus.self, from: data) } catch {
                throw LiveProblem.message(L("O site respondeu algo inesperado. Confirme que o plugin WP Center Ligação está atualizado."))
            }
        }
        let wpError = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch (code, wpError?["code"] as? String) {
        case (404, "rest_no_route"): throw LiveProblem.noPlugin
        case (401, _): throw LiveProblem.unauthorized
        case (403, _): throw LiveProblem.forbidden
        default:
            throw LiveProblem.message(wpError?["message"] as? String ?? L("O site respondeu com o erro HTTP \(code)."))
        }
    }

    /// "loja.pt", "https://loja.pt/wp-admin/" ou "loja.pt/blog" → a raiz do WordPress, em https.
    static func origin(from address: String) throws -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            throw AppError("Escreva o endereço do site, por exemplo loja.pt.")
        }
        if let range = components.path.range(of: "/wp-(admin|login\\.php|json).*", options: .regularExpression) {
            components.path.removeSubrange(range.lowerBound...)
        }
        components.path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.query = nil
        components.fragment = nil
        guard let url = components.url, isSecure(url) else { throw AppError("O site tem de usar HTTPS.") }
        return url
    }

    /// HTTPS, ou http só para sites neste Mac (para experimentar com um site local da WP Center).
    static func isSecure(_ url: URL) -> Bool {
        url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host() ?? ""))
    }

    /// O índice da API: primeiro em /wp-json, depois em ?rest_route= (sites sem ligações permanentes). Segue redireções (www, https).
    private static func discover(_ origin: URL) async throws -> ([String: Any], String) {
        for candidate in [origin.absoluteString + "/wp-json/", origin.absoluteString + "/?rest_route=/"] {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let final = response.url, isSecure(final),
                  let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any], index["routes"] != nil else { continue }
            var base = final.absoluteString
            if base.hasSuffix("/") { base.removeLast() }
            return (index, base)
        }
        throw AppError("Não foi possível encontrar um WordPress em \(origin.absoluteString). Confirme o endereço.")
    }
}

// MARK: - Porta-chaves

/// Só leitura, para migrar as ligações antigas: as chaves passaram para o live-sites.json.
enum Keychain {
    static func get(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.wpcenter.live",
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
