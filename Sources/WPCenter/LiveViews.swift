import AppKit
import SwiftUI

// MARK: - Barra lateral

/// Secção "Sites live" da barra lateral, separada dos sites locais: a visão geral e um site por linha.
struct LiveSidebarSection: View {
    @EnvironmentObject var live: LiveStore
    let search: String
    let onConnect: () -> Void
    @AppStorage(Prefs.liveSitesExpandedKey) private var expanded = true

    private var sites: [LiveSite] {
        search.isEmpty ? live.sites : live.sites.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Section(isExpanded: $expanded) {
            Label("Todos os sites live", systemImage: "square.grid.2x2")
            .badge(live.sites.reduce(0) { $0 + (live.status[$1.id]?.updateCount ?? 0) })
            .tag(SidebarItem.liveOverview)
            ForEach(sites) { site in
                LiveSiteRow(site: site, status: live.status[site.id], problem: live.problems[site.id], busy: live.busy.contains(site.id))
                    // Contagem no emblema cinzento do sistema, como o Mail; a cor fica para problemas (triângulo laranja).
                    .badge(live.busy.contains(site.id) || live.problems[site.id] != nil ? 0 : live.status[site.id]?.updateCount ?? 0)
                    .tag(SidebarItem.live(site.id))
                    .contextMenu { LiveSiteMenu(site: site) }
            }
        } header: {
            HStack {
                Text("Sites live")
                Spacer()
                Button(action: onConnect) { Image(systemName: "plus").iconHitTarget() }
                    .buttonStyle(.borderless)
                    .help("Ligar um site live")
                    .accessibilityLabel("Ligar um site live")
            }
        }
    }
}

private struct LiveSiteRow: View {
    let site: LiveSite
    let status: LiveStatus?
    let problem: LiveProblem?
    let busy: Bool

    var body: some View {
        HStack(spacing: 10) {
            LiveIcon(site: site, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).fontWeight(.medium).lineLimit(1)
                Text(site.url.host() ?? site.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small)
            } else if problem != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem?.text ?? "")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(problem?.text ?? (status?.updateCount ?? 0 > 0 ? L("Com atualizações") : ""))
    }
}

/// Menu de contexto de um site live (barra lateral, tabela e menu "Mais").
private struct LiveSiteMenu: View {
    @EnvironmentObject var live: LiveStore
    let site: LiveSite

    var body: some View {
        Button("Abrir site") { Prefs.openInBrowser(site.url) }
        Button("Abrir WP Admin") { Prefs.openInBrowser(site.adminURL) }
        Divider()
        Button("Verificar agora") { Task { await live.refresh(site, force: true) } }
            .disabled(live.busy.contains(site.id))
        Button("Copiar endereço") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(site.url.absoluteString, forType: .string)
        }
    }
}

/// O ícone do próprio site (Identidade do site); enquanto carrega, ou se não houver, um globo azul.
private struct LiveIcon: View {
    @EnvironmentObject var live: LiveStore
    let site: LiveSite
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        AsyncImage(url: live.status[site.id]?.icon ?? site.url.appendingPathComponent("favicon.ico")) { phase in
            if let image = phase.image {
                shape.fill(.white)
                    .overlay(image.resizable().interpolation(.high).scaledToFit())
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            } else {
                shape.fill(LinearGradient(colors: [Color.blue.opacity(0.85), Color.blue], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "globe").font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Visão geral

/// Todos os sites live numa tabela, com as ações em massa na barra de ferramentas.
struct LiveOverviewView: View {
    @EnvironmentObject var live: LiveStore
    let onOpen: (LiveSite.ID) -> Void
    let onConnect: () -> Void

    @State private var selection = Set<LiveSite.ID>()
    @State private var updatingAll = false
    @State private var confirmUpdateAll = false

    private var pendingUpdates: Int {
        live.sites.reduce(0) { total, site in
            total + (live.status[site.id].map { $0.pluginUpdates.count + $0.themeUpdates.count } ?? 0)
        }
    }
    private var refreshing: Bool { !live.busy.isEmpty }

    var body: some View {
        Group {
            if live.sites.isEmpty {
                ContentUnavailableView {
                    Label("Ainda não há sites live", systemImage: "globe")
                } description: {
                    Text("Ligue os seus sites publicados para ver o estado de todos num só lugar e atualizar plugins, temas e o WordPress sem entrar em cada um.")
                } actions: {
                    Button("Ligar site live…", action: onConnect).buttonStyle(.borderedProminent).controlSize(.large)
                    PluginButton().buttonStyle(.link)
                }
            } else {
                table
            }
        }
        .navigationTitle("Sites live")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await live.refreshAll(force: true) } } label: {
                    Label("Verificar", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                }
                .disabled(refreshing || live.sites.isEmpty)
                .help("Perguntar a todos os sites se há atualizações novas")
                Button { confirmUpdateAll = true } label: {
                    ToolbarLabel(pendingUpdates > 0 ? "Atualizar tudo (\(pendingUpdates))" : "Atualizar tudo",
                                 symbol: "arrow.up.circle.fill", color: pendingUpdates > 0 ? .orange : .secondary)
                }
                .disabled(updatingAll || refreshing || pendingUpdates == 0)
                .help("Atualizar os plugins e temas de todos os sites")
                Button(action: onConnect) { Label("Ligar site", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .help("Ligar mais um site live")
            }
        }
        .confirmationDialog("Atualizar os plugins e temas de todos os sites?", isPresented: $confirmUpdateAll) {
            Button(pendingUpdates == 1 ? "Atualizar 1 item" : "Atualizar \(pendingUpdates) itens") {
                updatingAll = true
                Task { await live.updateAll(); updatingAll = false }
            }
        } message: {
            Text("Usa o atualizador do próprio WordPress, em cada site. O WordPress em si atualiza-se site a site. Se o site não tiver cópia de segurança recente, faça uma antes no WPvivid.")
        }
        .task {
            if live.sites.contains(where: { live.status[$0.id] == nil && live.problems[$0.id] == nil }) { await live.refreshAll() }
        }
    }

    private var summary: String {
        let withUpdates = live.sites.filter { (live.status[$0.id]?.updateCount ?? 0) > 0 }.count
        let withProblems = live.problems.count
        var parts = [live.sites.count == 1 ? L("1 site") : L("\(live.sites.count) sites")]
        if withUpdates > 0 { parts.append(withUpdates == 1 ? L("1 com atualizações") : L("\(withUpdates) com atualizações")) }
        if withProblems > 0 { parts.append(withProblems == 1 ? L("1 com problemas") : L("\(withProblems) com problemas")) }
        return parts.joined(separator: " · ")
    }

    private var table: some View {
        Table(live.sites, selection: $selection) {
            TableColumn("Site") { site in
                HStack(spacing: 8) {
                    LiveIcon(site: site, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(site.name).fontWeight(.medium)
                        Text(site.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("WordPress") { site in
                if let status = live.status[site.id] {
                    Text(status.wordpress).monospacedDigit()
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("PHP") { site in
                if let status = live.status[site.id] { Text(status.php.split(separator: ".").prefix(2).joined(separator: ".")).monospacedDigit() }
            }
            .width(min: 40, ideal: 50)
            TableColumn("Estado") { site in
                LiveStateCell(status: live.status[site.id], problem: live.problems[site.id], busy: live.busy.contains(site.id))
            }
            .width(min: 180, ideal: 260)
        }
        .contextMenu(forSelectionType: LiveSite.ID.self) { ids in
            if ids.count == 1, let site = live.sites.first(where: { $0.id == ids.first }) {
                Button("Abrir detalhes") { onOpen(site.id) }
                Divider()
                LiveSiteMenu(site: site)
            }
        } primaryAction: { ids in
            if let id = ids.first { onOpen(id) }
        }
    }
}

/// Coluna Estado da tabela: o que falta atualizar, ou porque é que o site não respondeu.
private struct LiveStateCell: View {
    let status: LiveStatus?
    let problem: LiveProblem?
    let busy: Bool

    var body: some View {
        if busy {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A falar com o site…").foregroundStyle(.secondary) }
        } else if let problem {
            StatusText(LocalizedStringKey(problem.text), .warning).help(problem.text).lineLimit(1)
        } else if let status {
            if status.updateCount == 0 {
                StatusText("Tudo atualizado", .ok)
            } else {
                StatusText(LocalizedStringKey(Self.describe(status)), .update)
                    .help((status.pluginUpdates + status.themeUpdates).map(\.name).joined(separator: ", "))
            }
        } else {
            StatusText("Por verificar", .unknown)
        }
    }

    static func describe(_ status: LiveStatus) -> String {
        var parts: [String] = []
        if let core = status.core { parts.append(L("WordPress \(core)")) }
        let plugins = status.pluginUpdates.count, themes = status.themeUpdates.count
        if plugins > 0 { parts.append(plugins == 1 ? L("1 plugin") : L("\(plugins) plugins")) }
        if themes > 0 { parts.append(themes == 1 ? L("1 tema") : L("\(themes) temas")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detalhe

struct LiveSiteDetailView: View {
    @EnvironmentObject var live: LiveStore
    let site: LiveSite
    let onReconnect: () -> Void

    @State private var confirmDisconnect = false
    @State private var confirmCore = false
    @State private var lastErrors: [String: String] = [:]

    private var status: LiveStatus? { live.status[site.id] }
    private var problem: LiveProblem? { live.problems[site.id] }
    private var busy: Bool { live.busy.contains(site.id) }

    var body: some View {
        Form {
            Section { identity }
            if let problem { problemSection(problem) }
            if !lastErrors.isEmpty { errorsSection }
            if let status {
                wordpressSection(status)
                itemsSection("Plugins", status.plugins.sorted(by: Self.order), updates: status.pluginUpdates) { items in
                    await update(plugins: items.compactMap(\.file))
                }
                itemsSection("Temas", status.themes.sorted(by: Self.order), updates: status.themeUpdates) { items in
                    await update(themes: items.compactMap(\.slug))
                }
            } else if problem == nil {
                Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("A falar com o site…").foregroundStyle(.secondary) } }
            }
            connectionSection
        }
        .formStyle(.grouped)
        .navigationTitle(site.name)
        .navigationSubtitle(busy ? L("A falar com o site…") : status.map { $0.updateCount == 0 ? L("Tudo atualizado") : LiveStateCell.describe($0) } ?? "")
        .toolbar { toolbar }
        .task(id: site.id) {
            if status == nil { await live.refresh(site) }
        }
        .confirmationDialog("Desligar \(site.name) deste Mac?", isPresented: $confirmDisconnect) {
            Button("Desligar", role: .destructive) { live.disconnect(site) }
        } message: {
            Text("O site sai do WP Center. Para cortar o acesso também no site, revogue a palavra-passe de aplicação \"WP Center\" no perfil.")
        }
        .confirmationDialog("Atualizar o WordPress para \(status?.core ?? "")?", isPresented: $confirmCore) {
            Button("Atualizar o WordPress") { Task { await update(core: true) } }
        } message: {
            Text("O site fica uns segundos em manutenção. Se o site não tiver cópia de segurança recente, faça uma antes no WPvivid.")
        }
    }

    // MARK: Barra de ferramentas

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Prefs.openInBrowser(site.url) } label: { Label("Abrir site", systemImage: "safari").labelStyle(.titleAndIcon) }
                .help("Abrir o site no navegador")
            Button { Prefs.openInBrowser(site.adminURL) } label: {
                Label("WP Admin", systemImage: "gauge.with.dots.needle.33percent").labelStyle(.titleAndIcon)
            }
            .help("Abrir o painel do site no navegador")
            Button { Task { await live.refresh(site, force: true) } } label: {
                Label("Verificar", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .disabled(busy)
            .help("Perguntar ao site se há atualizações novas")
            Button {
                Task { await update(plugins: status?.pluginUpdates.compactMap(\.file) ?? [], themes: status?.themeUpdates.compactMap(\.slug) ?? []) }
            } label: {
                ToolbarLabel(itemUpdates > 0 ? "Atualizar tudo (\(itemUpdates))" : "Atualizar tudo",
                             symbol: "arrow.up.circle.fill", color: itemUpdates > 0 ? .orange : .secondary)
            }
            .disabled(busy || itemUpdates == 0 || status?.writable == false)
            .help("Atualizar todos os plugins e temas deste site")
            Menu {
                LiveSiteMenu(site: site)
                Divider()
                Button("Desligar deste Mac…", role: .destructive) { confirmDisconnect = true }
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
            }
            .help("Mais ações")
        }
    }

    private var itemUpdates: Int { (status?.pluginUpdates.count ?? 0) + (status?.themeUpdates.count ?? 0) }

    // MARK: Secções

    private var identity: some View {
        HStack(spacing: 14) {
            LiveIcon(site: site, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name).font(.title3.weight(.semibold)).lineLimit(1)
                Link(site.url.absoluteString, destination: site.url)
                if let status {
                    Text("WordPress \(status.wordpress) · PHP \(status.php)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func problemSection(_ problem: LiveProblem) -> some View {
        Section {
            Banner(text: problem.text)
            switch problem {
            case .noPlugin:
                Text("Instale-o uma vez: guarde o zip, abra Plugins → Adicionar → Carregar plugin no site e ative-o. Depois carregue em Verificar.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    PluginButton()
                    Button("Abrir carregamento de plugins") {
                        Prefs.openInBrowser(site.adminURL.appendingPathComponent("plugin-install.php").appending(queryItems: [URLQueryItem(name: "tab", value: "upload")]))
                    }
                }
            case .unauthorized:
                HStack {
                    Spacer()
                    Button("Ligar de novo…", action: onReconnect)
                }
            default:
                HStack {
                    Spacer()
                    Button("Tentar de novo") { Task { await live.refresh(site) } }.disabled(busy)
                }
            }
        }
    }

    private var errorsSection: some View {
        Section("Última atualização") {
            ForEach(lastErrors.sorted(by: { $0.key < $1.key }), id: \.key) { item, message in
                LabeledContent(name(of: item)) { ErrorText(message).lineLimit(3) }
            }
        }
    }

    private func wordpressSection(_ status: LiveStatus) -> some View {
        Section {
            LabeledContent("WordPress \(status.wordpress)") {
                if let core = status.core {
                    HStack {
                        StatusText("\(core) disponível", .update)
                        Button("Atualizar…") { confirmCore = true }.disabled(busy || !status.writable)
                    }
                } else {
                    StatusText("Atualizado", .ok)
                }
            }
            LabeledContent("PHP", value: status.php)
            LabeledContent("Modo debug") {
                if status.debug { StatusText("Ligado num site publicado", .warning) } else { StatusText("Desligado", .ok) }
            }
            if !status.writable {
                LabeledContent("Atualizações") {
                    StatusText("O servidor pede FTP: atualize no WP Admin", .warning)
                }
            }
        } header: {
            Text("WordPress")
        } footer: {
            if let checked = status.checked {
                Text("O site verificou atualizações \(checked.formatted(.relative(presentation: .named))).")
            }
        }
    }

    private func itemsSection(_ title: LocalizedStringKey, _ items: [LiveStatus.Item], updates: [LiveStatus.Item],
                              update: @escaping ([LiveStatus.Item]) async -> Void) -> some View {
        Section {
            ForEach(items) { item in
                LabeledContent {
                    if let new = item.update {
                        HStack {
                            Text("\(item.version) → \(new)").monospacedDigit().foregroundStyle(.secondary)
                            Button("Atualizar") { Task { await update([item]) } }
                                .disabled(busy || status?.writable == false)
                        }
                    } else {
                        Text(item.version).monospacedDigit().foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.update != nil ? "arrow.up.circle.fill" : item.active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.update != nil ? Color.orange : item.active ? Color.green : Color.secondary)
                            .accessibilityHidden(true)
                        Text(item.name).lineLimit(1)
                        if !item.active { Text("Inativo").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } header: {
            HStack {
                Text(title)
                Text(String(items.count)).foregroundStyle(.secondary)
                Spacer()
                if updates.count > 1 {
                    Button("Atualizar \(updates.count)") { Task { await update(updates) } }
                        .controlSize(.small)
                        .disabled(busy || status?.writable == false)
                }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Utilizador", value: site.user)
            if let version = status?.plugin { LabeledContent("Plugin WP Center Ligação", value: version) }
            HStack {
                Spacer()
                Button("Revogar no site…") {
                    var profile = URLComponents(url: site.adminURL.appendingPathComponent("profile.php"), resolvingAgainstBaseURL: false)
                    profile?.fragment = "application-passwords-section"
                    if let url = profile?.url { Prefs.openInBrowser(url) }
                }
                Button("Desligar deste Mac…", role: .destructive) { confirmDisconnect = true }
            }
        } header: {
            Text("Ligação")
        } footer: {
            Text("A chave da ligação fica guardada neste Mac e só serve para a API do site: não entra no WP Admin. Revogue-a no perfil para cortar o acesso.")
        }
    }

    // MARK: Ações

    private func update(plugins: [String] = [], themes: [String] = [], core: Bool = false) async {
        lastErrors = await live.update(site, plugins: plugins, themes: themes, core: core)
        announce(lastErrors.isEmpty ? "Atualização concluída" : "Atualização com erros")
    }

    private func name(of item: String) -> String {
        if item == "wordpress" { return "WordPress" }
        return (status?.plugins ?? []).first { $0.file == item }?.name ?? (status?.themes ?? []).first { $0.slug == item }?.name ?? item
    }

    /// Por atualizar primeiro, depois ativos, depois por nome.
    private static func order(_ a: LiveStatus.Item, _ b: LiveStatus.Item) -> Bool {
        if (a.update != nil) != (b.update != nil) { return a.update != nil }
        if a.active != b.active { return a.active }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// "Guardar o plugin": copia o zip para as Transferências e mostra-o no Finder.
private struct PluginButton: View {
    @EnvironmentObject var live: LiveStore
    @EnvironmentObject var store: SiteStore
    var body: some View {
        Button("Guardar o plugin…") {
            do { try live.revealPlugin() } catch { store.errorMessage = error.localizedDescription }
        }
        .help("Guardar o zip do plugin WP Center Ligação, para carregar em Plugins → Adicionar")
    }
}

// MARK: - Ligar site

struct ConnectLiveSiteView: View {
    @EnvironmentObject var live: LiveStore
    @Environment(\.dismiss) private var dismiss
    var address = ""

    @State private var text = ""
    @State private var connecting = false
    @State private var error: String?

    // Só o endereço: o resto (aprovar no navegador, onde fica a chave) explica-se a si próprio ou está no detalhe do site.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Ligar site live", subtitle: "Aprove a ligação no navegador, como administrador.")
            VStack(alignment: .leading, spacing: 8) {
                TextField("Endereço do site", text: $text, prompt: Text("loja.pt"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .labelsHidden()
                    .disabled(waiting)
                    .onSubmit(start)
                HStack(spacing: 4) {
                    Text("O site precisa do plugin WP Center Ligação.").foregroundStyle(.secondary)
                    PluginButton().buttonStyle(.link)
                }
                .font(.callout)
            }
            .padding(20)
            SheetFooter {
                if let failure = error ?? live.pending?.failure {
                    ErrorText(failure).font(.callout).lineLimit(3)
                } else if waiting {
                    ProgressView().controlSize(.small)
                    Text("À espera da aprovação no navegador…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancelar") {
                    live.cancelConnect()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: start) { Text(waiting ? "Abrir de novo" : "Continuar") }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(connecting || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if text.isEmpty { text = address } }
        .onChange(of: live.justConnected) { _, id in if id != nil { dismiss() } }
    }

    private var waiting: Bool { connecting || (live.pending != nil && live.pending?.failure == nil) }

    private func start() {
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do { try await live.connect(address: text) } catch { self.error = error.localizedDescription }
        }
    }
}
