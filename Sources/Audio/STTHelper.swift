import Foundation

/// The Python helper that does the Whisper work.
///
/// Two modes:
///  - one-shot (default): transcribe one file, print one JSON line, exit.
///  - daemon (`--daemon`): keep the process alive, read JSON requests on
///    stdin, answer on stdout. The model is loaded once and reused.
enum STTHelper {

    /// Marker so the Swift side can find the JSON line even if the
    /// interpreter prints progress output around it.
    static let jsonPrefix = "__ELIA_JSON__"

    /// Where the helper is written.
    static var scriptURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("EliaTopBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stt_helper.py")
    }

    /// Write the helper if it is missing or stale. Returns its path.
    @discardableResult
    static func install() throws -> URL {
        let url = scriptURL
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == source {
            return url
        }
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The helper source.
    static let source = #"""
    #!/usr/bin/env python3
    """EliaTopBar speech-to-text helper (mlx-whisper).

    One-shot mode (default): transcribe one file, print one JSON line, exit.
    Daemon mode (--daemon): read JSON requests on stdin, answer on stdout.
    """
    import argparse
    import gc
    import json
    import sys


    PREFIX = "__ELIA_JSON__"


    def emit(obj):
        sys.stdout.write(PREFIX + json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()


    def run_transcribe(audio, model, language):
        import mlx_whisper

        language = None if language in ("auto", "", None) else language
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model,
            language=language,
            verbose=False,
        )
        # Keep the GPU cache from accumulating between commands. The Metal
        # pool is the bulk of the resident memory; clearing it is the
        # difference between "fast" and "still holding everything".
        try:
            import mlx.core as mx
            mx.metal.clear_cache()
        except Exception:  # noqa: BLE001
            pass
        gc.collect()
        return {
            "ok": True,
            "text": (result.get("text") or "").strip(),
            "language": result.get("language"),
        }


    def one_shot(args):
        try:
            import mlx_whisper  # noqa: F401
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": "mlx_whisper is not installed for this interpreter: %s" % exc})
            return 1

        if args.check_only:
            try:
                from huggingface_hub import snapshot_download
                path = snapshot_download(args.model, local_files_only=True)
                emit({"ok": True, "cached": True, "path": path})
            except Exception:  # noqa: BLE001
                emit({"ok": True, "cached": False})
            return 0

        if args.download_only:
            try:
                from huggingface_hub import snapshot_download
                path = snapshot_download(args.model)
                emit({"ok": True, "path": path})
                return 0
            except Exception as exc:  # noqa: BLE001
                emit({"ok": False, "error": str(exc)})
                return 1

        if not args.audio:
            emit({"ok": False, "error": "No audio file was given."})
            return 1

        language = None if args.language in ("auto", "", None) else args.language
        try:
            import mlx_whisper
            result = mlx_whisper.transcribe(
                args.audio,
                path_or_hf_repo=args.model,
                language=language,
                verbose=False,
            )
            try:
                import mlx.core as mx
                mx.metal.clear_cache()
            except Exception:  # noqa: BLE001
                pass
            gc.collect()
            emit({
                "ok": True,
                "text": (result.get("text") or "").strip(),
                "language": result.get("language"),
            })
            return 0
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": str(exc)})
            return 1


    def daemon_main():
        # Pre-import so the first request only pays the transcription cost.
        try:
            import mlx_whisper  # noqa: F401
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": "mlx_whisper is not installed for this interpreter: %s" % exc})
            return 1
        # Handshake: the Swift side waits for this before sending anything.
        emit({"ok": True, "event": "ready"})

        while True:
            try:
                line = sys.stdin.readline()
            except Exception:  # noqa: BLE001
                break
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception as exc:  # noqa: BLE001
                emit({"ok": False, "error": "bad request: %s" % exc})
                continue
            rid = req.get("id")
            cmd = req.get("cmd", "transcribe")

            if cmd == "shutdown":
                emit({"id": rid, "ok": True, "event": "shutdown"})
                sys.stdout.flush()
                break

            if cmd == "transcribe":
                try:
                    out = run_transcribe(
                        req.get("audio"),
                        req.get("model"),
                        req.get("language", "auto"),
                    )
                    out["id"] = rid
                    emit(out)
                except Exception as exc:  # noqa: BLE001
                    emit({"id": rid, "ok": False, "error": str(exc)})
                continue

            emit({"id": rid, "ok": False, "error": "unknown cmd: %s" % cmd})


    def main():
        parser = argparse.ArgumentParser()
        parser.add_argument("audio", nargs="?")
        parser.add_argument("--model", required=True)
        parser.add_argument("--language", default="auto")
        parser.add_argument("--download-only", action="store_true")
        parser.add_argument("--check-only", action="store_true")
        parser.add_argument("--daemon", action="store_true")
        args = parser.parse_args()

        if args.daemon:
            return daemon_main()

        return one_shot(args)


    if __name__ == "__main__":
        sys.exit(main())
    """#
}