import SwiftUI

struct HostKeyConfirmationSheet: View {
    let request: HostKeyConfirmationRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "key.shield")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("First-time host key")
                        .font(.headline)
                    Text("Verify before connecting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("\(request.host):\(request.port)", systemImage: "server.rack")
                    .font(.callout.monospaced())
                Text("This server has not been seen before. The fingerprint shown below identifies the SSH host. If it matches the value the server administrator gave you, accept it. If not, **reject** — it could indicate a man-in-the-middle attack.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Fingerprint")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(SSHKeyFingerprint.display(request.fingerprint))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Reject", role: .destructive) {
                    HostKeyConfirmation.shared.reject()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Trust & Save") {
                    HostKeyConfirmation.shared.accept()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
