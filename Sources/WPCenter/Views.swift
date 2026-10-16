import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Janela principal

/// O que está escolhido na barra lateral: um site ou uma secção das Definições.
enum SidebarItem: Hashable {
    case site(Site.ID)
    case settings(SettingsPane)
}

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selection: SidebarItem?
    @State private var search = ""
    @State private var showNewSite = false
    @State private var showCPanel = false
    @State private var siteToDelete: Site?
    @State private var siteToRename: Site?

    private var filteredSites: [Site] {
        search.isEmpty ? store.sites : store.sites.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sites") {
                    ForEach(filteredSites) { site in
                        SiteRow(site: site, running: store.isRunning(site), shared: store.shares[site.id] != nil)
                            .tag(SidebarItem.site(site.id))
                            .contextMenu { SiteMenu(site: site, onRename: { siteToRename = site }) { siteToDelete = site } }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Procurar")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            // Definições fixas no fundo: os sites crescem por cima. Linhas próprias em vez de uma segunda List,
            // que precisaria de altura fixa e cortava o texto com outros tamanhos de barra lateral.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Definições")
                        .accessibilityAddTraits(.isHeader)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ForEach(SettingsPane.allCases) { pane in
                        SettingsSidebarRow(pane: pane, selected: selection == .settings(pane)) {
                            selection = .settings(pane)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        } detail: {
            if case .settings(let pane) = selection {
                SettingsPaneView(pane: pane)
            } else if case .site(let id) = selection, let site = store.sites.first(where: { $0.id == id }) {
                SiteDetailView(site: site, onRename: { siteToRename = site }) { siteToDelete = site }.id(site.id)
            } else {
                ContentUnavailableView {
                    Label(store.sites.isEmpty ? "Ainda não há sites" : "Selecione um site", systemImage: "globe")
                } description: {
                    Text("Sites WordPress locais, a correr no seu Mac, sem contas nem serviços externos.")
                } actions: {
                    Button("Novo site") { showNewSite = true }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showNewSite = true } label: { Label("Novo site", systemImage: "plus") }
                    .foregroundStyle(.tint) // a ação principal da app: "+" azul, no mesmo grupo dos outros botões
                    .help("Criar um novo site WordPress (⌘N)") // o atalho vive no menu Ficheiro
            }
        }
        .sheet(isPresented: $showNewSite) {
            NewSiteView { selection = .site($0.id) }
        }
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .sheet(item: $siteToRename) { RenameSiteView(site: $0) }
        .confirmationDialog("Apagar \"\(siteToDelete?.name ?? "")\"?", isPresented: Binding(
            get: { siteToDelete != nil }, set: { if !$0 { siteToDelete = nil } }
        ), presenting: siteToDelete) { site in
            Button("Mover para o Lixo", role: .destructive) {
                Task {
                    await store.delete(site)
                    if selection == .site(site.id) { selection = store.sites.first.map { .site($0.id) } }
                }
            }
        } message: { site in
            Text("A pasta \(site.path) vai para o Lixo. Bases de dados MySQL/MariaDB não são apagadas.")
        }
        .alert("Ocorreu um problema", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear {
            selection = selection ?? store.sites.first.map { .site($0.id) }
            handle(store.windowRequest) // a janela pode ter sido aberta pelo próprio pedido
        }
        .onChange(of: store.windowRequest) { _, request in handle(request) }
        // Sites iniciados/parados pelo `wpc` no terminal: refresca o estado de vez em quando.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in store.objectWillChange.send() }
    }

    /// Pedidos dos menus (Definições ⌘,, Novo site ⌘N, Ajuda → cPanel) para esta janela.
    private func handle(_ request: SiteStore.WindowRequest?) {
        guard let request else { return }
        store.windowRequest = nil
        switch request {
        case .settings: if case .settings = selection {} else { selection = .settings(.general) } // mantém a secção aberta
        case .newSite: showNewSite = true
        case .cpanel: showCPanel = true
        }
    }
}

private struct SiteRow: View {
    let site: Site
    let running: Bool
    let shared: Bool

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(size: 28)
                .overlay(alignment: .bottomTrailing) {
                    // Forma além da cor: cheio = a correr, anel = parado (distinguível sem ver cores).
                    Circle()
                        .fill(running ? Color.green : Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(running ? Color(nsColor: .windowBackgroundColor) : Color.gray,
                                                       lineWidth: running ? 1.5 : 2))
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).fontWeight(.medium).lineLimit(1)
                Text("localhost:\(String(site.port)) · \(site.database.engine.title) \(site.database.targetVersion)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if shared {
                Spacer(minLength: 4)
                Image(systemName: "link").foregroundStyle(.secondary).help("Partilhado por link")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? (shared ? L("A correr, partilhado por link") : L("A correr"))
                                    : (shared ? L("Parado, partilhado por link") : L("Parado")))
    }
}

/// Ações de um site, partilhadas pelo menu de contexto da barra lateral e pelo menu "Mais".
private struct SiteMenu: View {
    @EnvironmentObject var store: SiteStore
    let site: Site
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if store.isRunning(site) {
            Button("Parar") { store.stop(site) }
        } else {
            Button("Iniciar") { Task { await store.start(site) } }
        }
        Button("Abrir site") { Prefs.openInBrowser(site.url) }
        Button("Abrir WP Admin") { Task { await store.openAdmin(site) } }
        ShareMenuItems(site: site)
        Divider()
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
        Button("Abrir no editor") { Prefs.openInEditor(site.folder) }
            .disabled(Prefs.preferredEditor == nil)
        Button("Abrir no Terminal") { Prefs.openInTerminal(site.folder) }
        Button("Copiar endereço") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(site.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Mudar nome…", action: onRename)
        Button("Apagar site…", role: .destructive, action: onDelete)
    }
}

/// Partilhar / Copiar link / Terminar partilha, nos menus de contexto, "Mais" e barra de menus.
struct ShareMenuItems: View {
    @EnvironmentObject var store: SiteStore
    let site: Site

    var body: some View {
        if let share = store.shares[site.id] {
            if let url = share.url {
                Button("Copiar link de partilha") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Terminar partilha") { store.stopSharing(site) }
        } else {
            Button("Partilhar por link") { Task { await store.share(site) } }
        }
    }
}

/// O logo da app em miniatura, igual ao ícone do Dock: fundo branco arredondado com o símbolo.
private struct SiteIcon: View {
    var size: CGFloat
    static let logo = Runtime.appBundle.url(forResource: "logo", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        shape.fill(.white)
            .overlay {
                if let logo = Self.logo {
                    // O símbolo ocupa ~47% do SVG: a 129% do tamanho fica com ~60%, como no ícone da app.
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: size * 1.29, height: size * 1.29)
                } else {
                    Image(systemName: "globe").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.tint)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: size * 0.04, y: size * 0.02)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Detalhe do site

struct SiteDetailView: View {
    @EnvironmentObject var store: SiteStore
    let site: Site
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var starting = false
    @State private var openingAdmin = false
    @State private var credentialsValid: Bool?
    @State private var resetting = false
    @State private var confirmReset = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var collationTables: [String]?
    @State private var exportResult: SiteStore.ExportResult?
    @State private var showExclusions = false
    @State private var showShare = false

    private var running: Bool { store.isRunning(site) }
    private var db: DatabaseConfig { site.database }

    // Formulário agrupado, como nas Definições do Sistema; as ações vivem na barra de ferramentas e no menu Site.
    var body: some View {
        Form {
            Section { identity }
            accessSection
            databaseSection
            exportSection
            detailsSection
        }
        .formStyle(.grouped)
        .navigationTitle(site.name)
        .navigationSubtitle(starting ? "A iniciar…" : running ? "A correr" : "Parado")
        .toolbar { toolbar }
        .focusedSceneValue(\.selectedSite, site.id)
        .task(id: running) {
            if running { credentialsValid = await store.credentialsAreValid(site) }
        }
        .onChange(of: store.shares[site.id]?.url) { _, url in
            if url != nil { announce("Link de partilha pronto e copiado") }
        }
        .confirmationDialog("Gerar uma nova palavra-passe para \(site.adminUser)?", isPresented: $confirmReset) {
            Button("Gerar nova palavra-passe") { resetAccess() }
        } message: {
            Text("A palavra-passe atual deixa de funcionar e as sessões abertas deste utilizador terminam.")
        }
    }

    // MARK: Barra de ferramentas

    /// Ícone e nome lado a lado (como "Ícone e texto" no Finder): só com ícones não se percebia o que cada botão faz.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if running {
                Button { store.stop(site) } label: { Label("Parar", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                    .help("Parar o site (⌘R)")
            } else {
                Button {
                    starting = true
                    Task { await store.start(site); starting = false }
                } label: {
                    Label("Iniciar", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .disabled(starting)
                .help("Iniciar o site (⌘R)")
            }
            Button { Prefs.openInBrowser(site.url) } label: { Label("Abrir site", systemImage: "safari").labelStyle(.titleAndIcon) }
                .help("Abrir o site no navegador (⌘O)")
            Button {
                openingAdmin = true
                Task { await store.openAdmin(site); openingAdmin = false }
            } label: {
                Label("WP Admin", systemImage: "gauge.with.dots.needle.33percent").labelStyle(.titleAndIcon)
            }
            .disabled(openingAdmin)
            .help("Abrir o painel já com sessão iniciada (⇧⌘A)")
            Button { Task { await store.openMail() } } label: { Label("Emails", systemImage: "envelope").labelStyle(.titleAndIcon) }
                .help("Ver os emails enviados pelos sites, no Mailpit (⇧⌘E)")
            Button { showShare.toggle() } label: {
                Label(store.shares[site.id] == nil ? "Partilhar" : "Partilhado",
                      systemImage: store.shares[site.id] == nil ? "link" : "link.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .help(store.shares[site.id] == nil ? "Partilhar com o cliente por link" : "Partilhado por link")
            .popover(isPresented: $showShare, arrowEdge: .bottom) { SharePopover(site: site) }
            Menu {
                SiteMenu(site: site, onRename: onRename, onDelete: onDelete)
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
            }
            .help("Mais ações")
        }
    }

    // MARK: Secções

    private var identity: some View {
        HStack(spacing: 14) {
            SiteIcon(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(site.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Button(action: onRename) { Image(systemName: "pencil").iconHitTarget() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Mudar o nome do site")
                        .accessibilityLabel("Mudar o nome do site")
                }
                Link(site.url.absoluteString, destination: site.url)
                    .disabled(!running)
                Text("WordPress \(site.wpVersion) · PHP \(Runtime.phpVersion) · \(db.engine.title) \(db.targetVersion)"
                    .trimmingCharacters(in: .whitespaces))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var accessSection: some View {
        Section {
            LabeledContent("Utilizador") { CopyableText(site.adminUser, what: L("utilizador do WordPress")) }
            LabeledContent("Palavra-passe") { SecretText(value: site.adminPassword, what: L("palavra-passe do WordPress")) }
            if credentialsValid == false {
                Banner(text: L("Estas credenciais já não funcionam neste site (foi restaurado com o WPvivid?)."))
            }
            HStack {
                if resetting { ProgressView().controlSize(.small) }
                Spacer()
                Button(credentialsValid == false ? "Repor acesso" : "Gerar nova palavra-passe…") {
                    if credentialsValid == false { resetAccess() } else { confirmReset = true }
                }
                .disabled(resetting)
            }
        } header: {
            Text("Acesso ao WordPress")
        } footer: {
            Text("WP Admin entra já com sessão iniciada, com um código de uso único válido 60 segundos e só neste Mac.")
        }
    }

    private var databaseSection: some View {
        Section("Base de dados") {
            LabeledContent("Motor", value: "\(db.engine.title) \(db.targetVersion)".trimmingCharacters(in: .whitespaces))
            if db.engine.needsServer {
                LabeledContent("Onde", value: db.managed ? L("Neste Mac (gerida pela app)") : L("Servidor existente"))
                LabeledContent("Nome") { CopyableText(db.name, what: L("nome da base de dados")) }
                LabeledContent("Utilizador") { CopyableText(db.user, what: L("utilizador da base de dados")) }
                LabeledContent("Palavra-passe") { SecretText(value: db.password, what: L("palavra-passe da base de dados")) }
                LabeledContent("Servidor") { CopyableText("\(db.host):\(String(db.port))", what: L("endereço do servidor")) }
            } else {
                LabeledContent("Ficheiro", value: "wp-content/database/.ht.sqlite")
            }
        }
    }

    private var exportSection: some View {
        Section {
            if db.engine.needsServer {
                LabeledContent {
                    HStack(spacing: 8) {
                        if exporting {
                            ProgressView().controlSize(.small)
                            Text("A criar o backup…").foregroundStyle(.secondary)
                        }
                        Button { showExclusions.toggle() } label: { Image(systemName: "info.circle").iconHitTarget() }
                            .buttonStyle(.borderless)
                            .help("O que fica de fora")
                            .accessibilityLabel("O que fica de fora da exportação")
                            .popover(isPresented: $showExclusions, arrowEdge: .bottom) { exclusions }
                        Button("Exportar…") { export() }.disabled(exporting)
                    }
                } label: {
                    Text("Backup do WPvivid")
                    Text("Pronto a restaurar no servidor, sem o que só existe no Mac.")
                }
                if let exportError { ErrorText(exportError) }
                if let collationTables {
                    let list = collationTables.joined(separator: ", ")
                    Banner(text: collationTables.count == 1
                        ? L("1 tabela usa uma colação só do MySQL 8, que o MariaDB do cPanel recusa: \(list).")
                        : L("\(collationTables.count) tabelas usam uma colação só do MySQL 8, que o MariaDB do cPanel recusa: \(list)."))
                    HStack {
                        Spacer()
                        Button("Exportar sem converter") { export(.ignore) }
                            .help("Só se o seu cPanel usar MySQL 8")
                        Button("Converter e exportar") { export(.convert) }
                            .buttonStyle(.borderedProminent)
                            .help("Converte para utf8mb4_unicode_ci (funciona em MySQL e MariaDB); os dados mantêm-se")
                    }
                    .disabled(exporting)
                }
                if let result = exportResult {
                    LabeledContent {
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
                    } label: {
                        Label {
                            let size = ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file)
                            Text(result.files.count == 1 ? L("1 ficheiro · \(size)") : L("\(result.files.count) ficheiros · \(size)"))
                            Text(result.folder.lastPathComponent)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            } else {
                Text("Este site usa SQLite. O cPanel precisa de MySQL ou MariaDB.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Exportar para cPanel")
        } footer: {
            if db.engine.needsServer {
                Text("Guardado em \(exportDestination). No cPanel: WPvivid → Backup & Restore → Upload → Restore.")
            }
        }
    }

    /// Onde a exportação vai parar, como o Finder o mostra (p.ex. "Descargas").
    private var exportDestination: String {
        Prefs.asksExportLocation ? L("a pasta que escolher") : FileManager.default.displayName(atPath: Prefs.exportDirectory.path)
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fica de fora da exportação").font(.headline)
            ForEach([L("Restos do Studio (base de dados SQLite, plugin SQLite, carregador)"),
                     L("mu-plugins de desenvolvimento (dev-*) e a entrada automática do WP Center"),
                     L("Ficheiros para agentes de IA (AGENTS.md, CLAUDE.md…)")], id: \.self) {
                Label($0, systemImage: "minus.circle").font(.callout)
            }
            Text("O wp-config.php do cPanel nunca é substituído.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private var detailsSection: some View {
        Section("Detalhes") {
            LabeledContent("Pasta") {
                HStack(spacing: 6) {
                    Text(site.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) } label: { Image(systemName: "folder").iconHitTarget() }
                        .buttonStyle(.borderless).help("Mostrar no Finder").accessibilityLabel("Mostrar a pasta no Finder")
                }
            }
            LabeledContent("WordPress", value: site.wpVersion)
            LabeledContent("PHP", value: Runtime.phpVersion)
            LabeledContent("Criado", value: site.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    // MARK: Ações

    private func export(_ collations: SiteStore.CollationPolicy = .check) {
        var directory = Prefs.exportDirectory
        if Prefs.asksExportLocation {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = directory
            panel.prompt = L("Exportar aqui")
            panel.message = L("Escolha onde guardar o backup de \(site.name)")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            directory = url
        }
        exporting = true
        exportError = nil
        collationTables = nil
        exportResult = nil
        Task {
            do {
                exportResult = try await store.exportForCPanel(site, collations: collations, to: directory)
                announce("Exportação concluída")
            } catch let error as SiteStore.IncompatibleCollationError {
                collationTables = error.tables
                announce("Há tabelas com uma colação que o cPanel recusa")
            } catch {
                exportError = error.localizedDescription
                announce("A exportação falhou: \(error.localizedDescription)")
            }
            exporting = false
        }
    }

    private func resetAccess() {
        resetting = true
        Task {
            do {
                try await store.resetAccess(site)
                credentialsValid = true
            } catch {
                store.errorMessage = L("Não foi possível repor o acesso: \(error.localizedDescription)")
            }
            resetting = false
        }
    }
}

/// Popover do botão Partilhar: criar o link, copiá-lo, abri-lo e terminá-lo.
private struct SharePopover: View {
    @EnvironmentObject var store: SiteStore
    let site: Site

    var body: some View {
        let share = store.shares[site.id]
        VStack(alignment: .leading, spacing: 12) {
            Text("Partilhar com o cliente").font(.headline).accessibilityAddTraits(.isHeader)
            if let share, let url = share.url {
                Text(url.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button(role: .destructive) { store.stopSharing(site) } label: { Text("Terminar partilha") }
                        .help("Fechar o link: deixa de funcionar de imediato")
                    Spacer()
                    Button("Abrir") { Prefs.openInBrowser(url) }
                    Button("Copiar link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        announce("Copiado")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else if share != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("A criar o link…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancelar") { store.stopSharing(site) }
                }
            } else {
                Text("Cria um link público temporário (Cloudflare), sem conta. Funciona só enquanto estiver aberto e termina ao parar o site ou sair do WP Center.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(store.isRunning(site) ? "Criar link" : "Iniciar e criar link") { Task { await store.share(site) } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// Site escolhido na janela, para o menu Site da barra de menus.
struct SelectedSiteKey: FocusedValueKey { typealias Value = Site.ID }

extension FocusedValues {
    var selectedSite: Site.ID? {
        get { self[SelectedSiteKey.self] }
        set { self[SelectedSiteKey.self] = newValue }
    }
}

/// Menu "Site" da barra de menus: as ações do site escolhido, com os atalhos de teclado.
struct SiteCommands: Commands {
    @FocusedValue(\.selectedSite) private var siteID

    var body: some Commands {
        CommandMenu("Site") { SiteCommandItems(siteID: siteID) }
    }
}

private struct SiteCommandItems: View {
    let siteID: Site.ID?
    @ObservedObject private var store = SiteStore.shared

    var body: some View {
        let site = store.sites.first { $0.id == siteID }
        Group {
            if let site, store.isRunning(site) {
                Button("Parar") { store.stop(site) }.keyboardShortcut("r")
            } else {
                Button("Iniciar") { if let site { Task { await store.start(site) } } }.keyboardShortcut("r")
            }
            Button("Abrir site") { if let site { Prefs.openInBrowser(site.url) } }.keyboardShortcut("o")
            Button("Abrir WP Admin") { if let site { Task { await store.openAdmin(site) } } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            if let site {
                ShareMenuItems(site: site).environmentObject(store)
            } else {
                Button("Partilhar por link") {}
            }
            Divider()
            Button("Mostrar no Finder") { if let site { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) } }
            Button("Abrir no editor") { if let site { Prefs.openInEditor(site.folder) } }
                .disabled(Prefs.preferredEditor == nil)
            Button("Abrir no Terminal") { if let site { Prefs.openInTerminal(site.folder) } }
        }
        .disabled(site == nil)
        Divider()
        Button("Ver emails") { Task { await store.openMail() } }.keyboardShortcut("e", modifiers: [.command, .shift])
    }
}

// MARK: - Componentes

private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Alvo de clique de 22×22 pt para botões só com ícone (os símbolos ficam com ~10 pt, difíceis de acertar).
extension View {
    func iconHitTarget() -> some View { frame(minWidth: 22, minHeight: 22).contentShape(Rectangle()) }
}

/// Lido pelo VoiceOver quando algo muda sem mudar o foco (copiar, link pronto, exportação).
@MainActor func announce(_ text: String.LocalizationValue) {
    AccessibilityNotification.Announcement(L(text)).post()
}

/// Erro com o ícone a vermelho e o texto em cor normal: vermelho sobre fundo claro não tem contraste suficiente.
private struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
    }
}

private struct Banner: View {
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `what`: o que é, em minúsculas ("palavra-passe do WordPress"), para os botões dizerem o que copiam/mostram.
private struct SecretText: View {
    let value: String
    let what: String
    @State private var revealed = false
    var body: some View {
        HStack(spacing: 6) {
            Text(revealed ? value : String(repeating: "•", count: 12))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .accessibilityLabel(revealed ? value : L("Oculta")) // senão o VoiceOver lê 12 vezes "ponto"
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").iconHitTarget() }
                .buttonStyle(.borderless)
                .help(revealed ? "Ocultar" : "Mostrar")
                .accessibilityLabel(revealed ? L("Ocultar \(what)") : L("Mostrar \(what)"))
            CopyButton(value: value, what: what)
        }
    }
}

private struct CopyableText: View {
    let value: String
    let what: String
    init(_ value: String, what: String) { self.value = value; self.what = what }
    var body: some View {
        HStack(spacing: 6) { Text(value).textSelection(.enabled); CopyButton(value: value, what: what) }
    }
}

private struct CopyButton: View {
    let value: String
    let what: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            announce("Copiado")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").iconHitTarget()
        }
        .buttonStyle(.borderless)
        .help("Copiar")
        .accessibilityLabel("Copiar \(what)")
    }
}

// MARK: - Mudar nome

struct RenameSiteView: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss
    let site: Site

    @State private var name = ""
    @State private var updateWordPress = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SiteIcon(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mudar o nome do site").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(site.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("Nome do site", text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(save)
            Toggle("Usar também como título do site no WordPress", isOn: $updateWordPress)
            Text("A pasta do site (\(site.folder.lastPathComponent)) não muda.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                ErrorText(error).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small).padding(.horizontal, 12) } else { Text("Guardar") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || name == site.name)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { name = site.name }
    }

    private func save() {
        guard !saving, name != site.name else { return }
        saving = true
        error = nil
        Task {
            do {
                try await store.rename(site, to: name, updateWordPress: updateWordPress)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: - Novo site

struct NewSiteView: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Site) -> Void

    @State private var name = L("O meu site")
    @State private var directory = SiteStore.defaultDirectory
    @State private var user = Prefs.customAdminUser ?? SiteStore.defaultAdminUser
    @State private var password = SiteStore.strongPassword(length: 20)
    @State private var db = Prefs.defaultDatabase
    @State private var creating = false
    @State private var installing = false
    @State private var testing = false
    @State private var test: (ok: Bool, text: String)?
    @State private var error: String?
    @State private var showCPanel = false

    private var server: LocalServer { LocalServer(db) }
    private var usesLocalServer: Bool { db.engine.needsServer && db.managed }

    // Formulário agrupado, como as folhas da Apple: rótulos à esquerda, ajuda nos rodapés das secções.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Novo site WordPress")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                siteSection
                accessSection
                databaseSection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 540, height: 640)
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .onChange(of: db) { test = nil }
        .onChange(of: db.engine) { _, engine in db.targetVersion = engine.defaultVersion }
        .onAppear {
            // Reutiliza o último utilizador por conveniência; nunca a palavra-passe.
            if Prefs.customAdminUser == nil, let last = store.sites.last { user = last.adminUser }
        }
    }

    // MARK: Secções

    private var siteSection: some View {
        Section("Site") {
            TextField("Nome", text: $name, prompt: Text("O meu site")).accessibilityLabel("Nome do site")
            LabeledContent("Pasta") {
                HStack {
                    Text(directory.appendingPathComponent(SiteStore.slug(name)).path)
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    Button("Escolher…", action: chooseDirectory)
                }
            }
        }
    }

    private var accessSection: some View {
        Section {
            TextField("Utilizador", text: $user).accessibilityLabel("Utilizador do WordPress")
            LabeledContent("Palavra-passe") {
                HStack(spacing: 6) {
                    TextField("Palavra-passe", text: $password).labelsHidden().font(.body.monospaced())
                    Button { password = SiteStore.strongPassword(length: 20) } label: { Image(systemName: "arrow.clockwise").iconHitTarget() }
                        .buttonStyle(.borderless).help("Gerar outra palavra-passe").accessibilityLabel("Gerar outra palavra-passe")
                    CopyButton(value: password, what: L("palavra-passe"))
                }
            }
        } header: {
            Text("Acesso ao WordPress")
        } footer: {
            Text("O botão WP Admin da app entra sem a escrever.")
        }
    }

    private var databaseSection: some View {
        Section {
            Picker("Motor", selection: $db.engine) {
                ForEach(DatabaseEngine.allCases.filter(\.isAvailable)) { Text($0.title).tag($0) }
            }
            if db.engine.needsServer {
                Picker("Versão", selection: $db.targetVersion) {
                    ForEach(db.engine.cpanelVersions, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Usar um servidor de base de dados existente", isOn: Binding(
                    get: { !db.managed }, set: { db.managed = !$0 }))
                if db.managed { serverStatus } else { existingServerFields }
            }
        } header: {
            Text("Base de dados")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(db.engine.summary)
                if usesLocalServer {
                    Text("Base de dados, utilizador e palavra-passe criados ao acaso, no formato do cPanel (prefixo_nome).")
                }
                if db.engine.needsServer {
                    Button("Versões do cPanel…") { showCPanel = true }.buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private var existingServerFields: some View {
        TextField("Servidor", text: $db.host, prompt: Text("127.0.0.1"))
        TextField("Porta", value: $db.port, format: .number.grouping(.never))
        TextField("Nome da base de dados", text: $db.name, prompt: Text("gerada ao acaso se ficar vazia"))
        TextField("Utilizador da base de dados", text: $db.user)
        SecureField("Palavra-passe da base de dados", text: $db.password)
        HStack(spacing: 8) {
            if let test {
                Label { Text(test.text) } icon: {
                    Image(systemName: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(test.ok ? .green : .orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if testing { ProgressView().controlSize(.small) }
            Button("Testar ligação", action: testConnection).disabled(testing)
        }
    }

    @ViewBuilder private var serverStatus: some View {
        LabeledContent("Neste Mac") {
            if !server.isSupportedOnMac {
                Label { Text("\(server.title) não existe para Mac — escolha outra versão") } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
                }
            } else if server.isInstalled {
                Label { Text("\(server.title) instalado") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            } else if installing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A instalar…") }
            } else {
                Button("Instalar \(server.title)", action: installServer)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                ErrorText(error).font(.callout).lineLimit(3)
            }
            Spacer()
            Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
            Button(action: create) {
                if creating {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A criar…") }
                } else {
                    Text("Criar site")
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var canCreate: Bool {
        guard !creating, !installing, db.engine.isAvailable, !SiteStore.slug(name).isEmpty,
              !user.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return false }
        return !usesLocalServer || server.isInstalled
    }

    // MARK: Ações

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    private func installServer() {
        installing = true
        error = nil
        Task {
            defer { installing = false }
            do { try await store.install(server) } catch { self.error = error.localizedDescription }
        }
    }

    private func testConnection() {
        testing = true
        Task {
            defer { testing = false }
            var probe = db
            if probe.name.isEmpty { probe.name = SiteStore.cpanelStyleIdentifier() }
            do { test = try await DatabaseProbe.run(probe, create: false).verdict(for: probe) }
            catch { test = (false, error.localizedDescription) }
        }
    }

    private func create() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let site = try await store.create(name: name, in: directory, adminUser: user, adminPassword: password, database: db)
                SiteStore.defaultDirectory = directory
                onCreated(site)
                await store.start(site)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Bases de dados do cPanel

struct CPanelView: View {
    @Environment(\.dismiss) private var dismiss

    /// Colunas da matriz: cada versão que o cPanel deixa escolher, mais o PostgreSQL.
    private let columns: [(engine: DatabaseEngine, version: String)] =
        DatabaseEngine.mysql.cpanelVersions.map { (.mysql, $0) } + DatabaseEngine.mariadb.cpanelVersions.map { (.mariadb, $0) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    // Folha de largura fixa: os três motores lado a lado, com a mesma altura.
                    HStack(alignment: .top, spacing: 12) { engineCards }
                        .fixedSize(horizontal: false, vertical: true)
                    matrix
                    notes
                }
                .padding(24)
            }
            Divider()
            HStack {
                Label("Fonte: documentação oficial do cPanel (docs.cpanel.net), revista em julho de 2026", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 880, height: 760)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "server.rack").font(.title2).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text("Bases de dados do cPanel").font(.title2.weight(.semibold))
                Text("O que o cPanel & WHM 136 ou superior permite instalar num servidor novo.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var engineCards: some View {
        EngineSummary(engine: .mariadb, badge: "Padrão do cPanel", badgeColor: .green,
                      note: "As versões 10.5 e 10.6 só existem em AlmaLinux e CloudLinux 8 e 9.")
        EngineSummary(engine: .mysql, badge: nil, badgeColor: .clear,
                      note: "O MySQL 8.0 não está disponível em AlmaLinux nem CloudLinux 10.")
        EngineSummary(engine: .postgresql, badge: "Sem WordPress", badgeColor: .orange,
                      note: "Usa a versão incluída no sistema operativo, instalada com o script installpostgres. Não existe em Ubuntu.")
    }

    private var matrix: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Disponibilidade por sistema operativo", systemImage: "square.grid.3x3").font(.headline)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Sistema").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    ForEach(columns, id: \.version) { column in
                        VStack(spacing: 1) {
                            Text(column.engine.title).font(.caption2).foregroundStyle(.secondary)
                            Text(column.version).font(.caption.weight(.semibold))
                        }
                    }
                    VStack(spacing: 1) {
                        Text("PostgreSQL").font(.caption2).foregroundStyle(.secondary)
                        Text("SO").font(.caption.weight(.semibold))
                    }
                }
                .padding(.vertical, 6)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(CPanelSupportRow.all) { row in
                    GridRow {
                        Text(row.os).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns, id: \.version) { column in
                            mark((column.engine == .mysql ? row.mysql : row.mariadb).contains(column.version),
                                 L("\(column.engine.title) \(column.version) em \(row.os)"))
                        }
                        mark(row.postgresql != "Não suportado", L("PostgreSQL em \(row.os)"))
                    }
                    .padding(.vertical, 7)
                    if row.id != CPanelSupportRow.all.last?.id {
                        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            HStack(spacing: 16) {
                Label { Text("Disponível") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Label { Text("Não disponível") } icon: { Image(systemName: "minus").foregroundStyle(.tertiary) }
                Label { Text("Versão por omissão") } icon: { Image(systemName: "circle.fill").foregroundStyle(.green) }
            }
            .font(.caption)
        }
        .padding(16)
        .background(CardBackground())
    }

    /// `context` diz ao VoiceOver a linha e a coluna ("MariaDB 10.11 em AlmaLinux 9"), que a grelha não transmite.
    private func mark(_ available: Bool, _ context: String) -> some View {
        Image(systemName: available ? "checkmark.circle.fill" : "minus")
            .foregroundStyle(available ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            .frame(minWidth: 52)
            .accessibilityLabel(available ? L("\(context): disponível") : L("\(context): não disponível"))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            note("arrow.left.arrow.right", "Cada servidor usa MySQL ou MariaDB, nunca os dois ao mesmo tempo.")
            note("clock.arrow.circlepath", "MySQL 5.7 e MariaDB 10.0 a 10.3 já não podem ser escolhidos em instalações novas.")
            note("exclamationmark.triangle", "O WordPress precisa de MySQL ou MariaDB; não funciona com PostgreSQL.")
        }
    }

    private func note(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
        }
        .font(.callout)
    }
}

private struct EngineSummary: View {
    let engine: DatabaseEngine
    let badge: LocalizedStringKey?
    let badgeColor: Color
    let note: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(engine.title, systemImage: engine.symbol).font(.headline)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.15)))
                }
            }
            if engine.cpanelVersions.isEmpty {
                Text("Versão do sistema").font(.callout.weight(.medium))
            } else {
                // Versões em etiquetas; a por omissão do cPanel fica destacada.
                HStack(spacing: 5) {
                    ForEach(engine.cpanelVersions, id: \.self) { version in
                        let isDefault = engine == .mariadb && version == engine.defaultVersion
                        Text(version)
                            .font(.callout.weight(isDefault ? .semibold : .regular).monospacedDigit())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(isDefault ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1)))
                            .accessibilityLabel(isDefault ? L("\(version), versão por omissão") : version)
                    }
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let mac = LocalServer.homebrewVersions[engine] {
                Label("Neste Mac: \(mac.joined(separator: ", "))", systemImage: "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CardBackground())
    }
}

// MARK: - Definições

/// Secções das Definições, listadas na barra lateral como nas Definições do Sistema.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, newSites, skills, apps, advanced
    var id: Self { self }

    var title: String {
        switch self {
        case .general: L("Geral")
        case .newSites: L("Novos sites")
        case .skills: L("Habilidades")
        case .apps: L("Aplicações")
        case .advanced: L("Avançado")
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .newSites: "plus.square.on.square.fill"
        case .skills: "sparkles"
        case .apps: "square.grid.2x2.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        }
    }

    fileprivate var color: Color {
        switch self {
        case .general: .gray
        case .newSites: .blue
        case .skills: .indigo
        case .apps: .purple
        case .advanced: .orange
        }
    }
}

/// Ícone branco sobre quadrado colorido, como nas Definições do Sistema.
private struct SettingsIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Linha das Definições no fundo da barra lateral, com o mesmo realce das linhas da List.
private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: action) {
            Label { Text(pane.title) } icon: { SettingsIcon(pane: pane) }
                .foregroundStyle(selected && activeState == .key ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(activeState == .key ? Color.accentColor : Color.secondary.opacity(0.2))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Uma secção das Definições, mostrada na janela principal no lugar do site.
private struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralSettings()
            case .newSites: NewSiteSettings()
            case .skills: SkillsSettings()
            case .apps: AppsSettings()
            case .advanced: AdvancedSettings()
            }
        }
        .navigationTitle(pane.title)
    }
}

/// Traz a janela principal para a frente, abrindo-a se estiver fechada.
@MainActor private func showMainWindow(_ openWindow: OpenWindowAction) {
    if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
        window.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
    NSApp.activate(ignoringOtherApps: true)
}

/// Item de menu que mostra algo na janela principal (Definições, Novo site, referência do cPanel), abrindo-a se preciso.
struct MainWindowButton: View {
    let title: LocalizedStringKey
    let request: SiteStore.WindowRequest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            SiteStore.shared.windowRequest = request
            showMainWindow(openWindow)
        }
    }
}

private struct SkillsSettings: View {
    @EnvironmentObject var store: SiteStore
    @State private var enabled = Prefs.enabledSkills

    var body: some View {
        Form {
            Section {
                ForEach(AgentSkill.all) { skill in
                    Toggle(isOn: Binding(
                        get: { enabled.contains(skill.id) },
                        set: { on in
                            Prefs.setSkill(skill.id, enabled: on)
                            enabled = Prefs.enabledSkills
                            store.syncSkillsInAllSites()
                        })) {
                        Text(skill.title)
                        Text(skill.summary)
                    }
                }
            } footer: {
                Text("Instruções que ensinam os agentes de IA (Claude Code, Codex…) a fazer tarefas de WordPress. As ativas são copiadas para .claude/skills e .agents/skills de cada site; desligar uma apaga-a de todos os sites.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.launchBehaviorKey) private var launch = LaunchBehavior.none
    @AppStorage(Prefs.quitBehaviorKey) private var quit = QuitBehavior.stop
    @AppStorage(Prefs.showMenuBarKey) private var showMenuBar = false
    @AppStorage(Prefs.exportDirectoryKey) private var exportDirectory = Prefs.exportDirectory.path
    @AppStorage(Prefs.askExportLocationKey) private var askExportLocation = false
    @State private var opensAtLogin = Prefs.opensAtLogin
    @State private var needsApproval = Prefs.loginNeedsApproval
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Abrir o WP Center ao iniciar sessão", isOn: Binding(
                    get: { opensAtLogin },
                    set: { on in
                        do { try Prefs.setOpensAtLogin(on); loginError = nil } catch { loginError = error.localizedDescription }
                        opensAtLogin = Prefs.opensAtLogin
                        needsApproval = Prefs.loginNeedsApproval
                    }))
                Picker("Ao abrir o WP Center", selection: $launch) {
                    ForEach(LaunchBehavior.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Arranque")
            } footer: {
                if let loginError {
                    ErrorText(loginError)
                } else if needsApproval {
                    HStack {
                        Text("O macOS pede autorização em Itens de início de sessão.")
                        Button("Abrir Definições do Sistema") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                    }
                }
            }

            Section {
                Picker("Ao sair do WP Center", selection: $quit) {
                    ForEach(QuitBehavior.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Saída")
            } footer: {
                Text(quit == .keep
                     ? "Os sites e as bases de dados continuam disponíveis; pare-os depois na app ou com wpc stop."
                     : "Os sites param; as bases de dados geridas pela app também.")
            }

            Section {
                LabeledContent("Guardar em") {
                    HStack {
                        Text(FileManager.default.displayName(atPath: exportDirectory))
                            .foregroundStyle(askExportLocation ? .tertiary : .secondary)
                        Button("Escolher…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = URL(fileURLWithPath: exportDirectory)
                            if panel.runModal() == .OK, let url = panel.url { exportDirectory = url.path }
                        }
                        .disabled(askExportLocation)
                    }
                }
                Toggle("Perguntar onde guardar em cada exportação", isOn: $askExportLocation)
            } header: {
                Text("Exportações para o cPanel")
            } footer: {
                Text("Cada exportação fica numa subpasta com o nome do site e a data.")
            }

            Section {
                Toggle("Mostrar o WP Center na barra de menus", isOn: $showMenuBar)
            } footer: {
                Text("Acesso rápido para iniciar, parar e abrir cada site. Com esta opção, fechar a janela não fecha a app.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct NewSiteSettings: View {
    @AppStorage(Prefs.defaultEngineKey) private var engine = DatabaseEngine.mariadb
    @AppStorage(Prefs.defaultVersionKey) private var version = DatabaseEngine.mariadb.defaultVersion
    @AppStorage(Prefs.defaultAdminUserKey) private var adminUser = ""
    @State private var directory = SiteStore.defaultDirectory

    var body: some View {
        Form {
            Section("Local") {
                LabeledContent("Pasta dos sites") {
                    HStack {
                        Text(directory.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Button("Escolher…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.directoryURL = directory
                            if panel.runModal() == .OK, let url = panel.url {
                                directory = url
                                SiteStore.defaultDirectory = url
                            }
                        }
                    }
                }
            }
            Section {
                Picker("Motor", selection: $engine) {
                    ForEach(DatabaseEngine.allCases.filter(\.isAvailable)) { Text($0.title).tag($0) }
                }
                .onChange(of: engine) { _, new in version = new.defaultVersion }
                if engine.needsServer {
                    Picker("Versão", selection: $version) {
                        ForEach(engine.cpanelVersions, id: \.self) { Text("\(engine.title) \($0)").tag($0) }
                    }
                }
            } header: {
                Text("Base de dados por omissão")
            } footer: {
                Text("Use o motor e a versão do seu servidor cPanel: cada site novo já vem com eles escolhidos.")
            }
            Section {
                TextField("Utilizador do WordPress", text: $adminUser, prompt: Text(SiteStore.defaultAdminUser))
            } header: {
                Text("Acesso por omissão")
            } footer: {
                Text("Em branco, usa o último utilizador criado. A palavra-passe é sempre nova e forte.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsSettings: View {
    @AppStorage(Prefs.browserKey) private var browser = ""
    @AppStorage(Prefs.editorKey) private var editor = ""
    @AppStorage(Prefs.terminalKey) private var terminal = "com.apple.Terminal"
    private let browsers = Prefs.browsers
    private let editors = Prefs.installed(Prefs.knownEditors)
    private let terminals = Prefs.installed(Prefs.knownTerminals)

    var body: some View {
        Form {
            Section {
                Picker("Navegador", selection: $browser) {
                    Text("Predefinido do sistema").tag("")
                    Divider()
                    ForEach(browsers) { Text($0.name).tag($0.bundleID) }
                }
                Picker("Editor de código", selection: $editor) {
                    Text(editors.first.map { L("Automático (\($0.name))") } ?? L("Nenhum instalado")).tag("")
                    if !editors.isEmpty { Divider() }
                    ForEach(editors) { Text($0.name).tag($0.bundleID) }
                }
                Picker("Terminal", selection: $terminal) {
                    ForEach(terminals) { Text($0.name).tag($0.bundleID) }
                }
            } footer: {
                Text("Usados em Abrir site, WP Admin, Abrir no editor e Abrir no Terminal.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @EnvironmentObject var store: SiteStore
    @State private var cliInstalled = CLI.isInstalled
    @State private var cliError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Comando wpc no terminal", isOn: Binding(
                    get: { cliInstalled },
                    set: { on in
                        do { try on ? CLI.install() : CLI.uninstall(); cliError = nil } catch { cliError = error.localizedDescription }
                        cliInstalled = CLI.isInstalled
                    }))
            } footer: {
                if let cliError {
                    ErrorText(cliError)
                } else {
                    Text("wpc wp …, wpc start, wpc status, wpc admin e wpc export no terminal e para agentes de IA. Abra um novo terminal depois de ativar.")
                }
            }
            Section("Incluído na app") {
                LabeledContent("WordPress", value: Runtime.bundledWordPressVersion)
                LabeledContent("PHP", value: Runtime.phpVersion)
                LabeledContent("WP Center", value: Runtime.appVersion)
            }
            Section("Dados") {
                LabeledContent("Registos e bases de dados locais") {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.storage]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
