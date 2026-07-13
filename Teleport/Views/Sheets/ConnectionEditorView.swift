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
                Button { dismiss() } label: {
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
                        fieldRow("") {
                            Text("Key path takes precedence over password for SFTP auth.")
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

                Button("Cancel", role: .cancel) { dismiss() }
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
            // under App Sandbox without re-prompting.
            do {
                try BookmarkStore.shared.save(url, name: BookmarkStore.sshKeyName(for: connection.id))
            } catch {
                appState.showError(title: "Bookmark failed", message: error.localizedDescription)
            }
        }
    }
}
