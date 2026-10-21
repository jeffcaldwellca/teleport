import SwiftUI
import TeleportKit

/// A server's keyboard-interactive prompts — a verification code, a custom
/// PAM question — asked mid-login. The configured password has already
/// answered a lone password prompt by the time this appears.
struct InteractivePromptSheet: View {
    let request: InteractivePrompt.Request

    @State private var answers: [String]

    init(request: InteractivePrompt.Request) {
        self.request = request
        _answers = State(initialValue: Array(repeating: "", count: request.challenge.prompts.count))
    }

    private var title: String {
        request.challenge.name.isEmpty ? "\u{201C}\(request.connectionName)\u{201D} asks for more to log in" : request.challenge.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(request.challenge.instruction.isEmpty
                         ? "The server \u{201C}\(request.connectionName)\u{201D} needs another step to log you in."
                         : request.challenge.instruction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(request.challenge.prompts.enumerated()), id: \.offset) { index, prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.text.trimmingCharacters(in: .whitespaces))
                            .font(.callout)
                        if prompt.echo {
                            TextField("", text: $answers[index])
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(submit)
                        } else {
                            SecureField("", text: $answers[index])
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(submit)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { InteractivePrompt.shared.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func submit() {
        InteractivePrompt.shared.submit(answers)
    }
}
