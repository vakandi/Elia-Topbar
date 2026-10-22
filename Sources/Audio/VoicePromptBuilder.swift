import EliaTopBarKit
import Foundation

/// Builds the prompt that is sent to the bridge when a voice command fires.
///
/// The bridge replaces `PROMPT.md` with whatever `prompt` we send
/// (`control/engine.ts` → `workspacePrompt`), so sending the bare transcript
/// would delete the agent's mission. The override therefore carries the
/// original prompt plus a clearly marked voice block.
enum VoicePromptBuilder {

    /// The agent's `PROMPT.md`, when it can be found.
    static func loadPrompt(agent: String, repoPath: String) -> String? {
        let path = (repoPath as NSString)
            .appendingPathComponent("subworkers")
        let file = (path as NSString).appendingPathComponent(agent)
        let promptPath = (file as NSString).appendingPathComponent("PROMPT.md")
        guard let text = try? String(contentsOfFile: promptPath, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// The full override prompt: the agent's prompt, then the voice block,
    /// then the user's suffix.
    static func compose(agent: String, transcript: String, command: String, repoPath: String) -> String {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = command.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = loadPrompt(agent: agent, repoPath: repoPath) ?? ""
        if !out.isEmpty {
            out += "\n\n"
        }
        out += voiceBlock(transcript: spoken, command: instruction)
        out += VoiceSuffixPrompt.suffix(agent: agent, command: instruction, transcript: spoken)
        return out
    }

    /// The block appended to the agent prompt.
    static func voiceBlock(transcript: String, command: String) -> String {
        let instruction = command.isEmpty
            ? "The wake phrase was spoken with no instruction after it. Ask Wael what to do."
            : "The instruction is:\n\n> \(command)"
        return """
        ## Voice command — this run

        Wael spoke the following out loud (Whisper transcript, so expect small
        transcription errors and no punctuation):

        > \(transcript)

        \(instruction)

        That is the request for this run. It replaces the standing mission for
        this run only — do not restart the schedule, do not redo old tasks, and
        do not report on anything the sentence does not ask for. Execute it,
        then answer briefly with the result.
        """
    }
}
