import Foundation

/// The extra instructions appended to every vocal command.
///
/// It is a plain Markdown file the user owns and edits from the settings
/// window, because it is the one part of the voice feature that is about
/// *how* the agent should answer rather than *what* was said. The default
/// text tells the agent it was asked out loud and points it at the tools
/// that can answer out loud.
public enum VoiceSuffixPrompt {

    // MARK: - File

    /// Where the file lives.
    public static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("EliaTopBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voice-suffix.md")
    }

    /// The template on disk, or the default when the file is missing.
    public static func load() -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultText
        }
        return text
    }

    /// Write the template back.
    public static func save(_ text: String) {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Put the default back.
    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// True when the file exists and differs from the default.
    public static var isCustomised: Bool {
        load().trimmingCharacters(in: .whitespacesAndNewlines)
            != defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Variables

    /// A placeholder the user can put in the file.
    public struct Variable: Identifiable {
        public let name: String
        public let explanation: String
        public var id: String { name }
        /// The token as it appears in the file.
        public var token: String { "{{\(name)}}" }
    }

    /// Everything the template can interpolate.
    public static let variables: [Variable] = [
        Variable(name: "agent", explanation: "The agent the command was sent to"),
        Variable(name: "command", explanation: "The instruction, without the wake phrase"),
        Variable(name: "transcript", explanation: "The whole thing that was said"),
        Variable(name: "date", explanation: "Today, as YYYY-MM-DD"),
        Variable(name: "time", explanation: "The time, as HH:MM"),
    ]

    // MARK: - Rendering

    /// Replace the variables in a template.
    public static func render(_ template: String,
                       agent: String = "elia",
                       command: String = "deploy the api",
                       transcript: String = "Ok Elia, deploy the api") -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: now)

        var out = template
        for variable in variables {
            let value: String
            switch variable.name {
            case "agent": value = agent
            case "command": value = command
            case "transcript": value = transcript
            case "date": value = date
            case "time": value = time
            default: value = ""
            }
            out = out.replacingOccurrences(of: variable.token, with: value)
        }
        return out
    }

    /// The suffix appended to a prompt.
    public static func suffix(agent: String, command: String, transcript: String) -> String {
        let template = load()
        let rendered = render(template, agent: agent, command: command, transcript: transcript)
        return "\n\n---\n\n\(rendered)"
    }

    // MARK: - Default text

    /// What the user starts from.
    public static let defaultText = """
    ## Voice command

    Wael asked for this out loud. The text above is a voice transcript: it may carry
    small transcription errors, no punctuation, and no emphasis. Read the intent, not
    the spelling.

    **Answer out loud.** Do not only write a reply in the terminal — the person who
    asked cannot see it. Use the `speak` skill to say the answer, or put it in a macOS
    overlay popup:

        mcp-cli call macos-popup show_popup '{"title": "Elia", "message": "the answer", "level": "info", "duration": 10}'

    For a longer answer, use `show_docs` instead of `show_popup`. Full MCP usage and
    server paths are in:

        /Users/vakandi/Documents/subworker-opencode-rust/subworkers/context/TOOLS.md

    Keep the spoken answer short, and put the detail underneath it.

    ---

    *This file is appended to every voice command. Put here the text-to-speech tools,
    the wording you want, the overlay you want, and any standing preference for
    spoken answers. Edit it in Topbar Settings › Audio & Voice.*
    """
}
