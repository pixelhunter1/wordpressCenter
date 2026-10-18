import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Janela principal

/// O que está escolhido na barra lateral: um site local, os sites live (todos ou um) ou uma secção das Definições.
enum SidebarItem: Hashable {
    case site(Site.ID)
    case liveOverview
    case live(LiveSite.ID)
    case settings(SettingsPane)
}

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @EnvironmentObject var live: LiveStore
    @State private var selection: SidebarItem?
    @State private var search = ""
    @State private var showNewSite = false
    @State private var showImport = false
    @State private var showCPanel = false
    @State private var siteToDelete: Site?
    @State private var siteToRename: Site?
    @State private var siteToDuplicate: Site?
    /// Folha "Ligar site live"; o endereço vem preenchido ao ligar de novo um site.
    @State private var connectAddress: String?
    @AppStorage(Prefs.localSitesExpandedKey) private var localExpanded = true

    private var filteredSites: [Site] {
        search.isEmpty ? store.sites : store.sites.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var showsLive: Bool {
        switch selection {
        case .liveOverview, .live: true
        default: false
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sites locais", isExpanded: $localExpanded) {
                    ForEach(filteredSites) { site in
                        SiteRow(site: site, running: store.isRunning(site), shared: store.shares[site.id] != nil)
                            .tag(SidebarItem.site(site.id))
                            .contextMenu {
                                SiteMenu(site: site, onRename: { siteToRename = site }, onDuplicate: { siteToDuplicate = site }) { siteToDelete = site }
                            }
                    }
                }
                LiveSidebarSection(search: search) { connectAddress = "" }
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
                // Com muitos sites a lista passa por baixo: sem fundo, as linhas viam-se através das Definições.
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        } detail: {
            if case .settings(let pane) = selection {
                SettingsPaneView(pane: pane)
            } else if selection == .liveOverview {
                LiveOverviewView(onOpen: { selection = .live($0) }) { connectAddress = "" }
            } else if case .live(let id) = selection, let site = live.sites.first(where: { $0.id == id }) {
                LiveSiteDetailView(site: site) { connectAddress = site.url.absoluteString }
                    .id(site.id)
            } else if case .site(let id) = selection, let site = store.sites.first(where: { $0.id == id }) {
                SiteDetailView(site: site, onRename: { siteToRename = site }, onDuplicate: { siteToDuplicate = site }) { siteToDelete = site }
                    .id(site.id)
            } else {
                ContentUnavailableView {
                    Label(store.sites.isEmpty ? "Ainda não há sites" : "Selecione um site", systemImage: "globe")
                } description: {
                    Text("Sites WordPress locais, a correr no seu Mac, sem contas nem serviços externos.")
                } actions: {
                    Button("Novo site") { showNewSite = true }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Importar site…") { showImport = true }.buttonStyle(.link)
                }
            }
        }
        .toolbar {
            // Nos sites live a barra tem as ações deles (verificar, atualizar, ligar): os botões dos sites locais saem.
            if !showsLive {
                ToolbarItem {
                    Button { showImport = true } label: { Label("Importar site…", systemImage: "square.and.arrow.down") }
                        .help("Importar uma exportação da WP Center, do WordPress Studio ou do Local, ou um backup do WPvivid")
                }
                ToolbarItem {
                    Button { showNewSite = true } label: { Label("Novo site", systemImage: "plus") }
                        .foregroundStyle(.tint) // a ação principal da app: "+" azul, no mesmo grupo dos outros botões
                        .help("Criar um novo site WordPress (⌘N)") // o atalho vive no menu Ficheiro
                }
            }
        }
        .sheet(isPresented: Binding(get: { connectAddress != nil }, set: { if !$0 { connectAddress = nil } })) {
            ConnectLiveSiteView(address: connectAddress ?? "")
        }
        .onChange(of: live.justConnected) { _, id in if let id { selection = .live(id) } }
        .sheet(isPresented: $showNewSite) {
            NewSiteView { selection = .site($0.id) }
        }
        .sheet(isPresented: $showImport) {
            ImportSitesView { selection = .site($0.id) }
        }
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .sheet(item: $siteToRename) { RenameSiteView(site: $0) }
        .sheet(item: $siteToDuplicate) { DuplicateSiteView(site: $0) { selection = .site($0.id) } }
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
        case .importSites: showImport = true
        case .connectLive: connectAddress = ""
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
    let onDuplicate: () -> Void
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
        Button("Duplicar…", action: onDuplicate)
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
    let onDuplicate: () -> Void
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
    @State private var exportingWPC = false
    @State private var exportWPCError: String?
    @State private var exportWPCFile: URL?
    @State private var showShare = false
    @State private var health: SiteStore.SiteHealth?
    @State private var space: SiteStore.SiteSpace?
    @State private var confirmTrash = false
    @State private var trashing = false

    private var running: Bool { store.isRunning(site) }
    private var db: DatabaseConfig { site.database }

    // Formulário agrupado, como nas Definições do Sistema; as ações vivem na barra de ferramentas e no menu Site.
    var body: some View {
        Form {
            Section { identity }
            statusSection
            accessSection
            databaseSection
            exportSection
            spaceSection
            detailsSection
        }
        .formStyle(.grouped)
        .navigationTitle(site.name)
        .navigationSubtitle(starting ? "A iniciar…" : running ? "A correr" : "Parado")
        .toolbar { toolbar }
        .focusedSceneValue(\.selectedSite, site.id)
        .task(id: running) {
            health = nil
            await readStatus()
        }
        // Atualizar no WP Admin passa-se no navegador: volta a ler quando o utilizador regressa à app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readStatus() }
        }
        .task(id: site.id) { await loadSpace() }
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
                Button { store.stop(site) } label: { ToolbarLabel("Parar", symbol: "stop.fill", color: .red) }
                    .help("Parar o site (⌘R)")
            } else {
                Button {
                    starting = true
                    Task { await store.start(site); starting = false }
                } label: {
                    ToolbarLabel("Iniciar", symbol: "play.fill", color: .green)
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
                if store.shares[site.id] == nil {
                    Label("Partilhar", systemImage: "link").labelStyle(.titleAndIcon)
                } else {
                    ToolbarLabel("Partilhado", symbol: "link.circle.fill", color: .green)
                }
            }
            .help(store.shares[site.id] == nil ? "Partilhar com o cliente por link" : "Partilhado por link")
            .popover(isPresented: $showShare, arrowEdge: .bottom) { SharePopover(site: site) }
            Menu {
                SiteMenu(site: site, onRename: onRename, onDuplicate: onDuplicate, onDelete: onDelete)
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
                Text("WordPress \(site.wpVersion) · PHP \(PHPVersions.display(site.php)) · \(db.engine.title) \(db.targetVersion)"
                    .trimmingCharacters(in: .whitespaces))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusSection: some View {
        Section {
            if !running {
                Text("Inicie o site para ver o estado.").foregroundStyle(.secondary)
            } else if let health {
                LabeledContent("WordPress \(site.wpVersion)") {
                    if let core = health.core { StatusText("\(core) disponível", .update) } else { StatusText("Atualizado", .ok) }
                }
                updatesRow("Plugins", health.plugins, checked: health.checked)
                updatesRow("Temas", health.themes, checked: health.checked)
                updatesRow("Traduções", health.translations, checked: health.checked)
                LabeledContent("Modo debug") {
                    if health.debug { StatusText("Ligado: desligue antes de exportar", .warning) } else { StatusText("Desligado", .ok) }
                }
                if health.core != nil || !health.plugins.isEmpty || !health.themes.isEmpty || !health.translations.isEmpty {
                    HStack {
                        Spacer()
                        Button("Atualizar no WP Admin") { Task { await store.openAdmin(site, page: "update-core.php") } }
                    }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("A ler o estado…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Estado")
        } footer: {
            Text("Lido do próprio WordPress, sem contactar a internet: as atualizações são as que ele encontrou da última vez que verificou.")
        }
    }

    private func readStatus() async {
        guard running else { return }
        credentialsValid = await store.credentialsAreValid(site)
        health = try? await store.health(site)
    }

    private func updatesRow(_ title: LocalizedStringKey, _ names: [String], checked: Bool) -> some View {
        LabeledContent(title) {
            if !checked {
                StatusText("Por verificar", .unknown)
            } else if names.isEmpty {
                StatusText("Atualizados", .ok)
            } else {
                StatusText(names.count == 1 ? "1 por atualizar" : "\(names.count) por atualizar", .update)
                    .help(names.joined(separator: ", "))
            }
        }
    }

    private var spaceSection: some View {
        Section {
            if let space {
                let parts = spaceParts(space)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("No disco")
                        Spacer()
                        Text(bytes(space.total)).fontWeight(.medium)
                    }
                    StorageBar(parts: parts.map { ($0.bytes, $0.color) })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(parts, id: \.name) { part in
                            HStack(spacing: 5) {
                                Circle().fill(part.color).frame(width: 8, height: 8)
                                Text("\(part.name) \(bytes(part.bytes))")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                if let newest = space.backupSets.first {
                    LabeledContent {
                        if space.backupSets.count > 1 {
                            Button("Apagar os antigos…") { confirmTrash = true }
                                .disabled(trashing)
                                .confirmationDialog("Apagar os backups WPvivid antigos?", isPresented: $confirmTrash) {
                                    Button("Mover para o Lixo", role: .destructive, action: trashOldBackups)
                                } message: {
                                    Text("Vão para o Lixo e saem da lista do WPvivid. O backup mais recente fica no site.")
                                }
                        }
                    } label: {
                        Text("Backups WPvivid no site")
                        Text(space.backupSets.count == 1
                             ? L("1 backup, de \(newest.date.formatted(date: .abbreviated, time: .omitted))")
                             : L("\(space.backupSets.count) backups, o mais recente de \(newest.date.formatted(date: .abbreviated, time: .omitted))"))
                    }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("A medir…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Espaço")
        } footer: {
            if (space?.backupSets.count ?? 0) > 1 {
                Text("“Apagar os antigos” manda para o Lixo todos os backups menos o mais recente.")
            }
        }
    }

    private func spaceParts(_ space: SiteStore.SiteSpace) -> [(name: String, bytes: Int64, color: Color)] {
        [(L("Uploads"), space.uploads, Color.blue), (L("Base de dados"), space.database ?? 0, .purple), (L("Plugins"), space.plugins, .green),
         (L("Backups WPvivid"), space.backups, .orange), (L("Resto"), space.rest, .gray)]
            .filter { $0.1 > 0 }
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    private func loadSpace() async {
        let folder = site.folder, sqlite = db.engine == .sqlite, databaseDir = store.databaseDir(of: site)
        space = await Task.detached { SiteStore.space(of: folder, sqlite: sqlite, databaseDir: databaseDir) }.value
    }

    private func trashOldBackups() {
        trashing = true
        Task {
            do {
                _ = try await store.trashOldWPvividBackups(site)
                announce("Backups antigos movidos para o Lixo")
            } catch {
                store.errorMessage = error.localizedDescription
            }
            await loadSpace()
            trashing = false
        }
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

    /// As duas exportações lado a lado: para outra WP Center (o site tal como está) e para o cPanel (WPvivid).
    private var exportSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if exportingWPC {
                        ProgressView().controlSize(.small)
                        Text("A criar o ficheiro…").foregroundStyle(.secondary)
                    }
                    Button("Exportar…", action: exportWPC).disabled(exportingWPC)
                }
            } label: {
                Text("Para outra WP Center")
                Text("O site completo e a base de dados num só .zip. Importe-o noutro Mac em Ficheiro → Importar site.")
            }
            if let exportWPCError { ErrorText(exportWPCError) }
            if let file = exportWPCFile {
                LabeledContent {
                    Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                } label: {
                    Label {
                        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        Text(file.lastPathComponent)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

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
                    Text("Para cPanel (WPvivid)")
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
                LabeledContent("Para cPanel (WPvivid)") {
                    Text("Precisa de MySQL ou MariaDB (este site usa SQLite).").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Exportar")
        } footer: {
            Text(db.engine.needsServer
                ? L("Guardado em \(exportDestination). No cPanel: WPvivid → Backup & Restore → Upload → Restore.")
                : L("Guardado em \(exportDestination)."))
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
            Picker("PHP", selection: Binding(
                get: { site.php },
                set: { version in
                    Task {
                        do { try await store.setPHP(site, to: version) } catch { store.errorMessage = error.localizedDescription }
                    }
                })) {
                // Só as instaladas (e a atual); as outras instalam-se em Definições → Avançado.
                ForEach(PHPVersions.all.filter { PHPVersions.isInstalled($0) || $0 == site.php }, id: \.self) {
                    Text(PHPVersions.display($0)).tag($0)
                }
            }
            .help("Muda a versão de PHP deste site; se estiver a correr, reinicia-o")
            LabeledContent("Criado", value: site.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    // MARK: Ações

    /// A pasta de exportações das Definições, ou a que o utilizador escolher (se assim o pediu). nil = cancelou.
    private func exportDirectory() -> URL? {
        guard Prefs.asksExportLocation else { return Prefs.exportDirectory }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.exportDirectory
        panel.prompt = L("Exportar aqui")
        panel.message = L("Escolha onde guardar a exportação de \(site.name)")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportWPC() {
        guard let directory = exportDirectory() else { return }
        exportingWPC = true
        exportWPCError = nil
        exportWPCFile = nil
        Task {
            do {
                exportWPCFile = try await store.exportForWPCenter(site, to: directory)
                announce("Exportação concluída")
            } catch {
                exportWPCError = error.localizedDescription
                announce("A exportação falhou: \(error.localizedDescription)")
            }
            exportingWPC = false
        }
    }

    private func export(_ collations: SiteStore.CollationPolicy = .check) {
        guard let directory = exportDirectory() else { return }
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

/// Alvo de clique de 22×22 pt para botões só com ícone (os símbolos ficam com ~10 pt, difíceis de acertar).
extension View {
    func iconHitTarget() -> some View { frame(minWidth: 22, minHeight: 22).contentShape(Rectangle()) }
}

/// Lido pelo VoiceOver quando algo muda sem mudar o foco (copiar, link pronto, exportação).
@MainActor func announce(_ text: String.LocalizationValue) {
    AccessibilityNotification.Announcement(L(text)).post()
}

/// Botão da barra de ferramentas com o ícone a cores e o texto normal: o estado (iniciar, parar, partilhado) vê-se de relance.
struct ToolbarLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    init(_ title: LocalizedStringKey, symbol: String, color: Color) { self.title = title; self.symbol = symbol; self.color = color }

    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .labelStyle(.titleAndIcon)
    }
}

/// Estado de uma linha do cartão Estado: o ícone diz se está bem, o texto diz o quê (distinguível sem cores).
struct StatusText: View {
    enum Kind { case ok, update, warning, unknown }
    let text: LocalizedStringKey
    let kind: Kind
    init(_ text: LocalizedStringKey, _ kind: Kind) { self.text = text; self.kind = kind }

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .update: Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unknown: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

/// Barra do espaço por partes, como a do Armazenamento nas Definições do Sistema. A legenda ao lado tem os números.
private struct StorageBar: View {
    let parts: [(bytes: Int64, color: Color)]

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, parts.reduce(0) { $0 + $1.bytes }))
            HStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { i in
                    parts[i].color.frame(width: max(2, geo.size.width * CGFloat(parts[i].bytes) / total))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Erro com o ícone a vermelho e o texto em cor normal: vermelho sobre fundo claro não tem contraste suficiente.
struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
    }
}

struct Banner: View {
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

// MARK: - Duplicar

/// Cópia completa do site (ficheiros e base de dados), ao lado do original, com outro nome.
struct DuplicateSiteView: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let onDuplicated: (Site) -> Void

    @State private var name = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SiteIcon(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicar site").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(site.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TextField("Nome da cópia", text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .onSubmit(duplicate)
                .disabled(working)
            Text("Copia os ficheiros e a base de dados. A cópia tem endereço e palavra-passe próprios; o original não muda.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                ErrorText(error).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(action: duplicate) {
                    if working {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A duplicar…") }
                    } else {
                        Text("Duplicar")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working || SiteStore.slug(name).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(working)
        .onAppear { name = L("\(site.name) (cópia)") }
    }

    private func duplicate() {
        guard !working, !SiteStore.slug(name).isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                let copy = try await store.duplicate(site, name: name)
                announce("Site duplicado")
                onDuplicated(copy)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
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
    @State private var php = Prefs.defaultPHP
    @State private var installingPHP = false
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
            SheetHeader(title: "Novo site WordPress",
                        subtitle: "WordPress \(Runtime.bundledWordPressVersion), no seu Mac e sem serviços externos.")
            Form {
                siteSection
                accessSection
                databaseSection
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder) // no formulário agrupado, sem moldura não se distingue o que se pode escrever
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
            Picker("PHP", selection: $php) {
                ForEach(PHPVersions.all, id: \.self) { Text(PHPVersions.display($0)).tag($0) }
            }
            if !PHPVersions.isInstalled(php) {
                LabeledContent("Neste Mac") {
                    if installingPHP {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A instalar…") }
                    } else {
                        Button("Instalar PHP \(php)", action: installPHP)
                    }
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
        SheetFooter {
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
    }

    private var canCreate: Bool {
        guard !creating, !installing, !installingPHP, PHPVersions.isInstalled(php), db.engine.isAvailable, !SiteStore.slug(name).isEmpty,
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

    private func installPHP() {
        installingPHP = true
        error = nil
        Task {
            defer { installingPHP = false }
            do { try await store.installPHP(php) } catch { self.error = error.localizedDescription }
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
                let site = try await store.create(name: name, in: directory, adminUser: user, adminPassword: password, database: db, php: php)
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

// MARK: - Importar

/// Cria um site a partir de uma exportação da WP Center, do WordPress Studio, do Local ou de um backup WPvivid (escolhida ou largada na folha).
struct ImportSitesView: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss
    let onImported: (Site) -> Void

    @State private var file: URL?
    @State private var origin: ExportOrigin?
    @State private var name = ""
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Importar site", subtitle: "Exportações da WP Center, do WordPress Studio ou do Local, e backups do WPvivid (.zip ou .tar.gz).")
            Form {
                Section {
                    LabeledContent("Ficheiro") {
                        HStack {
                            Text(file?.lastPathComponent ?? L("Nenhum ficheiro escolhido"))
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Escolher…", action: chooseFile).disabled(importing)
                        }
                    }
                    if file != nil {
                        LabeledContent("Origem", value: origin?.rawValue ?? L("Confirmada ao importar"))
                    }
                    TextField("Nome", text: $name, prompt: Text("O meu site")).accessibilityLabel("Nome do site").disabled(importing)
                } footer: {
                    Text("Também pode largar o ficheiro aqui. Num backup WPvivid em várias partes, escolha uma: as outras, na mesma pasta, entram também. Os sites da WP Center mantêm a base de dados; os outros passam para o MariaDB/MySQL. O administrador recebe uma palavra-passe nova.")
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            SheetFooter {
                if let error { ErrorText(error).font(.callout).lineLimit(4) }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
                Button(action: runImport) {
                    if importing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("A importar…") }
                    } else {
                        Text("Importar")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(importing || file == nil || SiteStore.slug(name).isEmpty)
            }
        }
        .frame(width: 540, height: 370)
        .interactiveDismissDisabled(importing)
        .dropDestination(for: URL.self) { urls, _ in
            guard !importing, let url = urls.first else { return false }
            pick(url)
            return true
        }
    }

    private func pick(_ url: URL) {
        file = url
        (origin, name) = ExportOrigin.peek(url)
        error = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .gzip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { pick(url) }
    }

    private func runImport() {
        guard let file else { return }
        importing = true
        error = nil
        Task {
            defer { importing = false }
            do {
                let site = try await store.importSite(from: file, name: name)
                onImported(site)
                await store.start(site)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Bases de dados do cPanel

/// Título de uma folha, separado do formulário: o conteúdo que faz scroll não passa por baixo dele.
struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)
            Divider()
        }
    }
}

/// Barra de botões no fundo de uma folha, separada do formulário.
struct SheetFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }
}

/// Referência das versões que o cPanel deixa instalar (menu Ajuda e folha Novo site), em formulário agrupado.
struct CPanelView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Bases de dados do cPanel",
                        subtitle: "O que o cPanel & WHM 136 ou superior permite instalar num servidor novo.")
            Form {
                Section {
                    engineRows(.mariadb)
                } header: {
                    Text("MariaDB — padrão do cPanel")
                } footer: {
                    Text("As versões 10.5 e 10.6 só existem em AlmaLinux e CloudLinux 8 e 9.")
                }
                Section {
                    engineRows(.mysql)
                } header: {
                    Text("MySQL")
                } footer: {
                    Text("O MySQL 8.0 não está disponível em AlmaLinux nem CloudLinux 10.")
                }
                Section {
                    LabeledContent("Versão", value: L("A do sistema operativo"))
                } header: {
                    Text("PostgreSQL — sem WordPress")
                } footer: {
                    Text("Instalado com o script installpostgres; não existe em Ubuntu. O WordPress precisa de MySQL ou MariaDB.")
                }
                // As diferenças entre sistemas já estão nos rodapés de cada motor: aqui só a lista.
                Section {
                    LabeledContent("Sistemas operativos", value: CPanelSupportRow.all.map(\.os).joined(separator: ", "))
                } header: {
                    Text("Servidor")
                } footer: {
                    Text("Cada servidor usa MySQL ou MariaDB, nunca os dois ao mesmo tempo. MySQL 5.7 e MariaDB 10.0 a 10.3 já não podem ser escolhidos em instalações novas.")
                }
            }
            .formStyle(.grouped)
            SheetFooter {
                Text("Fonte: documentação oficial do cPanel (docs.cpanel.net), revista em julho de 2026")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560, height: 640)
    }

    @ViewBuilder private func engineRows(_ engine: DatabaseEngine) -> some View {
        LabeledContent("Versões no cPanel", value: engine.cpanelVersions.map {
            engine == .mariadb && $0 == engine.defaultVersion ? L("\($0) (por omissão)") : $0
        }.joined(separator: ", "))
        LabeledContent("Disponível para Mac", value: (LocalServer.homebrewVersions[engine] ?? []).joined(separator: ", "))
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
                Text("Exportações")
            } footer: {
                Text("Para o cPanel, uma subpasta com o nome do site e a data; para outra WP Center, um só ficheiro .zip.")
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
    @AppStorage(Prefs.defaultPHPKey) private var php = PHPVersions.bundled
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
                Picker("Versão", selection: $php) {
                    ForEach(PHPVersions.all, id: \.self) { version in
                        Text(PHPVersions.isInstalled(version) ? PHPVersions.display(version) : L("\(version) (por instalar)")).tag(version)
                    }
                }
            } header: {
                Text("PHP por omissão")
            } footer: {
                Text("Use a versão de PHP do servidor cPanel. Uma versão por instalar instala-se ao criar o site ou em Avançado.")
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
        .textFieldStyle(.roundedBorder) // no formulário agrupado, sem moldura não se distingue o que se pode escrever
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

/// Uma versão instalável com o Homebrew (PHP ou servidor de base de dados): estado e Instalar/Remover.
private struct HomebrewRow: View {
    @EnvironmentObject var store: SiteStore
    let title: String
    let installed: Bool
    let inUse: Bool
    let install: () async throws -> Void
    let remove: () async throws -> Void
    @State private var busy = false
    @State private var confirmRemove = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if installed {
                    if inUse { Text("Em uso").foregroundStyle(.secondary) }
                    Button("Remover…") { confirmRemove = true }
                        .disabled(inUse)
                        .help(inUse ? "Usado por um site: mude-o primeiro para outra versão" : "Desinstalar com o Homebrew")
                } else {
                    Button("Instalar") { run(install) }
                }
            }
        }
        .confirmationDialog("Remover \(title)?", isPresented: $confirmRemove) {
            Button("Remover", role: .destructive) { run(remove) }
        } message: {
            Text("Desinstala com o Homebrew: deixa de estar disponível também para outros programas que o usem. Pode voltar a instalá-lo mais tarde; os sites e as bases de dados não são apagados.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action() } catch { store.errorMessage = error.localizedDescription }
            busy = false
        }
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
            Section {
                ForEach(PHPVersions.all.filter { $0 != PHPVersions.bundled }, id: \.self) { version in
                    HomebrewRow(title: "PHP \(version)", installed: PHPVersions.isInstalled(version),
                                inUse: store.isInUse(php: version),
                                install: { try await store.installPHP(version) },
                                remove: { try await store.uninstallPHP(version) })
                }
            } header: {
                Text("Outras versões de PHP")
            } footer: {
                Text("Instaladas com o Homebrew só quando as pede. Uma versão em uso por um site não pode ser removida.")
            }
            Section {
                ForEach(LocalServer.homebrewVersions.sorted { $0.key.title < $1.key.title }, id: \.key) { engine, versions in
                    ForEach(versions, id: \.self) { version in
                        let server = LocalServer(DatabaseConfig(engine: engine, targetVersion: version))
                        HomebrewRow(title: server.title, installed: server.isInstalled, inUse: store.isInUse(server),
                                    install: { try await store.install(server) },
                                    remove: { try await store.uninstall(server) })
                    }
                }
            } header: {
                Text("Servidores de base de dados")
            } footer: {
                Text("Remover só apaga o programa: as bases de dados já criadas ficam guardadas e voltam a funcionar se o reinstalar.")
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
