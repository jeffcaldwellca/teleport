import SwiftUI
import TeleportKit

/// Pick hosts from `~/.ssh/config` to add as SFTP connections.
struct SSHConfigImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var hosts: [SSHConfig.Host] = []
    @State private var selected: Set<String> = []

    private var store: ConnectionStore { appState.connectionStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from SSH Config").font(.headline)
            Text("Hosts named in ~/.ssh/config. Each becomes an SFTP connection using its HostName, User, Port and IdentityFile; hosts without an IdentityFile use ssh-agent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hosts.isEmpty {
                Text("No hosts found in ~/.ssh/config.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(hosts, id: \.alias) { host in
                    let saved = store.isSaved(host)
                    Toggle(isOn: Binding(
                        get: { selected.contains(host.alias) },
                        set: { if $0 { selected.insert(host.alias) } else { selected.remove(host.alias) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(host.alias)
                            Text(saved ? "Already added" : subtitle(for: host))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(saved)
                }
                .frame(minHeight: 180, maxHeight: 320)
            }

            HStack {
                if !hosts.isEmpty {
                    Button("Select All") { selected = Set(importable.map(\.alias)) }
                        .disabled(importable.isEmpty)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Import" : "Import \(selected.count)") {
                    store.importHosts(hosts.filter { selected.contains($0.alias) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            hosts = SSHConfig.load().hosts
            selected = Set(importable.map(\.alias))
        }
    }

    private var importable: [SSHConfig.Host] { hosts.filter { !store.isSaved($0) } }

    private func subtitle(for host: SSHConfig.Host) -> String {
        var text = "\(host.user ?? NSUserName())@\(host.hostName)"
        if let port = host.port, port != 22 { text += ":\(port)" }
        if let key = host.identityFile { text += " · \((key as NSString).lastPathComponent)" }
        return text
    }
}
