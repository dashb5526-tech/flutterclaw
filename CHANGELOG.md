# FlutterClaw v1.0.16

## Highlights

- **Browser tooling:** Expanded `web_browse` with a large automation surface (many new actions), user-assisted **BrowserOverlay**, smarter handling of SPAs and login/auth walls, optional screenshot descriptions, and less noise in the LLM context (no embedded base64 screenshots).
- **Channels:** Responses route back to the originating channel; intermediate assistant text can flow to channels during long tool loops; channel errors no longer silently stop the agent.
- **Agent & session:** Repairs for orphaned `tool_use` blocks in transcripts (load + active sessions); stop button cancels the in-flight LLM stream immediately.
- **OpenClaw parity:** Ongoing port of missing OpenClaw behavior, including adaptive thinking, persistent unsafe mode, `/unsafe` override, and related security/UI affordances (thinking chip, Security settings).
- **Live Activity:** Correct token/model display and updates when switching agents.

## Notes for builders

- Version: **1.0.16** (build **17**) — see `pubspec.yaml`.
