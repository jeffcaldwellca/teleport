import SwiftUI

struct PermissionsEditorSheet: View {
    let item: FileItem
    let session: RemoteSession

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // 9 permission bits: [owner-r, owner-w, owner-x, group-r, group-w, group-x, other-r, other-w, other-x]
    @State private var bits   = Array(repeating: false, count: 9)
    @State private var suid   = false
    @State private var sgid   = false
    @State private var sticky = false
    @State private var owner  = ""
    @State private var group  = ""

    @State private var isApplying  = false
    @State private var errorMessage: String? = nil

    private var isSFTP: Bool {
        session.connection.connectionProtocol == .sftp
    }

    // MARK: - Computed

    private var octalValue: Int {
        var v = 0
        if suid   { v |= 0o4000 }
        if sgid   { v |= 0o2000 }
        if sticky { v |= 0o1000 }
        for (i, b) in bits.enumerated() where b {
            v |= (0o400 >> i)
        }
        return v
    }

    private var symbolicString: String {
        String((0..<9).map { i -> Character in
            let on = bits[i]
            switch i % 3 {
            case 0: return on ? "r" : "-"
            case 1: return on ? "w" : "-"
            case 2:
                if i == 2 { return suid ? (on ? "s" : "S") : (on ? "x" : "-") }
                if i == 5 { return sgid  ? (on ? "s" : "S") : (on ? "x" : "-") }
                return sticky ? (on ? "t" : "T") : (on ? "x" : "-")
            default: return "-"
            }
        })
    }

    private var ownershipChanged: Bool {
        let o = owner.trimmingCharacters(in: .whitespaces)
        let g = group.trimmingCharacters(in: .whitespaces)
        return !o.isEmpty || !g.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            permissionsSection
            ownershipSection
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            buttonRow
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { loadCurrentValues() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : item.systemImage)
                .font(.title)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private static let labelWidth: CGFloat = 60

    private var permissionsSection: some View {
        GroupBox {
            VStack(spacing: 10) {
                // Column headers
                HStack {
                    Text("").frame(width: Self.labelWidth)
                    ForEach(["Read", "Write", "Exec"], id: \.self) { label in
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                // r/w/x rows
                ForEach(0..<3, id: \.self) { row in
                    HStack {
                        Text(["Owner", "Group", "Other"][row])
                            .font(.callout)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        ForEach(0..<3, id: \.self) { col in
                            Toggle("", isOn: $bits[row * 3 + col])
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Divider()

                // Special bits
                HStack {
                    Text("Special")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    Toggle("setuid", isOn: $suid).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("setgid", isOn: $sgid).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("sticky", isOn: $sticky).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Octal + symbolic readout
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Octal").font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%04o", octalValue))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Symbolic").font(.caption2).foregroundStyle(.secondary)
                        Text(symbolicString)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(.top, 2)
            }
            .padding(8)
        } label: {
            Label("Permissions", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
        }
    }

    private var ownershipSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if isSFTP {
                    Label("SFTP requires numeric User ID and Group ID", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Owner")
                        .font(.callout)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField(isSFTP ? "UID (e.g. 1000)" : "Username", text: $owner)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Group")
                        .font(.callout)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    TextField(isSFTP ? "GID (e.g. 1000)" : "Group name", text: $group)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(8)
        } label: {
            Label("Ownership", systemImage: "person.2")
                .font(.callout.weight(.medium))
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            if isApplying {
                ProgressView().controlSize(.small).padding(.trailing, 4)
            }

            Button("Apply Changes") { Task { await applyChanges() } }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Logic

    private func loadCurrentValues() {
        owner = item.owner ?? ""
        group = item.group ?? ""

        let octal: Int
        if let p = item.permissions {
            octal = Self.parsePermissions(p)
        } else {
            octal = 0o644
        }

        suid   = (octal & 0o4000) != 0
        sgid   = (octal & 0o2000) != 0
        sticky = (octal & 0o1000) != 0
        for i in 0..<9 {
            bits[i] = (octal & (0o400 >> i)) != 0
        }
    }

    private func applyChanges() async {
        isApplying = true
        errorMessage = nil
        do {
            try await session.client.setPermissions(octalValue, at: item.path)
            let o = owner.trimmingCharacters(in: .whitespaces)
            let g = group.trimmingCharacters(in: .whitespaces)
            if !o.isEmpty || !g.isEmpty {
                try await session.client.setOwnership(owner: o, group: g, at: item.path)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }

    // MARK: - Parsing

    /// Parse a permission string (symbolic or numeric-octal) to an Int of permission bits.
    static func parsePermissions(_ s: String) -> Int {
        // Numeric: "644", "0644", "100644", "40755" — parse as octal and mask to permission bits
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy(\.isNumber), let num = Int(trimmed, radix: 8) {
            return num & 0o7777
        }
        // Symbolic: "rwxr-xr-x" or "drwxr-xr-x" — take the last 9 characters
        let chars = Array(trimmed.suffix(9))
        guard chars.count == 9 else { return 0o644 }
        let weights = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        return zip(chars, weights).reduce(0) { acc, pair in
            acc | (pair.0 == "-" ? 0 : pair.1)
        }
    }
}
