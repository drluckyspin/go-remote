---
name: go-remote
description: >-
  Moves the current coding session into a hardened go-remote workspace and opens it on the user's phone: the same
  conversation carries on there, with its history, and closes here. Use when the user runs /go-remote ($go-remote in
  Codex), or asks to continue on their phone, go remote, or keep working from another device.
---

# Go remote

Moves this session into a go-remote workspace for the current repo: a container on this computer that the phone reaches
over BitBang. A Claude Code or Codex session moves whole. Once your reply ends, it closes here, resumes in the
container, and a QR code opens in a window; scanning it lands the user in this same conversation on the phone. Other
agents hand over a written brief instead. The `go-remote` CLI does the work.

## Guardrails

- **Never handle the way in.** The BitBang URL, the pairing link and code, the PIN, the web token, the sign-in token and
  `.env` each grant access, and anything you read goes to a model provider. Do not print, read, copy or ask for them.
  Run `go-remote` with `--json`: its output never contains them, and the QR code opens in a window on the user's screen
  instead. Do not run `go-remote logs`, `docker logs` or `go-remote qr` without `--json`, and do not open the QR image.
- **Never push, commit, or stop a workspace** unless the user asks. Ask before running `go-remote stop`.
- If `go-remote` is not installed, tell the user to run `make install-cli` in their go-remote checkout, and stop.

## Steps

1. **Confirm the repo.** Run `git rev-parse --show-toplevel` and `git status --short`. Tell the user which repo will be
   mounted and how many uncommitted changes it has: the laptop and the container share the working tree.

2. **Find this session's id.**

   | Agent                               | Where the id is                                                                                             |
   | ----------------------------------- | ----------------------------------------------------------------------------------------------------------- |
   | Claude Code                         | `${CLAUDE_SESSION_ID}`; if that still reads as a placeholder, run `printf '%s\n' "$CLAUDE_CODE_SESSION_ID"` |
   | Codex                               | run `printf '%s\n' "$CODEX_THREAD_ID"`                                                                      |
   | Anything else (Cursor, Gemini, ...) | none: hand over a brief (step 3)                                                                            |

   Only if those are empty, run `go-remote sessions --json` in the repo, take the newest entry for your agent, and
   confirm it with the user before using it.

3. **Move it.** For Claude Code or Codex, from the repo:

   ```bash
   go-remote start "$(git rev-parse --show-toplevel)" --json --resume <agent>:<id>
   ```

   go-remote starts the workspace (the first start can take a minute) and answers with `"moving": true`. The move itself
   waits for this turn to end. Codex: go-remote needs Docker, so it has to run outside Codex's own sandbox.

   For any other agent, write a brief to `.go-remote/handoff.md` at the repo root (go-remote keeps `.go-remote/` out of
   git): a first line `Model: <id>` naming the model you are running on, as the new agent's own CLI spells it (for
   Claude Code `claude-opus-5-5` or the alias `opus`; leave the line out if you are not sure), then the goal, what is
   done, what is next, decisions and open questions, the files involved, and how to test. No secrets. Then start a new
   agent with it (`--agent codex` if the user prefers Codex):

   ```bash
   go-remote start "$(git rev-parse --show-toplevel)" --json --agent claude --brief .go-remote/handoff.md --open chat
   ```

4. **Tell the user, then end your turn.** Run nothing after go-remote answers: the move starts when your reply ends.

   - `"moving": true`: when this reply ends, this session closes here and continues in the workspace, and a QR code
     opens in a window. Scanning it with the phone's camera connects, pairs the phone and opens this conversation.
     Later, `go-remote pull` in the repo brings the session back to this computer, and `claude --resume <id>` (or
     `codex resume <id>`) carries on with it here.
   - `"qr": "window"`: the QR code is open in a window on their screen; scanning it opens the new agent's chat.
   - `"qr": "none"`: there was no window to show it in; ask them to run `go-remote qr` in a terminal.
   - go-remote fails because the agent is not signed in, in the container: the session stays here. Ask the user to run
     `go-remote login` in a terminal (once, for every workspace), then `/go-remote` again.
   - Warnings on stderr (a version difference, uncommitted changes) are worth passing on.

   The pairing code in the QR code expires in 10 minutes; `go-remote qr` in a terminal makes a new one. If no QR code
   appears within a minute of your reply ending, the terminal this session ran in says why.
