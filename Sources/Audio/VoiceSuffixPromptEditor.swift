import EliaTopBarKit
import SwiftUI

/// The editor for the suffix prompt — the Markdown file that is appended to
/// every vocal command.
///
/// It is where the user tells the agent how to answer out loud: the
/// text-to-speech tool, the overlay, the wording, anything else that must be
/// true for every spoken command.
struct VoiceSuffixPromptEditor: View {

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = VoiceSuffixPrompt.load()
    @State private var didLoad = false

    private let editorFont = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prompt suffix for every voice command")
                .font(.system(size: 13, weight: .semibold))

            Text("Put here how the agent should answer out loud: the text-to-speech tools it has, "
                 + "the overlay it should use, the wording you want, and anything else that must be true "
                 + "for every spoken command. It is appended to the prompt of every voice command, so the "
                 + "agent always knows the request came from your voice.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("For example: use the `speak` skill to say the answer, or show it in a macOS overlay with "
                 + "`mcp-cli call electron-mcp macos_popup '{\"title\": \"Elia\", \"message\": \"…\"}'`.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Template").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .font(editorFont)
                        .frame(minHeight: 190)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(VoiceSuffixPrompt.render(text))
                            .font(editorFont)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 190)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Variables").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(VoiceSuffixPrompt.variables) { variable in
                        Button {
                            text += " " + variable.token
                        } label: {
                            Text(variable.token)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(variable.explanation)
                    }
                }
            }

            HStack {
                Text(VoiceSuffixPrompt.fileURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Restore the default") {
                    text = VoiceSuffixPrompt.defaultText
                }
                .controlSize(.small)
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
                Button("Save") {
                    VoiceSuffixPrompt.save(text)
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 720, height: 480)
        .onAppear {
            if !didLoad {
                text = VoiceSuffixPrompt.load()
                didLoad = true
            }
        }
    }
}
