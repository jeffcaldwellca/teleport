import SwiftUI

struct PassphraseSheet: View {
    let request: PassphrasePrompt.Request

    @State private var passphrase = ""
    @State private var remember = true

    private var keyName: String { (request.keyPath as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enter the passphrase for \u{201C}\(keyName)\u{201D}")
                        .font(.headline)
                    Text(request.keyPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if request.isRetry {
                Label("That passphrase didn\u{2019}t unlock the key. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)

            Toggle("Remember in Keychain", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { PassphrasePrompt.shared.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        // Turned down in place (wrong passphrase): clear the field for another go.
        .onChange(of: request.isRetry) { _, isRetry in
            if isRetry { passphrase = "" }
        }
    }

    private func unlock() {
        guard !passphrase.isEmpty else { return }
        PassphrasePrompt.shared.submit(passphrase, remember: remember)
    }
}
