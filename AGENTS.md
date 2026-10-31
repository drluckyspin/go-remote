# AGENTS.md

How to work on go-remote: where things are, how to test them, and the rules that keep it safe to change. This file is
for coding agents and people alike. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the system works, and
[README.md](README.md) is the user guide.

## What go-remote is

go-remote lets you leave your desk without leaving your coding agent behind. Type `/go-remote` in Claude Code or Codex.
It waits for the agent to finish its turn, moves the conversation into a locked-down Docker container on your own
computer, and shows a QR code. Scan it, and your phone opens the same session in a chat-and-terminal view, connected
over BitBang's encrypted peer-to-peer link. There are no ports to open, no accounts to create and nothing to host. The
container sees only the repo you gave it, and it can alert your phone when the agent needs you. Claude Code, Codex and
Cursor all run inside.

It has three parts: an image with a hardened compose service (one workspace per repo), a host CLI (`go-remote`, with
`gr` as its short name), and the `/go-remote` skill that lets an agent move its own session.

## Repo map

| Path                      | What it holds                                                                                                   |
| ------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `Common.make`, `Makefile` | Every make target is in `Common.make`; `Makefile` only includes it                                              |
| `Dockerfile`              | The workspace image: `node:24-trixie-slim` with the pinned agent CLIs, BitBang, Herdr, herdr-web-ui, Bun and uv |
| `docker-compose.yml`      | The one hardened `workspace` service; make and the CLI give it a project name per repo                          |
| `docker/`                 | What runs in the container, installed as `/usr/local/bin/go-remote-*`, plus Herdr, tmux, Codex and bash config  |
| `ingress/`                | `go-remote-ingress` (`server.ts`, `rewrite.ts`, `compat.js`) and `go-remote-alerts` (`alerts.ts`), run by Bun   |
| `cli/`                    | The host CLI, in Bun and TypeScript, compiled in Docker by `cli/Dockerfile` into `dist/go-remote-<os>-<arch>`   |
| `skills/go-remote/`       | The `/go-remote` skill, embedded in the CLI and installed by `go-remote install-skill`                          |
| `scripts/`                | Host scripts: `log.bash`, `checkenv.bash`, `export-ca.bash`, `smoke-test.bash`, `e2e.bash`, `bump-version.bash` |
| `e2e/`                    | The Playwright phone test (`phone.mjs`), its image, and a stand-in Anthropic API (`mock-anthropic.ts`)          |
| `config/`                 | Mounted read-only at `/etc/go-remote`; `ice-servers.example.json` shows how to add a TURN relay                 |
| `certs/`                  | Extra root CAs to bake into the image; `make build` exports the Zscaler one there when the Mac has it           |
| `third_party/`            | License texts of the components the image or the CLI carries                                                    |
| `VERSION`                 | The project version, changed only with `make bump-version`                                                      |

## Commands

| Command      | Needs                                        | Takes             | What it covers                                                                   |
| ------------ | -------------------------------------------- | ----------------- | -------------------------------------------------------------------------------- |
| `make lint`  | dprint, shfmt, mbake, shellcheck, Docker CLI | seconds           | Formatting of every file type, shellcheck, and `docker-compose.yml` validity     |
| `make unit`  | Docker with Buildx                           | seconds, cached   | `tsc --noEmit` and `bun test` for the CLI and the ingress, in Docker             |
| `bun test`   | Bun on the host                              | about a second    | The same unit tests, for quick loops                                             |
| `make cli`   | Docker with Buildx                           | about a minute    | The unit tests, then the four `dist/` binaries                                   |
| `make build` | Docker with Buildx                           | minutes, cached   | The image                                                                        |
| `make test`  | The image                                    | about 90 seconds  | The smoke test: hardening, toolchain and pins, git, both UIs, BitBang end to end |
| `make e2e`   | The image, Buildx, and network to bitba.ng   | about 150 seconds | A phone through a real BitBang URL, the default agent, and a session move        |

Which to run:

- Every change: `make lint`.
- TypeScript in `cli/` or `ingress/`: `make unit`, or `bun test` while iterating.
- `Dockerfile`, `docker/`, `docker-compose.yml` or `ingress/`: `make build`, then `make test`.
- Anything on the path from the phone to herdr-web-ui, the default agent, or moving sessions: `make e2e` as well.
- Before opening a pull request: all of them.

In a sandboxed agent shell, `bun test` must run outside the sandbox, because the tests open unix sockets. The make
targets need Docker, so they also run outside it.

The smoke test and the e2e test each create their own repo, env file and home volume, never use `.env`, and clean up
after themselves. They print no BitBang URL or pairing code. Their checks reach BitBang's servers, so a check can fail
once on a network hiccup; run it again before chasing it, and say so in the pull request if it happened.

### On a real phone

`make e2e` drives a phone browser through a real BitBang URL, but not a real phone. After a change on that path, check
these by hand, and say in the pull request which ones you did:

1. `make run REPO=~/src/my-repo`, then scan the QR code with the camera: the terminal opens, already paired.
2. Type a command, and the output appears. Try Esc, Tab and Ctrl-C from the key row.
3. Lock the phone for a minute and unlock it: the page reconnects.
4. Reload the page: it stays paired. Scan a code that is more than ten minutes old: only the pairing screen appears.
5. `go-remote start ~/src/my-repo --agent claude`: the chat view opens on the phone, and a message reaches the agent.
6. With `GR_NTFY_TOPIC` set, an agent that finishes sends an alert.
7. With `GR_UI=shell`: BitBang's terminal opens on the tmux session, with the key bar.
8. `/go-remote` in a Claude Code session on the laptop: when its reply ends, the session closes and a QR code opens.
   Scan it, and the phone shows the conversation; send a message, and it carries on.

## Conventions

### Names

- Settings are `GR_*`, in `.env`, compose and the scripts. `BITBANG_PIN` and `BITBANG_MAX_SESSIONS` configure BitBang
  itself and keep its prefix.
- Everything else is `go-remote`: the image `go-remote:latest`, labels `go-remote.*`, compose projects
  `go-remote-<directory>`, the volume `go-remote-home`, commands in the image `go-remote-*`, and paths under
  `/usr/local/lib/go-remote`, `/usr/local/share/go-remote`, `/opt/go-remote`, `/etc/go-remote` and `/tmp/go-remote`.
- The compose project name is computed in two places, `go_remote_project` in `Common.make` and `projectName()` in
  `cli/src/workspace.ts`. Change them together; `cli/src/workspace.test.ts` pins the rules.

### Bash

- Scripts end in `.bash`, start with `#!/usr/bin/env bash` and `set -euo pipefail`, and open with the header block the
  other scripts use: Script Name, Description, Usage.
- Output goes through `scripts/log.bash` (`log_info`, `log_success`, `log_warning`, `log_error`, `log_indent`). It
  writes to stderr, so stdout stays free for data. In the image it is `/usr/local/lib/go-remote/log.bash`.
- shfmt formats with two-space indents (`-i 2 -ci`), and shellcheck runs at warning level with `-x`.

### Make

- `Common.make` must work with GNU Make 3.81, the macOS default: no `.ONESHELL`, no `$(file ...)`.
- A public target is declared as `.PHONY: name ## What it does`, which is what `make help` lists.
- Recipes log with `$(LOGGER) log_info "..."`. mbake formats the file, through dprint.

### TypeScript

- Bun, with `strict` and `noUncheckedIndexedAccess`. The CLI has two dependencies, both compiled in: `lean-qr` and
  `@xterm/headless`. A new one needs a row in `THIRD_PARTY_NOTICES.md` and its license in `third_party/`.
- Messages for people go through `ui` in `cli/src/ui.ts`, on stderr. stdout carries only what a command produces: a QR
  code, a table or JSON. An error a person can act on is a `UserError(message, hint)`.
- Tests sit beside the code as `*.test.ts`.

### Comments

Each file opens with a comment that says what it is for. Comments elsewhere explain why: a constraint, an upstream
limit, a security reason. They do not narrate what the next line does.

### Markdown and GitHub text

- Markdown is formatted by dprint with the repo's `dprint.json`: 120 columns, wrapped. Tables are aligned, and every
  code fence has a language tag.
- Pull request descriptions and release notes are different: GitHub turns every newline into a line break there, so each
  paragraph and list item goes on one line.

## Recipes

### Change the version

Run `make bump-version X.Y.Z`. It writes `VERSION` and copies the version into `package.json`, which the CLI compiles in
for `go-remote --version`. Never edit either by hand. If another file starts carrying the version, add it to
`scripts/bump-version.bash`. A release also gets its own column in the README's Pinned versions table.

### Bump a pinned component

1. In the `Dockerfile`, change the component's `*_VERSION` build argument. Herdr and the Cursor Agent CLI also pin a
   SHA-256 digest for each architecture (`*_SHA256_AMD64`, `*_SHA256_ARM64`). herdr-web-ui pins a commit
   (`HERDR_WEB_UI_COMMIT`) as well as its version. BitBang is checked against its release's `checksums.txt`, and dprint
   against its `SHASUMS256.txt`. shfmt and ShellCheck pin a digest per architecture too. mbake is pinned, with every
   package it needs, in `docker/mbake-requirements.txt`; change `MBAKE_VERSION` and regenerate the file with the
   `uv pip compile` command in its header.
2. The `go-remote.version.*` label picks the new version up. A new component also needs a label, and an entry in the pin
   loop in `scripts/smoke-test.bash`.
3. An agent CLI's label is also in `PIN_LABELS` in `cli/src/versions.ts`, which compares it with the laptop's version
   when a session moves.
4. Update the README's Pinned versions table, and `THIRD_PARTY_NOTICES.md` if the component or its license changes.
5. Run `make build` and `make test`, and `make e2e` for BitBang, Herdr, herdr-web-ui or Claude Code.

### Add an agent kind

Cursor was added this way, in [pull request #4](https://github.com/drluckyspin/go-remote/pull/4):

- Install it in the `Dockerfile`, pinned and checksum-verified, with a version label, and add it to the smoke test's pin
  loop.
- Add it to `AgentKind` and `AGENT_NAMES` in `cli/src/sessions.ts`, and to `PIN_LABELS`. Leave it out of
  `SessionAgentKind` until go-remote can copy, resume and pull its transcripts.
- In `docker/agent.bash`: how to tell it is signed in, how to spot its sign-in screen, its start arguments, and its
  `login` command.
- In `docker/entrypoint.bash`: its home directories and its `herdr integration install`.
- In the CLI: its start arguments in `cli/src/handoff.ts`, the `--agent` and `login` choices in `cli/src/main.ts`, and
  `doctor` and `login`.
- Document any API key in `.env.example`, and add a smoke check.

### Set the agent's model

go-remote never reads the model an agent runs on; herdr-web-ui's pill only reports the last model in the transcript, and
is not clickable. A fresh agent gets `--model <id>` from two places, and a resumed session gets none:

- the `Model:` line of `.go-remote/handoff.md`, read by `briefModel()` in `cli/src/handoff.ts`, which wins;
- `GR_MODEL`, read in the container by `containerModel()` for `go-remote start`, and by `start_in_pane` in
  `docker/agent.bash` for the default agent.

Both check the value against the same plain-id pattern, because an agent writes the brief and a flag or shell word must
never reach a command line. Change the pattern in both places together. A new agent kind needs no change if its CLI
takes `--model`.

### Add a setting

- Name it `GR_*` and document it in `.env.example`.
- A secret (an API key, a token, the PIN, the ntfy topic) reaches the container only through compose's `env_file`. Never
  pass one by `${VAR}` interpolation: a key exported in the host shell would win over `.env` and land in a container
  that can be reached remotely.
- A setting that is not secret goes in compose's `environment:` with a default, `GR_X: ${GR_X:-default}`.
- Existing users get new keys from `scripts/checkenv.bash`, which offers a `.env.new` with them added.

### Publish the image or the CLI

go-remote ships neither: the image and the `go-remote` executables are built on each user's machine. Pushing the image
to a registry, or handing out the executables, would redistribute what they carry, and some of it cannot simply be
passed on. Before anyone does, go through `THIRD_PARTY_NOTICES.md`, and settle at least these:

- **ShellCheck is GPL-3.0.** A published image distributes its binary, so it must come with the license text and an
  offer of the matching source, or be left out of the published image.
- **Claude Code and the Cursor Agent CLI are proprietary.** A published image may not carry them without permission from
  Anthropic and Cursor; it would have to fetch them on the user's machine instead.
- **Bun statically links JavaScriptCore, which is LGPL-2,** into the image and every `go-remote` executable. Check
  [Bun's licensing page](https://bun.sh/docs/project/licensing) for what that requires.

A new component with a copyleft or proprietary license gets a line in this list.

## Security rules

These hold the design together. A change that weakens one says so, and why, in its pull request.

- **Container hardening** in `docker-compose.yml`: `read_only`, `cap_drop: [ALL]`, `no-new-privileges`, the non-root
  `agent` user, `init`, limits on processes, memory and CPUs, `/tmp` on tmpfs, and `restart: "no"`. No ports are
  published; the only way in is BitBang's outbound connection.
- **Mounts:** the repo, at its host path; the home volume; and the checkout's `config/`, read-only at `/etc/go-remote`.
  Nothing else. `resolveRepo()` and `RESERVED_PATHS` in `cli/src/workspace.ts` refuse `/`, the home directory, system
  paths and git worktrees.
- **Nothing that grants access is printed.** That covers BitBang URLs, pairing codes, OAuth tokens and `.env` contents,
  in logs, test output, pull requests and an agent's context. `redact()` in `cli/src/link.ts` strips URLs and connection
  IDs. `cli/src/present.ts` shows the link only on an interactive terminal or in a window on the laptop. The ingress
  never logs a request URL, because a scanned link carries the pairing code in its query.
- **herdr-web-ui's access token** stays in the container's tmpfs. Phones get in only by pairing, with one-time codes
  from `go-remote-pair`.
- **The ingress** may restore Host, add `X-Forwarded-Proto`, drop `tailscale-*` identity headers, move the app's CSP
  into a meta tag with only `frame-ancestors 'self'` left as a header, drop `X-Frame-Options`, and load `compat.js`. It
  leaves pages whose policy has `sandbox` alone (file previews stay unframeable rather than lose their sandbox), and
  only `compat.js` adds `x-herdr-machine`, to the app's own same-origin writes, so cross-site requests still fail.
- **Updates and telemetry stay off,** and every component is pinned.

### Tests and the machine they run on

Tests never touch the real `~/.claude`, `~/.codex`, `~/.cursor`, `~/.agents`, `~/.config/go-remote`, `~/.local/bin`, the
Keychain or `.env`, and never run a real sign-in. The existing tests show how. Unit tests make temporary directories
(`mkdtempSync`) and pass them in where the real ones would go: a home for `installSkill()`, `Stores` for sessions,
`XDG_CONFIG_HOME` for the config. The e2e test points `CLAUDE_CONFIG_DIR` at a temporary laptop, uses `GR_ENV_FILE` and
`GR_HOME_VOLUME` for a throwaway env file and volume, and answers Claude Code with the stand-in Anthropic API. To try
`make install-cli` or `make upgrade`, point `HOME`, `XDG_CONFIG_HOME` and `BIN_DIR` at a temporary directory: they run
`go-remote setup`, which writes its config under `XDG_CONFIG_HOME` whenever that is set, and `upgrade` installs the
skill under that `HOME`. Set `DOCKER_CONFIG=$HOME/.docker` from the real home first, or Docker loses its Buildx plugin.
`go-remote stop` and `make down` stop every workspace after asking; try them with throwaway containers that carry a
workspace's labels (`go-remote.repo`, `com.docker.compose.service=workspace`, `com.docker.compose.project`), and only
when `docker ps -a --filter label=go-remote.repo` shows no real ones.

## Git and pull requests

- Work on a feature branch. Pull requests that build on each other are stacked with GitHub Stacks, and land in `main`
  bottom-up with merge commits.
- Keep commits small, each passing `make lint` and the unit tests, with an imperative subject and a body that says why.
- Stage explicit paths, and check `git diff --cached --name-only` before committing.
- No emoji in commits, pull request titles or descriptions.
- Ask before anything destructive: force-pushing, deleting a branch or tag, rewriting pushed history,
  `git reset --hard`, or closing a pull request. A merged pull request does not prove its branch is fully in `main`;
  `git log origin/main..<branch>` must be empty first.
- A pull request description has a summary, the changes grouped with links into the diff, and a test plan that says what
  ran and what did not.
