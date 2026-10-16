import AppKit
import SwiftUI

// MARK: - Janela principal

struct ContentView: View {
    @EnvironmentObject var store: SiteStore
    @State private var selection: Site.ID?
    @State private var showNewSite = false
    @State private var showCPanel = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Sites") {
                    ForEach(store.sites) { site in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(store.isRunning(site) ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(site.name).lineLimit(1)
                                Text(site.database.engine.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(site.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
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
                SiteDetailView(site: site, selection: $selection).id(site.id)
            } else {
                ContentUnavailableView {
                    Label(store.sites.isEmpty ? "Ainda não há sites" : "Selecione um site", systemImage: "globe")
                } description: {
                    Text("Sites WordPress locais, a correr no seu Mac, sem contas nem serviços externos.")
                } actions: {
                    Button("Novo site") { showNewSite = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showNewSite = true } label: { Label("Novo site", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .help("Criar um novo site WordPress")
            }
        }
        .sheet(isPresented: $showNewSite) {
            NewSiteView { selection = $0.id }
        }
        .sheet(isPresented: $showCPanel) { CPanelView() }
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

// MARK: - Detalhe do site

struct SiteDetailView: View {
    @EnvironmentObject var store: SiteStore
    let site: Site
    @Binding var selection: Site.ID?
    @State private var confirmDelete = false
    @State private var revealPassword = false
    @State private var starting = false
    @State private var exporting = false
    @State private var exportError: String?
    @State private var exportResult: SiteStore.ExportResult?

    private var running: Bool { store.isRunning(site) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "globe")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.tint))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.name).font(.title2.weight(.semibold))
                        Label(running ? "A correr em \(site.url.absoluteString)" : "Parado",
                              systemImage: running ? "circle.fill" : "circle")
                            .font(.callout)
                            .foregroundStyle(running ? .green : .secondary)
                            .labelStyle(StatusLabelStyle())
                    }
                    Spacer()
                    if running {
                        Button("Parar") { store.stop(site) }.controlSize(.large)
                    } else {
                        Button {
                            starting = true
                            Task { await store.start(site); starting = false }
                        } label: {
                            if starting { ProgressView().controlSize(.small).padding(.horizontal, 12) } else { Text("Iniciar") }
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(starting)
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Button { NSWorkspace.shared.open(site.url) } label: { Label("Abrir site", systemImage: "safari") }
                    Button { NSWorkspace.shared.open(site.url.appendingPathComponent("wp-admin/")) } label: {
                        Label("WP Admin", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([site.folder]) } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    Button { openTerminal() } label: { Label("Terminal", systemImage: "terminal") }
                }
                .buttonStyle(.bordered)
            }

            Section("Site") {
                LabeledContent("Endereço") {
                    Text(site.url.absoluteString).textSelection(.enabled)
                }
                LabeledContent("Pasta") {
                    Text(site.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("WordPress", value: site.wpVersion)
                LabeledContent("PHP", value: Runtime.phpVersion)
            }

            Section("Base de dados") {
                LabeledContent("Motor") {
                    Label(site.database.engine.title + (site.database.targetVersion.isEmpty ? "" : " \(site.database.targetVersion)"),
                          systemImage: site.database.engine.symbol)
                }
                if site.database.engine.needsServer {
                    LabeledContent("Onde", value: site.database.managed ? "Neste Mac (gerida pelo WP Center)" : "Servidor existente")
                    LabeledContent("Base de dados") { CopyableText(site.database.name) }
                    LabeledContent("Utilizador") { CopyableText(site.database.user) }
                    LabeledContent("Servidor", value: "\(site.database.host):\(String(site.database.port))")
                } else {
                    LabeledContent("Ficheiro", value: "wp-content/database/.ht.sqlite")
                }
            }

            Section("Acesso") {
                LabeledContent("Utilizador") { CopyableText(site.adminUser) }
                LabeledContent("Palavra-passe") {
                    HStack(spacing: 6) {
                        Text(revealPassword ? site.adminPassword : String(repeating: "•", count: 12))
                            .font(.body.monospaced())
                        Button { revealPassword.toggle() } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealPassword ? "Ocultar" : "Mostrar")
                        CopyButton(value: site.adminPassword)
                    }
                }
            }

            Section {
                if site.database.engine.needsServer {
                    HStack {
                        Button {
                            exporting = true
                            exportError = nil
                            Task {
                                do { exportResult = try await store.exportForCPanel(site) } catch { exportError = error.localizedDescription }
                                exporting = false
                            }
                        } label: {
                            Label("Exportar para cPanel", systemImage: "shippingbox")
                        }
                        .disabled(exporting)
                        if exporting {
                            ProgressView().controlSize(.small)
                            Text("A criar o backup com o WPvivid…").foregroundStyle(.secondary)
                        }
                    }
                    if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if let result = exportResult {
                        LabeledContent {
                            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
                        } label: {
                            Label("\(result.files.count) ficheiro\(result.files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))",
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result.folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else {
                    Label("Este site usa SQLite. O cPanel precisa de MySQL ou MariaDB.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Exportar para cPanel")
            } footer: {
                Text("Cria um backup do WPvivid, que tem de estar ativo neste site. No cPanel: WPvivid → Backup & Restore → Upload → Restore. Fica de fora o que só existe no Mac: restos do Studio, mu-plugins dev-* e ficheiros para agentes de IA. O wp-config.php do cPanel nunca é substituído.")
            }

            Section {
                Button("Apagar site…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("A pasta é movida para o Lixo. Bases de dados MySQL/MariaDB não são apagadas.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(site.name)
        .confirmationDialog("Apagar \"\(site.name)\"?", isPresented: $confirmDelete) {
            Button("Mover para o Lixo", role: .destructive) {
                Task {
                    await store.delete(site)
                    selection = store.sites.first?.id
                }
            }
        } message: {
            Text("A pasta \(site.path) será movida para o Lixo.")
        }
    }

    private func openTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([site.folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 7)); configuration.title }
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
    @State private var user = "admin"
    @State private var password = SiteStore.randomPassword(length: 16)
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
            Form {
                Section {
                    TextField("Nome do site", text: $name)
                    LabeledContent("Guardar em") {
                        HStack {
                            Text(directory.appendingPathComponent(SiteStore.slug(name)).path)
                                .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button("Escolher…", action: chooseDirectory)
                        }
                    }
                } header: {
                    Text("Novo site WordPress")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.bottom, 4)
                }

                Section {
                    TextField("Utilizador", text: $user)
                    LabeledContent("Palavra-passe") {
                        HStack {
                            TextField("", text: $password).labelsHidden().font(.body.monospaced())
                            Button { password = SiteStore.randomPassword(length: 16) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Gerar outra palavra-passe")
                        }
                    }
                } header: {
                    Text("Acesso")
                } footer: {
                    if let warning = userWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text(db.engine.needsServer && db.managed
                             ? "Serve para entrar no WordPress e é também o acesso à base de dados."
                             : "Serve para entrar no WordPress.")
                    }
                }

                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(DatabaseEngine.allCases) { engine in
                            EngineCard(engine: engine, selected: db.engine == engine) {
                                db.engine = engine
                                db.targetVersion = engine.defaultVersion
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if db.engine.needsServer {
                        Picker("Versão", selection: $db.targetVersion) {
                            ForEach(db.engine.cpanelVersions, id: \.self) { version in
                                let local = LocalServer(DatabaseConfig(engine: db.engine, targetVersion: version))
                                Text(local.title + (local.isSupportedOnMac || !db.managed ? "" : " — indisponível no Mac")).tag(version)
                            }
                        }
                        if db.managed { serverStatus }
                    }
                } header: {
                    HStack {
                        Text("Base de dados")
                        Spacer()
                        Button("Versões do cPanel…") { showCPanel = true }
                            .buttonStyle(.link).font(.callout)
                    }
                } footer: {
                    if usesLocalServer {
                        Text("A base de dados \"\(SiteStore.databaseName(for: name))\" é criada automaticamente no seu Mac. Escolha a mesma versão do seu servidor cPanel para migrar sem surpresas com o WPvivid.")
                    }
                }

                if db.engine.needsServer {
                    Section {
                        DisclosureGroup("Opções avançadas", isExpanded: $showAdvanced) {
                            Toggle("Usar um servidor de base de dados existente", isOn: Binding(
                                get: { !db.managed }, set: { db.managed = !$0 }))
                            if !db.managed {
                                TextField("Servidor", text: $db.host, prompt: Text("127.0.0.1"))
                                TextField("Porta", value: $db.port, format: .number.grouping(.never))
                                TextField("Base de dados", text: $db.name, prompt: Text(SiteStore.databaseName(for: name)))
                                TextField("Utilizador da base de dados", text: $db.user)
                                SecureField("Palavra-passe da base de dados", text: $db.password)
                                HStack {
                                    Button("Testar ligação", action: testConnection).disabled(testing)
                                    if testing { ProgressView().controlSize(.small) }
                                    if let test {
                                        Label(test.text, systemImage: test.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(test.ok ? .green : .orange).font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: db) { test = nil }

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).lineLimit(3)
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(action: create) {
                    if creating { ProgressView().controlSize(.small).padding(.horizontal, 18) } else { Text("Criar site") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(width: 580, height: 560)
        .sheet(isPresented: $showCPanel) { CPanelView() }
        .onAppear {
            // Reutiliza o último acesso: no mesmo servidor local, o mesmo utilizador tem de ter a mesma palavra-passe.
            if let last = store.sites.last { user = last.adminUser; password = last.adminPassword }
        }
    }

    @ViewBuilder private var serverStatus: some View {
        if !server.isSupportedOnMac {
            Label("\(server.title) não está disponível para Mac. Escolha outra versão.", systemImage: "xmark.octagon")
                .foregroundStyle(.secondary)
        } else if server.isInstalled {
            Label("\(server.title) instalado neste Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            HStack {
                Label("\(server.title) ainda não está instalado", systemImage: "arrow.down.circle")
                Spacer()
                if installing { ProgressView().controlSize(.small); Text("A instalar…").foregroundStyle(.secondary) }
                else { Button("Instalar", action: installServer) }
            }
        }
    }

    private var userWarning: String? {
        guard usesLocalServer, !user.isEmpty else { return nil }
        return DatabaseConfig.isValidIdentifier(user) && user.count <= 32
            ? nil : "Use só letras, números e _ no utilizador (máx. 32)."
    }

    private var canCreate: Bool {
        guard !creating, !installing, db.engine.isAvailable, !SiteStore.slug(name).isEmpty,
              !user.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty, userWarning == nil else { return false }
        return !usesLocalServer || server.isInstalled
    }

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
            if probe.name.isEmpty { probe.name = SiteStore.databaseName(for: name) }
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

private struct EngineCard: View {
    let engine: DatabaseEngine
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: engine.symbol).font(.title3)
                    Text(engine.title).font(.headline)
                    Spacer()
                    if !engine.isAvailable {
                        Text("Indisponível").font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    } else if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                Text(engine.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!engine.isAvailable)
        .opacity(engine.isAvailable ? 1 : 0.55)
        .help(engine.isAvailable ? "" : "O WordPress não suporta PostgreSQL nativamente.")
    }
}

// MARK: - Bases de dados do cPanel

struct CPanelView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bases de dados suportadas pelo cPanel & WHM").font(.title3.weight(.semibold))
                Text("Versões que se podem escolher numa instalação nova (cPanel & WHM 136 ou superior).")
                    .foregroundStyle(.secondary)
            }

            Table(CPanelSupportRow.all) {
                TableColumn("Sistema operativo", value: \.os)
                TableColumn("MySQL") { Text($0.mysql.joined(separator: ", ")) }
                TableColumn("MariaDB") { Text($0.mariadb.joined(separator: ", ")) }
                TableColumn("PostgreSQL", value: \.postgresql)
            }
            .frame(height: 250)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(CPanelSupportRow.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout)
                }
            }

            HStack {
                Text("Fonte: documentação oficial cPanel (docs.cpanel.net), revista em julho de 2026.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
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
