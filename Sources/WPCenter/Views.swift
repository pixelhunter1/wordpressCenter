import AppKit
import SwiftUI

// MARK: - Janela principal

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selection: Site.ID?
    @State private var search = ""
    @State private var showNewSite = false
    @State private var showCPanel = false
    @State private var siteToDelete: Site?

    private var filteredSites: [Site] {
        search.isEmpty ? store.sites : store.sites.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sites") {
                    ForEach(filteredSites) { site in
                        SiteRow(site: site, running: store.isRunning(site))
                            .tag(site.id)
                            .contextMenu { SiteMenu(site: site) { siteToDelete = site } }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Procurar")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            .safeAreaInset(edge: .bottom) {
                Button { showCPanel = true } label: {
                    Label("Bases de dados do cPanel", systemImage: "server.rack")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
        } detail: {
            if let site = store.sites.first(where: { $0.id == selection }) {
                SiteDetailView(site: site) { siteToDelete = site }.id(site.id)
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
                    .keyboardShortcut("n")
                    .help("Criar um novo site WordPress (⌘N)")
            }
        }
        .sheet(isPresented: $showNewSite) {
            NewSiteView { selection = $0.id }
        }
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .confirmationDialog("Apagar \"\(siteToDelete?.name ?? "")\"?", isPresented: Binding(
            get: { siteToDelete != nil }, set: { if !$0 { siteToDelete = nil } }
        ), presenting: siteToDelete) { site in
            Button("Mover para o Lixo", role: .destructive) {
                Task {
                    await store.delete(site)
                    if selection == site.id { selection = store.sites.first?.id }
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
        .onAppear { selection = selection ?? store.sites.first?.id }
        // Sites iniciados/parados pelo `wpc` no terminal: refresca o estado de vez em quando.
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in store.objectWillChange.send() }
    }
}

private struct SiteRow: View {
    let site: Site
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(size: 28)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(running ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).fontWeight(.medium).lineLimit(1)
                Text("localhost:\(String(site.port)) · \(site.database.engine.title) \(site.database.targetVersion)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "A correr" : "Parado")
    }
}

/// Ações de um site, partilhadas pelo menu de contexto da barra lateral e pelo menu "Mais".
private struct SiteMenu: View {
    @EnvironmentObject var store: SiteStore
    let site: Site
    let onDelete: () -> Void

    var body: some View {
        if store.isRunning(site) {
            Button("Parar") { store.stop(site) }
        } else {
            Button("Iniciar") { Task { await store.start(site) } }
        }
        Button("Abrir site") { NSWorkspace.shared.open(site.url) }
        Button("Abrir WP Admin") { Task { await store.openAdmin(site) } }
        Divider()
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) }
        Button("Abrir no Terminal") {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open([site.folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
        Button("Copiar endereço") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(site.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Apagar site…", role: .destructive, action: onDelete)
    }
}

private struct SiteIcon: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.47, blue: 0.80), Color(red: 0.07, green: 0.20, blue: 0.42)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "globe").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

// MARK: - Detalhe do site

struct SiteDetailView: View {
    @EnvironmentObject var store: SiteStore
    let site: Site
    let onDelete: () -> Void

    @State private var starting = false
    @State private var openingAdmin = false
    @State private var credentialsValid: Bool?
    @State private var resetting = false
    @State private var confirmReset = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportResult: SiteStore.ExportResult?
    @State private var showExclusions = false

    private var running: Bool { store.isRunning(site) }
    private var db: DatabaseConfig { site.database }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                // 2 colunas equilibradas em janelas largas; 1 coluna em janelas estreitas.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) { accessCard; exportCard }.frame(minWidth: 340)
                        VStack(spacing: 16) { databaseCard; detailsCard }.frame(minWidth: 340)
                    }
                    VStack(spacing: 16) { accessCard; databaseCard; exportCard; detailsCard }
                }
            }
            .padding(24)
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(site.name)
        .navigationSubtitle(running ? "A correr" : "Parado")
        .toolbar {
            ToolbarItem {
                Menu {
                    SiteMenu(site: site, onDelete: onDelete)
                } label: {
                    Label("Mais", systemImage: "ellipsis.circle")
                }
                .help("Mais ações")
            }
        }
        .task(id: running) {
            if running { credentialsValid = await store.credentialsAreValid(site) }
        }
        .confirmationDialog("Gerar uma nova palavra-passe para \(site.adminUser)?", isPresented: $confirmReset) {
            Button("Gerar nova palavra-passe") { resetAccess() }
        } message: {
            Text("A palavra-passe atual deixa de funcionar e as sessões abertas deste utilizador terminam.")
        }
    }

    // MARK: Cabeçalho

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                identity
                Spacer(minLength: 24)
                actions
            }
            VStack(alignment: .leading, spacing: 16) {
                identity
                actions
            }
        }
        .padding(20)
        .background(CardBackground())
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 16) {
            SiteIcon(size: 60)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(site.name).font(.title2.weight(.semibold)).lineLimit(1)
                    StatusPill(running: running, busy: starting)
                }
                Link(site.url.absoluteString, destination: site.url)
                    .font(.callout)
                    .disabled(!running)
                HStack(spacing: 6) {
                    Chip(text: "WordPress \(site.wpVersion)")
                    Chip(text: "PHP \(Runtime.phpVersion)")
                    Chip(text: "\(db.engine.title) \(db.targetVersion)".trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(site.url) } label: { Label("Abrir site", systemImage: "safari") }
                .keyboardShortcut("o")
                .help("Abrir o site no navegador (⌘O)")
            Button {
                openingAdmin = true
                Task { await store.openAdmin(site); openingAdmin = false }
            } label: {
                Label("WP Admin", systemImage: "gauge.with.dots.needle.33percent")
            }
            .disabled(openingAdmin)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Abrir o painel já com sessão iniciada (⇧⌘A)")
            if running {
                Button { store.stop(site) } label: { Label("Parar", systemImage: "stop.fill") }
                    .keyboardShortcut("r")
                    .help("Parar o site (⌘R)")
            } else {
                Button {
                    starting = true
                    Task { await store.start(site); starting = false }
                } label: {
                    Label("Iniciar", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(starting)
                .keyboardShortcut("r")
                .help("Iniciar o site (⌘R)")
            }
        }
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
    }

    // MARK: Cartões

    private var accessCard: some View {
        Card(title: "Acesso ao WordPress", symbol: "person.badge.key",
             footnote: "WP Admin entra já com sessão iniciada, com um código de uso único válido 60 segundos e só neste Mac.") {
            InfoRow("Utilizador") { CopyableText(site.adminUser) }
            Divider()
            InfoRow("Palavra-passe") { SecretText(value: site.adminPassword) }
            if credentialsValid == false {
                Banner(text: "Estas credenciais já não funcionam neste site (foi restaurado com o WPvivid?).")
                    .padding(.top, 10)
            }
            HStack {
                Button(credentialsValid == false ? "Repor acesso" : "Gerar nova palavra-passe…") {
                    if credentialsValid == false { resetAccess() } else { confirmReset = true }
                }
                .buttonStyle(.bordered)
                .tint(credentialsValid == false ? .orange : nil)
                .disabled(resetting)
                if resetting { ProgressView().controlSize(.small) }
            }
            .padding(.top, 10)
        }
    }

    private var databaseCard: some View {
        Card(title: "Base de dados", symbol: "cylinder.split.1x2") {
            InfoRow("Motor") { Text("\(db.engine.title) \(db.targetVersion)") }
            Divider()
            if db.engine.needsServer {
                InfoRow("Onde") { Text(db.managed ? "Neste Mac (gerida pela app)" : "Servidor existente") }
                Divider()
                InfoRow("Nome") { CopyableText(db.name) }
                Divider()
                InfoRow("Utilizador") { CopyableText(db.user) }
                Divider()
                InfoRow("Palavra-passe") { SecretText(value: db.password) }
                Divider()
                InfoRow("Servidor") { CopyableText("\(db.host):\(String(db.port))") }
            } else {
                InfoRow("Ficheiro") { Text("wp-content/database/.ht.sqlite").foregroundStyle(.secondary) }
            }
        }
    }

    private var exportCard: some View {
        Card(title: "Exportar para cPanel", symbol: "shippingbox",
             footnote: db.engine.needsServer ? "No cPanel: WPvivid → Backup & Restore → Upload → Restore." : nil) {
            if db.engine.needsServer {
                Text("Backup do WPvivid pronto a restaurar no servidor, sem o que só existe no Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: export) { Label("Exportar", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(exporting)
                    if exporting {
                        ProgressView().controlSize(.small)
                        Text("A criar o backup…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showExclusions.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("O que fica de fora")
                        .popover(isPresented: $showExclusions, arrowEdge: .bottom) { exclusions }
                }
                .padding(.top, 10)
                if let exportError { Banner(text: exportError).padding(.top, 10) }
                if let result = exportResult {
                    HStack(alignment: .top) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(result.files.count) ficheiro\(result.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))")
                                .fontWeight(.medium)
                            Text(result.folder.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
                    }
                    .padding(.top, 10)
                }
            } else {
                Text("Este site usa SQLite. O cPanel precisa de MySQL ou MariaDB.").foregroundStyle(.secondary)
            }
        }
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fica de fora da exportação").font(.headline)
            ForEach(["Restos do Studio (base de dados SQLite, plugin SQLite, carregador)",
                     "mu-plugins de desenvolvimento (dev-*) e a entrada automática do WP Center",
                     "Ficheiros para agentes de IA (AGENTS.md, CLAUDE.md…)"], id: \.self) {
                Label($0, systemImage: "minus.circle").font(.callout)
            }
            Text("O wp-config.php do cPanel nunca é substituído.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }

    private var detailsCard: some View {
        Card(title: "Detalhes", symbol: "info.circle") {
            InfoRow("Pasta") {
                HStack(spacing: 6) {
                    Text(site.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Mostrar no Finder")
                }
            }
            Divider()
            InfoRow("WordPress") { Text(site.wpVersion) }
            Divider()
            InfoRow("PHP") { Text(Runtime.phpVersion) }
            Divider()
            InfoRow("Criado") { Text(site.createdAt.formatted(date: .abbreviated, time: .shortened)) }
        }
    }

    // MARK: Ações

    private func export() {
        exporting = true
        exportError = nil
        Task {
            do { exportResult = try await store.exportForCPanel(site) } catch { exportError = error.localizedDescription }
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
                store.errorMessage = "Não foi possível repor o acesso: \(error.localizedDescription)"
            }
            resetting = false
        }
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

private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            VStack(alignment: .leading, spacing: 0) { content }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

private struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value
    init(_ label: String, @ViewBuilder value: () -> Value) { self.label = label; self.value = value() }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
        }
        .padding(.vertical, 7)
    }
}

private struct StatusPill: View {
    let running: Bool
    let busy: Bool
    var body: some View {
        let (text, color): (String, Color) = busy ? ("A iniciar…", .orange) : running ? ("A correr", .green) : ("Parado", .secondary)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(running || busy ? color : .secondary)
    }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

private struct Banner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SecretText: View {
    let value: String
    @State private var revealed = false
    var body: some View {
        HStack(spacing: 6) {
            Text(revealed ? value : String(repeating: "•", count: 12))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(revealed ? "Ocultar" : "Mostrar")
            CopyButton(value: value)
        }
    }
}

private struct CopyableText: View {
    let value: String
    init(_ value: String) { self.value = value }
    var body: some View {
        HStack(spacing: 6) { Text(value).textSelection(.enabled); CopyButton(value: value) }
    }
}

private struct CopyButton: View {
    let value: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copiar")
    }
}

// MARK: - Novo site

struct NewSiteView: View {
    @EnvironmentObject var store: SiteStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Site) -> Void

    @State private var name = "O meu site"
    @State private var directory = SiteStore.defaultDirectory
    @State private var user = SiteStore.defaultAdminUser
    @State private var password = SiteStore.strongPassword(length: 20)
    @State private var db = DatabaseConfig()
    @State private var creating = false
    @State private var installing = false
    @State private var testing = false
    @State private var test: (ok: Bool, text: String)?
    @State private var error: String?
    @State private var showCPanel = false
    @State private var showAdvanced = false

    private var server: LocalServer { LocalServer(db) }
    private var usesLocalServer: Bool { db.engine.needsServer && db.managed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    siteCard
                    accessCard
                    databaseCard
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 720)
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .onChange(of: db) { test = nil }
        .onAppear {
            // Reutiliza o último utilizador por conveniência; nunca a palavra-passe.
            if let last = store.sites.last { user = last.adminUser }
        }
    }

    // MARK: Partes

    private var header: some View {
        HStack(spacing: 14) {
            SiteIcon(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Novo site WordPress").font(.title2.weight(.semibold))
                Text("WordPress \(Runtime.bundledWordPressVersion) · PHP \(Runtime.phpVersion), no seu Mac e sem serviços externos.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var siteCard: some View {
        FormCard(title: "Site", symbol: "globe") {
            FormRow("Nome") {
                TextField("O meu site", text: $name).textFieldStyle(.roundedBorder)
            }
            FormRow("Guardar em") {
                HStack {
                    Text(directory.appendingPathComponent(SiteStore.slug(name)).path)
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Escolher…", action: chooseDirectory)
                }
            }
        }
    }

    private var accessCard: some View {
        FormCard(title: "Acesso ao WordPress", symbol: "person.badge.key",
                 footnote: "Para entrar no painel. O botão WP Admin da app entra sem a escrever.") {
            FormRow("Utilizador") {
                TextField("utilizador", text: $user).textFieldStyle(.roundedBorder)
            }
            FormRow("Palavra-passe") {
                HStack(spacing: 6) {
                    TextField("", text: $password).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button { password = SiteStore.strongPassword(length: 20) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Gerar outra palavra-passe")
                    CopyButton(value: password)
                }
            }
        }
    }

    private var databaseCard: some View {
        FormCard(title: "Base de dados", symbol: "cylinder.split.1x2",
                 footnote: usesLocalServer
                    ? "Base de dados, utilizador e palavra-passe criados ao acaso, no formato do cPanel (prefixo_nome). Escolha a versão do seu servidor para migrar com o WPvivid sem surpresas."
                    : nil) {
            HStack(spacing: 8) {
                ForEach(DatabaseEngine.allCases) { engine in
                    EngineTile(engine: engine, selected: db.engine == engine) {
                        db.engine = engine
                        db.targetVersion = engine.defaultVersion
                    }
                }
            }
            .padding(.bottom, 4)

            Text(db.engine.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if db.engine.needsServer {
                FormRow("Versão") {
                    HStack {
                        Picker("Versão", selection: $db.targetVersion) {
                            ForEach(db.engine.cpanelVersions, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        Button("Versões do cPanel…") { showCPanel = true }.buttonStyle(.link).font(.callout)
                    }
                }
                if db.managed { serverStatus }
                DisclosureGroup("Usar um servidor de base de dados existente", isExpanded: $showAdvanced) {
                    advancedFields.padding(.top, 8)
                }
                .onChange(of: showAdvanced) { _, open in db.managed = !open }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormRow("Servidor") {
                HStack {
                    TextField("127.0.0.1", text: $db.host).textFieldStyle(.roundedBorder)
                    TextField("Porta", value: $db.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            FormRow("Base de dados") {
                TextField("gerada ao acaso se ficar vazia", text: $db.name).textFieldStyle(.roundedBorder)
            }
            FormRow("Utilizador") { TextField("", text: $db.user).textFieldStyle(.roundedBorder) }
            FormRow("Palavra-passe") { SecureField("", text: $db.password).textFieldStyle(.roundedBorder) }
            FormRow("") {
                HStack(spacing: 8) {
                    Button("Testar ligação", action: testConnection).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let test {
                        Label(test.text, systemImage: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(test.ok ? .green : .orange).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var serverStatus: some View {
        FormRow("Neste Mac") {
            if !server.isSupportedOnMac {
                Label("\(server.title) não existe para Mac — escolha outra versão", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.orange)
            } else if server.isInstalled {
                Label("\(server.title) instalado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack {
                    Label("\(server.title) por instalar", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                    Spacer()
                    if installing {
                        ProgressView().controlSize(.small)
                        Text("A instalar…").foregroundStyle(.secondary)
                    } else {
                        Button("Instalar", action: installServer)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).lineLimit(3)
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
        .controlSize(.large)
        .padding(16)
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

private struct FormCard<Content: View>: View {
    let title: String
    let symbol: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// Rótulo à esquerda com largura fixa, campo à direita: colunas alinhadas em todos os cartões.
private struct FormRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field
    init(_ label: String, @ViewBuilder field: () -> Field) { self.label = label; self.field = field() }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            field.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EngineTile: View {
    let engine: DatabaseEngine
    let selected: Bool
    let action: () -> Void

    private var tag: String {
        switch engine {
        case .mariadb: "Recomendado"
        case .mysql: "cPanel"
        case .sqlite: "Só testes"
        case .postgresql: "Indisponível"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: engine.symbol).font(.title2)
                Text(engine.title).font(.callout.weight(.semibold))
                Text(tag).font(.caption2).foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!engine.isAvailable)
        .opacity(engine.isAvailable ? 1 : 0.45)
        .help(engine.isAvailable ? engine.summary : "O WordPress não suporta PostgreSQL nativamente.")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                                .foregroundStyle(column.version == DatabaseEngine.mariadb.defaultVersion && column.engine == .mariadb
                                                 ? Color.green : Color.primary)
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
                            mark((column.engine == .mysql ? row.mysql : row.mariadb).contains(column.version))
                        }
                        mark(row.postgresql != "Não suportado")
                    }
                    .padding(.vertical, 7)
                    if row.id != CPanelSupportRow.all.last?.id {
                        Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            HStack(spacing: 16) {
                Label("Disponível", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Não disponível", systemImage: "minus").foregroundStyle(.tertiary)
                Label("Versão por omissão", systemImage: "circle.fill").foregroundStyle(.green)
            }
            .font(.caption)
        }
        .padding(16)
        .background(CardBackground())
    }

    private func mark(_ available: Bool) -> some View {
        Image(systemName: available ? "checkmark.circle.fill" : "minus")
            .foregroundStyle(available ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
            .frame(minWidth: 52)
            .accessibilityLabel(available ? "Disponível" : "Não disponível")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            note("arrow.left.arrow.right", "Cada servidor usa MySQL ou MariaDB, nunca os dois ao mesmo tempo.")
            note("clock.arrow.circlepath", "MySQL 5.7 e MariaDB 10.0 a 10.3 já não podem ser escolhidos em instalações novas.")
            note("exclamationmark.triangle", "O WordPress precisa de MySQL ou MariaDB; não funciona com PostgreSQL.")
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
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
    let badge: String?
    let badgeColor: Color
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(engine.title, systemImage: engine.symbol).font(.headline)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.15)))
                        .foregroundStyle(badgeColor)
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
                            .foregroundStyle(isDefault ? Color.green : Color.primary)
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

struct SettingsView: View {
    @State private var directory = SiteStore.defaultDirectory
    @State private var cliInstalled = CLI.isInstalled
    @State private var cliError: String?

    var body: some View {
        Form {
            LabeledContent("Pasta dos sites") {
                HStack {
                    Text(directory.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                    Button("Escolher…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            directory = url
                            SiteStore.defaultDirectory = url
                        }
                    }
                }
            }
            Section {
                Toggle("Comando wpc no terminal", isOn: Binding(
                    get: { cliInstalled },
                    set: { on in
                        do { try on ? CLI.install() : CLI.uninstall(); cliError = nil } catch { cliError = error.localizedDescription }
                        cliInstalled = CLI.isInstalled
                    }))
            } footer: {
                Text(cliError ?? "Permite usar `wpc wp …`, `wpc start`, `wpc status` e os agentes de IA no terminal. Abra um novo terminal depois de ativar.")
                    .foregroundStyle(cliError == nil ? Color.secondary : Color.red)
            }
            LabeledContent("WordPress incluído", value: Runtime.bundledWordPressVersion)
            LabeledContent("PHP incluído", value: Runtime.phpVersion)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
    }
}
