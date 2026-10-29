import Foundation

// MARK: - Manifesto dos upstreams

/// O `Runtime/skills/upstreams.json`: de onde vem cada skill, em que commit, e onde ela vive no repositório.
/// O mesmo formato serve as duas cópias: a que vai dentro da app (com `builtAt`, a data do build) e a que a app
/// guarda depois de atualizar (com `fetchedAt`, a data da busca). É essa comparação que decide qual delas vale.
struct SkillManifest: Codable {
    struct Upstream: Codable {
        struct Item: Codable {
            let id: String
            let path: String
            let engine: Bool?
        }
        struct Engine: Codable {
            let asset: String?
            let install: String?
            var version: String?
        }
        let repo: String
        var ref: String
        var license: String?
        var skills: [Item]
        var engine: Engine?
    }

    var format: Int
    var comment: String?
    var builtAt: String?
    var fetchedAt: String?
    var upstreams: [String: Upstream]

    var engineVersion: String? { upstreams["impeccable"]?.engine?.version }
}

/// `Runtime/skills/patches.json`: as correções que são nossas, aplicadas depois de cada cópia — pelo build e
/// pela app, a partir deste mesmo ficheiro.
struct SkillPatchRules: Decodable {
    struct Rule: Decodable {
        let file: String
        let find: String
        let replace: String
    }
    let patches: [Rule]
}

// MARK: - Atualizar as skills a partir do GitHub

/// Procura versões novas das skills no GitHub e, se o utilizador mandar, trazê-las para
/// `~/Library/Application Support/WP Center/skills/` — o pacote da app é assinado e só de leitura.
///
/// Esta é a terceira ligação para fora do Mac, e acontece só quando o utilizador carrega: as outras duas são a
/// partilha de um site e os sites live (`architecture`, invariante 1).
@MainActor
final class SkillUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, ready, applying, done
        case failed(String)
    }

    struct SkillChange: Identifiable {
        var id: String { skill }
        let skill: String
        let title: String
        let changed: Bool
        let files: Int
    }

    struct UpstreamChange: Identifiable {
        var id: String { key }
        let key: String
        let repo: String
        let from: String
        let to: String
        let skills: [SkillChange]
        var changed: Int { skills.filter(\.changed).count }
    }

    struct Summary {
        let skills: Int
        let engineWarning: String?
    }

    /// Um repositório já descarregado e aberto numa pasta temporária, à espera de ser aplicado.
    private struct Staged {
        let key: String
        let sha: String
        let root: URL
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var upstreams: [UpstreamChange] = []
    @Published private(set) var summary: Summary?

    private var staged: [Staged] = []

    var changedSkills: Int { upstreams.reduce(0) { $0 + $1.changed } }

    // MARK: Procurar

    func check() async {
        guard phase != .checking, phase != .applying else { return }
        discardStaged()
        summary = nil
        upstreams = []
        phase = .checking
        do {
            let manifest = try Self.bundleManifest()
            var found: [UpstreamChange] = []
            for (key, upstream) in manifest.upstreams.sorted(by: { $0.key < $1.key }) {
                let sha = try await Self.latestCommit(of: upstream.repo)
                let root = try await Self.download(upstream.repo, sha)
                staged.append(Staged(key: key, sha: sha, root: root))
                var skills: [SkillChange] = []
                for item in upstream.skills {
                    let from = SiteStore.shared.skillSource(item.id)
                    let to = root.appendingPathComponent(item.path)
                    guard FileManager.default.fileExists(atPath: to.path) else {
                        throw AppError("Em \(upstream.repo) já não existe \(item.path).")
                    }
                    let difference = Self.changedFiles(from: from, to: to)
                    skills.append(SkillChange(skill: item.id, title: AgentSkill.title(of: item.id),
                                              changed: difference.changed, files: difference.files))
                }
                found.append(UpstreamChange(key: key, repo: upstream.repo,
                                            from: String(upstream.ref.prefix(7)), to: String(sha.prefix(7)),
                                            skills: skills))
            }
            upstreams = found
            phase = .ready
        } catch {
            discardStaged()
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Aplicar

    func apply() async {
        guard phase == .ready else { return }
        phase = .applying
        let store = SiteStore.shared
        do {
            let destination = store.appSupportSkills
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var manifest = try Self.bundleManifest()
            manifest.fetchedAt = Self.timestamp()

            var copied = 0
            for staged in staged {
                guard var upstream = manifest.upstreams[staged.key] else { continue }
                for item in upstream.skills {
                    let source = staged.root.appendingPathComponent(item.path)
                    let target = destination.appendingPathComponent(item.id)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: source, to: target)
                    // Atribuição: a licença do upstream viaja com a skill, como no Scripts/update-skills.sh.
                    for legal in ["LICENSE", "NOTICE.md"] {
                        let from = staged.root.appendingPathComponent(legal)
                        let to = target.appendingPathComponent(legal)
                        if !FileManager.default.fileExists(atPath: to.path), FileManager.default.fileExists(atPath: from.path) {
                            try? FileManager.default.copyItem(at: from, to: to)
                        }
                    }
                    copied += 1
                }
                upstream.ref = staged.sha
                manifest.upstreams[staged.key] = upstream
            }

            try Self.applyPatches(in: destination)
            try Self.write(manifest, to: destination.appendingPathComponent("upstreams.json"))

            let warning = store.updateSkillsEverywhere()
            summary = Summary(skills: copied, engineWarning: warning)
            phase = .done
            discardStaged()
        } catch {
            discardStaged()
            phase = .failed(error.localizedDescription)
        }
    }

    func discardStaged() {
        for item in staged { try? FileManager.default.removeItem(at: item.root) }
        staged = []
    }

    // MARK: - Manifesto e patches

    nonisolated static func bundleManifest() throws -> SkillManifest {
        try manifest(at: Runtime.skills.appendingPathComponent("upstreams.json"))
    }

    nonisolated static func manifest(at file: URL) throws -> SkillManifest {
        guard let data = try? Data(contentsOf: file) else {
            throw AppError("A app não traz o manifesto das habilidades. Volte a compilar com o build.sh.")
        }
        do { return try JSONDecoder().decode(SkillManifest.self, from: data) }
        catch { throw AppError("O manifesto das habilidades está ilegível: \(error.localizedDescription)") }
    }

    nonisolated static func write(_ manifest: SkillManifest, to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: file, options: .atomic)
    }

    /// As nossas correções, iguais às que o build aplica (`Runtime/skills/patches.json`). Um alvo que desapareceu
    /// é um erro, não um aviso: uma skill meio corrigida é pior do que uma atualização que não se fez.
    nonisolated static func applyPatches(in root: URL) throws {
        let file = Runtime.skills.appendingPathComponent("patches.json")
        guard let data = try? Data(contentsOf: file) else { return }
        let rules = try JSONDecoder().decode(SkillPatchRules.self, from: data)
        for rule in rules.patches {
            let target = root.appendingPathComponent(rule.file)
            guard let text = try? String(contentsOf: target, encoding: .utf8) else { continue }
            if text.contains(rule.find) {
                try text.replacingOccurrences(of: rule.find, with: rule.replace)
                    .write(to: target, atomically: true, encoding: .utf8)
            } else if !rule.replace.isEmpty, text.contains(rule.replace) {
                continue // já estava corrigido: aplicar duas vezes não estraga nada
            } else {
                throw AppError("A correção local a \(rule.file) já não encontra o que corrige.")
            }
        }
    }

    // MARK: - Rede (só aqui)

    /// O último commit do ramo principal, pela API do GitHub — sem `git` instalado e sem chave.
    private static func latestCommit(of repo: String) async throws -> String {
        struct Commit: Decodable { let sha: String }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/commits?per_page=1") else {
            throw AppError("Endereço inválido para \(repo).")
        }
        let (data, response) = try await send(URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError("O GitHub não respondeu como esperado para \(repo).")
        }
        guard let commits = try? JSONDecoder().decode([Commit].self, from: data), let first = commits.first else {
            throw AppError("Não consegui ler o último commit de \(repo).")
        }
        return first.sha
    }

    /// O código do repositório naquele commit, já aberto numa pasta temporária.
    private static func download(_ repo: String, _ sha: String) async throws -> URL {
        guard let url = URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(sha)") else {
            throw AppError("Endereço inválido para \(repo).")
        }
        let (data, response) = try await send(URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw AppError("Não consegui descarregar \(repo).")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wpcenter-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tarball = folder.appendingPathComponent("repo.tgz")
        try data.write(to: tarball)
        let (status, output) = try await Runtime.exec(URL(fileURLWithPath: "/usr/bin/tar"),
                                                      ["-xzf", tarball.path, "-C", folder.path, "--strip-components", "1"])
        guard status == 0 else { throw AppError("O ficheiro de \(repo) não se abriu:\n\(String(output.suffix(300)))") }
        try? FileManager.default.removeItem(at: tarball)
        return folder
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WP Center/\(Runtime.appVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        do { return try await URLSession.shared.data(for: request) }
        catch { throw AppError("Sem ligação ao GitHub: \(error.localizedDescription)") }
    }

    // MARK: - Comparar

    /// Se a cópia nova muda alguma coisa e em quantos ficheiros. A licença e o carimbo da app não contam: não vêm
    /// do upstream ou são nossos.
    nonisolated static func changedFiles(from: URL, to: URL) -> (changed: Bool, files: Int) {
        func files(_ root: URL) -> Set<String> {
            var paths: Set<String> = []
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return paths }
            for case let file as URL in walk {
                guard (try? file.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
                let relative = String(file.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard relative != skillStampFileName, relative != "LICENSE", relative != "NOTICE.md" else { continue }
                paths.insert(relative)
            }
            return paths
        }
        let before = files(from), after = files(to)
        var different = before.symmetricDifference(after).count
        for path in before.intersection(after) {
            let old = try? Data(contentsOf: from.appendingPathComponent(path))
            let new = try? Data(contentsOf: to.appendingPathComponent(path))
            if old != new { different += 1 }
        }
        return (different > 0, different)
    }

    nonisolated static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
