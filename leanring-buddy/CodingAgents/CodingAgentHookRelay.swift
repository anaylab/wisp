//
//  CodingAgentHookRelay.swift
//  leanring-buddy
//
//  The tiny program a coding agent's hooks run. Claude Code (and Gemini CLI,
//  Antigravity) call it with the hook's JSON on stdin; it adds where the agent
//  is running (terminal, tty, iTerm session), forwards the JSON to Wisp's Unix
//  socket and — only for a permission request — waits for Wisp's answer and
//  prints it in the shape Claude Code expects.
//
//  It must never block or break the agent: if Wisp isn't running, the socket
//  connect fails immediately and the relay exits 0 printing nothing, so the
//  agent carries on exactly as if no hook were installed.
//
//  Two files, written to ~/Library/Application Support/Wisp/hooks/ on launch:
//  a /bin/sh wrapper (checks python3 is really there, so a Mac without the
//  developer tools never gets the "install command line tools" dialog from a
//  hook) and the Python relay itself. Adapted from Coucou's nb-hook (MIT).
//

import Foundation

nonisolated enum CodingAgentHookRelay {
    /// The folder holding the relay and the socket.
    static var supportDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp", isDirectory: true)
    }

    static var hooksDirectoryURL: URL {
        supportDirectoryURL.appendingPathComponent("hooks", isDirectory: true)
    }

    /// The wrapper the agents' settings point at. Its file name is also how the
    /// installer recognises Wisp's own entries in a settings file.
    static var wrapperScriptURL: URL {
        hooksDirectoryURL.appendingPathComponent(wrapperScriptFileName)
    }

    static let wrapperScriptFileName = "wisp-agent-hook"

    static var pythonRelayURL: URL {
        hooksDirectoryURL.appendingPathComponent("wisp-agent-hook.py")
    }

    /// The socket Wisp listens on. A Unix socket path is limited to 103 bytes on
    /// macOS; "/Users/<name>/Library/Application Support/Wisp/agent-hooks.sock"
    /// stays well inside that for any ordinary user name.
    static var socketURL: URL {
        supportDirectoryURL.appendingPathComponent("agent-hooks.sock")
    }

    /// The command a settings file runs: the wrapper through /bin/sh, quoted
    /// because "Application Support" has a space in it.
    static var hookCommandBase: String {
        let escapedWrapperPath = wrapperScriptURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh \"\(escapedWrapperPath)\""
    }

    /// Writes (or refreshes) both relay files. Called on every launch so an
    /// app update that changes the relay takes effect without reinstalling hooks.
    static func installRelayFiles() throws {
        let fileManager = FileManager.default
        for directoryURL in [supportDirectoryURL, hooksDirectoryURL] {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }
        try writeExecutable(wrapperScriptSource, to: wrapperScriptURL)
        try writeExecutable(pythonRelaySource(socketPath: socketURL.path), to: pythonRelayURL)
    }

    /// Whether the relay can actually run: python3 needs the Xcode command line
    /// tools (or Xcode). Without them the wrapper silently does nothing.
    static func isPythonAvailable() -> Bool {
        let xcodeSelectProcess = Process()
        xcodeSelectProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        xcodeSelectProcess.arguments = ["-p"]
        xcodeSelectProcess.standardOutput = FileHandle.nullDevice
        xcodeSelectProcess.standardError = FileHandle.nullDevice
        do {
            try xcodeSelectProcess.run()
            xcodeSelectProcess.waitUntilExit()
            return xcodeSelectProcess.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func writeExecutable(_ source: String, to fileURL: URL) throws {
        let existingSource = try? String(contentsOf: fileURL, encoding: .utf8)
        if existingSource != source {
            try source.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
    }

    // MARK: - Sources

    private static let wrapperScriptSource = """
    #!/bin/sh
    # Wisp coding-agent hook relay. Always exits 0 — never blocks the agent.
    HOOK_DIR="$(dirname "$0")"
    if xcode-select -p >/dev/null 2>&1; then
        out=$(/usr/bin/python3 "$HOOK_DIR/wisp-agent-hook.py" "$@" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$out" ]; then
            printf '%s\\n' "$out"
        fi
    fi
    exit 0
    """

    /// The Python relay. The socket path is baked in at install time so the
    /// relay never has to guess where Wisp lives.
    static func pythonRelaySource(socketPath: String) -> String {
        let escapedSocketPath = socketPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        #!/usr/bin/env python3
        # wisp-agent-hook.py — forwards a coding agent's hook event to Wisp.
        # Reads JSON on stdin, adds terminal context, sends it to Wisp's socket.
        # Only a PermissionRequest waits for an answer; everything else is
        # fire-and-forget with a 0.3s timeout. Never fails the agent.
        import sys, json, os, socket, subprocess

        SOCKET_PATH = '\(escapedSocketPath)'

        EVENT_ALIASES = {
            'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
            'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
            'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
            'startup': 'SessionStart', 'exit': 'SessionEnd',
            'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        }

        def normalize_tool_fields(payload):
            # Gemini CLI and Antigravity describe tools differently from Claude Code.
            if 'tool_name' in payload:
                return
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
            if 'tool_input' not in payload and isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'),
                                 ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
            if 'session_id' not in payload:
                for key in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
                    if payload.get(key):
                        payload['session_id'] = payload[key]
                        break
                if 'session_id' not in payload and os.environ.get('GEMINI_SESSION_ID'):
                    payload['session_id'] = os.environ['GEMINI_SESSION_ID']

        def controlling_tty():
            # The agent's terminal device, so Wisp can bring back the exact
            # Terminal.app tab. Best effort: empty when there is none.
            try:
                out = subprocess.run(['/bin/ps', '-o', 'tty=', '-p', str(os.getppid())],
                                     capture_output=True, text=True, timeout=0.5).stdout.strip()
                if out and out != '??':
                    return '/dev/' + out
            except Exception:
                pass
            return ''

        def send(payload, timeout, wait_for_reply):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(SOCKET_PATH)
            s.sendall((json.dumps(payload) + '\\n').encode())
            if not wait_for_reply:
                s.close()
                return ''
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            return b''.join(chunks).decode().strip()

        def main():
            try:
                raw = sys.stdin.buffer.read()
                if not raw:
                    return
                payload = json.loads(raw)
                if not isinstance(payload, dict):
                    return
            except Exception:
                return

            # --agent <name> tags the payload; a bare argument is a fallback
            # event name for agents that don't set hook_event_name.
            args = sys.argv[1:]
            agent = ''
            arg_event = ''
            i = 0
            while i < len(args):
                if args[i] == '--agent' and i + 1 < len(args):
                    agent = args[i + 1]
                    i += 2
                else:
                    if not arg_event:
                        arg_event = args[i]
                    i += 1
            if agent:
                payload.setdefault('wisp_agent', agent)

            env = os.environ
            payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
            payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
            payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
            if not payload.get('cwd'):
                paths = payload.get('workspacePaths', [])
                payload['cwd'] = paths[0] if isinstance(paths, list) and paths else os.getcwd()
            try:
                raw_event = payload.get('hook_event_name', '') or arg_event
                if raw_event:
                    payload['hook_event_name'] = EVENT_ALIASES.get(raw_event, raw_event)
                normalize_tool_fields(payload)
            except Exception:
                pass
            event = payload.get('hook_event_name', '')
            if event in ('SessionStart', 'UserPromptSubmit', 'PermissionRequest'):
                payload.setdefault('tty', controlling_tty())

            if event == 'PermissionRequest':
                # Claude Code waits for this hook (its timeout is 120s).
                try:
                    reply = send(payload, 118, True)
                    decision = json.loads(reply).get('permissionDecision', '') if reply else ''
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'behavior': 'allow'}
                elif decision == 'always':
                    out = {'behavior': 'allow',
                           'updatedPermissions': payload.get('permission_suggestions', [])}
                elif decision == 'deny':
                    out = {'behavior': 'deny', 'message': 'Denied from Wisp'}
                else:
                    # No answer: print nothing, so Claude Code asks in the terminal.
                    return
                sys.stdout.write(json.dumps({'hookSpecificOutput': {
                    'hookEventName': 'PermissionRequest', 'decision': out}}) + '\\n')
                sys.stdout.flush()
                return

            try:
                send(payload, 0.3, False)
            except Exception:
                pass
            # Gemini CLI and Antigravity expect JSON on stdout ({} = no decision).
            if agent in ('gemini', 'antigravity'):
                sys.stdout.write('{}\\n')
                sys.stdout.flush()

        main()
        sys.exit(0)
        """
    }
}
