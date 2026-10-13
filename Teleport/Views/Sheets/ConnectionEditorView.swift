import SwiftUI
import TeleportKit

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private let isEditing: Bool
    @State private var connection: Connection
    @State private var password: String  = ""
    @State private var isTesting         = false
    @State private var testResult:         String? = nil
    @State private var testSuccess         = false
    @State private var hasSavedPassphrase  = false

    init(existing: Connection?) {
        if let existing {
            isEditing   = true
            _connection = State(initialValue: existing)
        } else {
            isEditing   = false
            _connection = State(initialValue: Connection())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────
            HStack {
                Text(isEditing ? "Edit Connection" : "New Connection")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { discard() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // ── Form ───────────────────────────────────
            Form {
                Section("General") {
                    fieldRow("Name") {
                        TextField("Optional", text: $connection.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow("Protocol") {
                        Picker("", selection: $connection.connectionProtocol) {
                            ForEach(Connection.ConnectionProtocol.allCases) { proto in
                                Label(proto.rawValue, systemImage: proto.systemImage).tag(proto)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: connection.connectionProtocol) { _, p in
                            if connection.port == connection.connectionProtocol.defaultPort ||
                               Connection.ConnectionProtocol.allCases.map(\.defaultPort).contains(connection.port) {
                                connection.port = p.defaultPort
                            }
                        }
                    }
                }

                Section("Server") {
                    fieldRow("Host") {
                        TextField("", text: $connection.host)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow("Port") {
                        HStack(spacing: 8) {
                            TextField("", value: $connection.port, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Stepper("", value: $connection.port, in: 1...65535)
                                .labelsHidden()
                            Spacer()
                        }
                    }
                    fieldRow("Initial Path") {
                        TextField("/", text: $connection.initialPath)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Credentials") {
                    fieldRow("Username") {
                        TextField("", text: $connection.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    fieldRow("Password") {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }

                    if connection.connectionProtocol == .sftp {
                        fieldRow("SSH Key") {
                            HStack(spacing: 8) {
                                TextField("Optional", text: $connection.sshKeyPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse…") { browseForKey() }
                            }
                        }
                        if hasSavedPassphrase {
                            fieldRow("") {
                                HStack(spacing: 8) {
                                    Label("Passphrase saved", systemImage: "key.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Forget") {
                                        PassphrasePrompt.shared.forget(connection.id)
                                        hasSavedPassphrase = false
                                    }
                                    .controlSize(.small)
                                    .help("Remove this key\u{2019}s passphrase from the Keychain. You\u{2019}ll be asked for it the next time you connect.")
                                    Spacer()
                                }
                            }
                        }
                        fieldRow("") {
                            Toggle("Use ssh-agent", isOn: $connection.useSSHAgent)
                                .toggleStyle(.checkbox)
                                .help("Try the keys held by ssh-agent first (including ones unlocked with ssh-add), before the key file or password.")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        fieldRow("") {
                            Text("A key file takes precedence over the password. Encrypted keys ask for their passphrase when connecting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $connection.notes)
                        .frame(minHeight: 60)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.25)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }

                if let result = testResult {
                    Section {
                        Label {
                            Text(result)
                                .font(.callout)
                                .foregroundStyle(testSuccess ? .green : .red)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testSuccess ? .green : .red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // ── Actions ────────────────────────────────
            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().controlSize(.small) }
                        Text(isTesting ? "Testing…" : "Test Connection")
                    }
                    .frame(minWidth: 130)
                }
                .disabled(connection.host.isEmpty || isTesting)

                Spacer()

                Button("Cancel", role: .cancel) { discard() }
                    .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Save" : "Add") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(connection.host.isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            if isEditing {
                password = appState.connectionStore.password(for: connection)
            }
            hasSavedPassphrase = PassphrasePrompt.shared.hasRememberedPassphrase(for: connection.id)
        }
        // Testing the connection may have just saved one.
        .onChange(of: isTesting) { _, _ in
            hasSavedPassphrase = PassphrasePrompt.shared.hasRememberedPassphrase(for: connection.id)
        }
        // Test Connection can hit a first-time SSH host key. The confirmation
        // sheet in ContentView can't present while this editor sheet is up, so
        // the prompt must be presentable from here or the test would hang
        // forever awaiting an answer.
        .sheet(item: Binding(
            get: { HostKeyConfirmation.shared.pending },
            set: { if $0 == nil { HostKeyConfirmation.shared.reject() } }
        )) { request in
            HostKeyConfirmationSheet(request: request)
        }
        // Likewise for the passphrase of an encrypted key.
        .sheet(item: Binding(
            get: { PassphrasePrompt.shared.pending },
            // Dismissed without an answer: the connection gives up on the key.
            set: { if $0 == nil { PassphrasePrompt.shared.cancel() } }
        )) { request in
            PassphraseSheet(request: request)
        }
    }

    // MARK: - Layout

    private static let labelWidth: CGFloat = 84

    /// A form row with a right-aligned label sitting next to a full-width,
    /// left-aligned control — the native macOS dialog convention. The label
    /// stays adjacent to its field (rather than floating off to the left), and
    /// the field's editable area is always visible.
    @ViewBuilder
    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            content()
        }
    }

    // MARK: - Actions

    /// Close without saving. Testing a brand-new connection may have
    /// remembered its key passphrase; with the connection discarded there is
    /// nothing for that to belong to.
    private func discard() {
        if !isEditing { PassphrasePrompt.shared.forget(connection.id) }
        dismiss()
    }

    private func save() {
        do {
            if isEditing {
                try appState.connectionStore.update(
                    connection,
                    password: password.isEmpty ? nil : password
                )
            } else {
                try appState.connectionStore.add(connection, password: password)
            }
            dismiss()
        } catch {
            appState.showError(error)
        }
    }

    private func testConnection() async {
        isTesting  = true
        testResult = nil

        let client = RemoteClientFactory.make(for: connection, password: password)
        do {
            try await client.connect()
            await client.disconnect()
            testResult  = "Connected successfully"
            testSuccess = true
        } catch {
            testResult  = error.localizedDescription
            testSuccess = false
        }
        isTesting = false
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.directoryURL = URL(fileURLWithPath: NSString("~/.ssh").expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            connection.sshKeyPath = url.path
            // Capture a security-scoped bookmark so we can read this file later
            // even if the file is moved.
            do {
                try BookmarkStore.shared.save(url, name: BookmarkStore.sshKeyName(for: connection.id))
            } catch {
                appState.showError(title: "Bookmark failed", message: error.localizedDescription)
            }
        }
    }
}
