# Wisp

An AI companion that lives next to your cursor on macOS. Hold a hotkey, talk to it,
and it answers out loud — looking at your screen when the question is about your
screen, and flying a small blue cursor over to point at whatever it is talking about.

**Everything runs on your own machine.** No API keys, no account, no analytics, and
no network traffic except to `localhost`. Nothing you say or show it leaves the Mac
it is running on.

---

## What it uses

| Stage | What runs it | Where |
|---|---|---|
| Speech to text | Apple Speech framework | on-device |
| Answering and vision | Ollama `qwen2.5vl:7b` | `localhost:11434` |
| Speaking | `AVSpeechSynthesizer` | on-device |

The model is held in memory while you are talking to it and released after five
minutes of quiet, so it is not sitting on six gigabytes of RAM while you work.

**Voice quality is worth one minute of setup.** macOS ships compact voices that
sound robotic. Enhanced and premium voices are a free download under
**System Settings → Accessibility → Spoken Content → System Voice → Manage Voices**,
and Wisp automatically picks the highest-quality English voice you have installed.

---

## Requirements

- Apple-silicon Mac, macOS 14.2+
- 16GB RAM recommended
- [Ollama](https://ollama.com/download)
- Xcode

## Setup

```bash
ollama pull qwen2.5vl:7b
```

```bash
open leanring-buddy.xcodeproj
```

Select the `leanring-buddy` scheme and press Cmd+R. The app appears in the menu bar
with no Dock icon. Grant the four permissions it asks for, then hold
**Control + Option** and talk.

> The Xcode project and scheme keep their original names, typo included. Only the
> app is called Wisp.

### Running it outside Xcode

```bash
open -a /path/to/Wisp.app
```

Use `open`, not the binary directly. Launching `Wisp.app/Contents/MacOS/Wisp` from a
shell skips LaunchServices registration, which stops macOS attributing the speech
recognition request to the app bundle — it then aborts on the first push-to-talk with
a misleading message about a missing usage description.

---

## Features

- **Pointing.** The model tags answers with screen coordinates and the blue cursor
  flies there.
- **Annotation.** Boxes, arrows and highlights drawn over the live screen.
- **Dashboard.** Activity timeline, full conversation transcript, connected tools and
  MCP servers, per-turn timing breakdowns, and a live memory readout.
- **Agent mode.** Off by default behind `AgentModeEnabled` in `Info.plist`. When on,
  the model can call tools, including work that runs in the background and notifies
  you when it finishes. Anything that acts rather than reads asks permission first —
  out loud, and on screen with approve and deny buttons.
- **MCP.** Point `~/.wisp/mcp.json` at any stdio MCP server, using the same format
  Claude Desktop uses.

---

## Configuration

Everything is in `leanring-buddy/Info.plist`:

| Key | Default | Notes |
|---|---|---|
| `ChatProvider` | `ollama` | |
| `OllamaModel` | `qwen2.5vl:7b` | Smaller models are faster but stop emitting the coordinate tags the cursor depends on |
| `OllamaBaseURL` | `http://localhost:11434` | |
| `VoiceTranscriptionProvider` | `apple` | |
| `VoiceTTSProvider` | `apple` | |
| `AgentModeEnabled` | `false` | |

---

## Credits

Wisp began as a fork of [Clicky](https://github.com/farzaa/clicky) by
[Farza](https://github.com/farzaa), and is MIT licensed accordingly. The original
sends voice, screenshots and conversations to cloud services through a Cloudflare
Worker; this version replaces all of that with models running locally, and adds the
dashboard, screen annotation, agent loop, tool confirmation and MCP client.

Bugs and questions about *this* version belong here, not with the original author.

## License

MIT. See [LICENSE](LICENSE).
