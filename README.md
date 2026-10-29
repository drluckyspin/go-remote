# Go Remote

**Go Remote lets you seamlessly move your coding agent session to your phone, without moving any files to the cloud.**

<!-- markdownlint-disable MD033 -->
<p align="center">
  <img src="docs/go-remote-teaser.gif" alt="go-remote moving a Claude Code session from the laptop to a phone" width="1000">
</p>
<!-- markdownlint-enable MD033 -->

Type `/go-remote` in Claude Code or Codex on your laptop, then hand off your active conversation to a secure Docker
container running on the same machine. Scan a QR code to continue from your phone in a rich chat and terminal interface.
Powered by Herdr and BitBang, it connects over an encrypted peer-to-peer link, without VPNs, open ports, or hosted
infrastructure. Open source, local-first, and built for developers who don't want to stay at their desks. Go Remote's
core benefits are the combination of local execution, container isolation, and seamless session handoff.

Supported platforms: **macOS** (Apple Silicon and Intel) and **Linux** (x86_64 and arm64). Windows is not supported.

Requires **Docker Desktop** on macOS, or **Docker Engine with Compose v2** on Linux, plus `make` and `git`. Building the
image also needs the **Buildx** plugin: Docker Desktop includes it, but the Homebrew `docker` formula and many Linux
packages do not. Claude Code, Codex and the Cursor Agent CLI come in the image; to move a session from your laptop, you
need that agent there too.

## Why this project?

A coding agent runs in a terminal on the machine where it was started. Reaching it from a phone takes three things: a
connection to that machine, an interface to the agent that works on a phone, and limits on what that connection can
reach. BitBang provides the connection and herdr-web-ui the interface, but they do not work together as they are:
herdr-web-ui expects a conventional reverse proxy, and BitBang serves apps in an iframe through a service worker.
BitBang's own shell mode, run on the laptop, also gives anyone who has the link a shell with access to everything on it.

Go Remote combines them. It runs each repo's agents in a hardened container that mounts only that repo, serves
herdr-web-ui through BitBang with an adapter between the two, pairs each phone with a one-time code, and moves an
agent's session from the laptop into the container and back.

## How it works

<!-- markdownlint-disable MD033 -->
<p align="center">
  <img src="docs/how-it-works.png" alt="Marchitecture diagram of system flow" width="1000">
</p>
<!-- markdownlint-enable MD033 -->

Each repo gets its own workspace container, with the repo mounted at the same path as on your laptop. Inside, everything
listens on loopback only. `bitbang serve` reaches out to BitBang's signaling server, and the phone connects to it over
WebRTC. `go-remote-ingress` adapts herdr-web-ui to BitBang's page, and Herdr runs the agents, one per tab.

When you type `/go-remote` in an agent on the laptop:

1. The skill finds the session's ID, runs `go-remote start --resume`, and ends its turn.
2. `go-remote` starts the repo's workspace, if it is not running, and checks the agent there is signed in.
3. Once the turn has ended, it closes the laptop's agent, copies the session into the container, and resumes it in a new
   Herdr tab.
4. It opens a window with a QR code. The link in it carries a one-time pairing code, and never passes through the agent.
5. When the phone scans it, BitBang connects, the code pairs the phone, and herdr-web-ui opens the agent's chat with its
   earlier turns.

[ARCHITECTURE.md](ARCHITECTURE.md) describes each component and the reasons for its design.

## Quick start

Clone the repo, build the image, and install the `go-remote` command (`gr` for short) and the `/go-remote` skill:

```bash
git clone https://github.com/drluckyspin/go-remote.git && cd go-remote
make build                 # the image; bakes in a Zscaler root CA if this Mac has one
make install-cli           # go-remote, and gr linked to it, into ~/.local/bin
go-remote install-skill    # /go-remote for Claude Code, Codex and Cursor
go-remote login            # with Claude Code on this computer: sign it in once, for every workspace
```

`make install-cli` builds `go-remote` in Docker, so you need nothing else. It warns when `~/.local/bin` is not on your
PATH: add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile, and open a new terminal. The first
`go-remote start` creates `.env` from `.env.example`, readable by you only. Everything in it is optional.

To upgrade, run `git pull` in the checkout, then `make upgrade`: it builds the image and installs the new `go-remote`
and its `/go-remote` skill, so all three stay the same version. A workspace that is already running keeps the old image
until it restarts, and `make upgrade` lists any that do; restarting one ends its phone sessions, so it leaves that to
you. A release that adds a setting stops `go-remote start` until `.env` has it; `make check` offers a `.env.new` with it
added.

Codex and Cursor sign in inside a running workspace, and so does Claude Code when it is not on this computer. Run
`go-remote start ~/src/my-repo` first: with no agent signed in, it offers to sign you in. See [Signing in](#signing-in).

Then, in Claude Code, type `/go-remote` (`$go-remote` in Codex). When the reply ends, a QR code opens: scan it with your
phone's camera. To start a new conversation instead:

```bash
go-remote start ~/src/my-repo                   # the workspace and its default agent, and a QR code for it
go-remote start ~/src/my-repo --agent codex     # also start Codex in a new tab, and open its chat
```

### Without installing anything

`make run` does the same from the checkout, with no `go-remote` on your PATH:

```bash
make run REPO=~/src/my-repo    # start, show the QR code, follow the logs; Ctrl+C stops it
```

Without `REPO`, it mounts the directory you run it from, so `make -C ~/src/go-remote run` inside a repo mounts that
repo. `make run-detached` leaves the workspace running after you close the terminal.

## Moving a session

`/go-remote` moves the session it runs in. For one you have already quit, do the same from a terminal:

```bash
go-remote sessions                      # find it: claude:<id> or codex:<id>
go-remote start --resume claude:<id>    # continue it in the container, and open its chat on the phone
```

- **Single writer.** A session moves rather than being copied, so only one side writes to it. `/go-remote` waits for its
  turn to end, then closes the laptop's agent before resuming the session in the container. From a terminal, quit the
  session first; if its transcript changed in the last minute, `go-remote` asks.
- **Forking.** `--fork` continues a copy instead, so the laptop's session can continue too.
- **Handoff notes.** `--brief notes.md` copies a handoff note to `.go-remote/handoff.md` in the repo, which git ignores,
  and asks the agent to read it. `/go-remote` in an agent `go-remote` cannot resume yet, such as Cursor, writes a brief
  and starts Claude Code with it, on the model the brief's `Model:` line names (see
  [choosing the model](#choosing-the-model)).
- **Moving back.** Quit the agent in the container, then run `go-remote pull`. It copies the container's sessions for
  the repo back, keeps a `.bak` of any laptop copy it replaces, and prints the command that resumes the session here. A
  session you carried on here since is left alone, and one still open here is not replaced until you quit it.
- **Turns taken on the phone are kept.** A move never overwrites them: if the container's copy has any, `go-remote pull`
  has to bring them back first.

The container's agent must be signed in first (see [Signing in](#signing-in)); otherwise the session stays on the laptop
and `go-remote` says so. If no QR code appears after a move, the terminal the session ran in says why. `go-remote` warns
when the laptop's agent is a different version from the one in the image, because a newer transcript may not load in an
older release. A session carries the conversation, never credentials.

## On the phone

**Pairing.** Scan the QR code with the camera. BitBang connects, and the pairing code in the link pairs the phone in the
same step. A code works once, and expires after ten minutes if nobody uses it. A paired phone stays paired when the page
reloads. To add another device, run `go-remote qr` (or `make url`) for a new code. Herdr's settings, under Phone &
devices, list the paired devices and revoke them.

**Chat and Terminal.** A new workspace has two tabs: Repo Shell, a shell in the repo, and one for its default agent.
Chat and Terminal, at the top, are two views of the tab you are on, so on an agent's tab Terminal shows the agent's own
screen. herdr-web-ui's chat reads Claude Code and Codex sessions; Cursor's tab shows its live terminal instead. The
laptop sees the same tabs with `go-remote attach`. The terminal view has a row of keys above the phone keyboard (Esc,
Tab, ^C, Ctrl, Alt, Shift, Enter and the arrows), which Herdr's settings let you change.

**Restarts.** A workspace started again after `go-remote stop` opens fresh tabs; the last one's transcripts stay, for
`go-remote pull` and `--resume`. A restarted container (`docker restart`) keeps its tabs.

**Alerts.** Set `GR_NTFY_TOPIC` and install the [ntfy](https://ntfy.sh) app to get a notification when an agent needs
you or finishes, even with BitBang closed. Alerts name the agent and the repo, never what was said, and tapping one does
not open the session. Anyone who knows the topic can read its alerts, so make it long and random, for example
`openssl rand -hex 16`.

### The shell mode

`GR_UI=shell` serves BitBang's own terminal instead, on one tmux session shared by every browser, and the URL alone gets
you in. A phone keyboard has no Esc, Ctrl or arrow keys, and swiping does not scroll while tmux has mouse mode on, so
the bottom row of the tmux status bar has keys you tap:

| Key           | Sends                                                                           |
| ------------- | ------------------------------------------------------------------------------- |
| `Esc`         | Escape, for example to interrupt Claude Code                                    |
| `^C`          | Ctrl-C                                                                          |
| `Tab` `⇧Tab`  | Tab and Shift-Tab (Shift-Tab cycles Claude Code's modes)                        |
| `↑` `↓`       | Arrow keys, for menus and command history                                       |
| `PgUp` `PgDn` | Page through the scrollback; paging back to the bottom returns to the live view |

The row fits a 48-column phone screen, and the laptop sees it too. `GR_KEY_BAR=false` hides it.

## Commands

| `go-remote` command                    | What it does                                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `start [path]`                         | Start the workspace for a repo (default: the current directory) and show its QR code                         |
| `start --agent claude\|codex\|cursor`  | Also start that agent in a new tab, on a new conversation, and open it (Cursor's terminal; the others' chat) |
| `start --resume <agent:id>`            | Move a session from this computer into the workspace, and open its chat                                      |
| `qr [path]`                            | Show a fresh QR code, with a new pairing code                                                                |
| `login [claude\|codex\|cursor] [path]` | Sign an agent in, once for every workspace; Claude Code's token goes in `.env`                               |
| `list`                                 | List workspaces, their health, and the agents running in each                                                |
| `sessions [path]`                      | List the Claude Code and Codex sessions on this computer that ran in the repo                                |
| `pull [path] [agent:id]`               | Copy the container's sessions back to this computer                                                          |
| `attach [path]`                        | Open the Herdr UI in this terminal (`--shell` for the tmux session)                                          |
| `logs [path]`                          | Show the container log, with the URL taken out                                                               |
| `stop [path]`                          | Stop a workspace, or every one after asking (`--all`, `--yes`); logins stay in the home volume               |
| `doctor`                               | Check Docker, the image and its pins, `.env`, and the agent CLIs on this computer                            |
| `install-skill`                        | Install the `/go-remote` skill for Claude Code, Codex and Cursor                                             |

`go-remote help` lists every option, and `--json` gives machine-readable output for scripts and agents. The link is
shown only on an interactive terminal: otherwise the QR code opens in a window. Each repo gets its own workspace, named
`go-remote-<directory name>`, so several can run at once. `start` and `sessions` default to the current directory. `qr`,
`pull`, `attach`, `logs` and `stop` take the workspace for the repo you are in, else the only one (`stop`, else all of
them; see below). Otherwise, give them the repo's path or the workspace's name as `list` shows it, which still works
after its repo has moved: `go-remote stop go-remote-my-repo`. `login` signs in inside the named workspace, or any
running one, since they share their sign-ins.

`stop` outside any repo, with several workspaces, stops all of them, and so does `stop --all`. Stopping a workspace ends
its phone sessions, so both ask first; `--yes` skips the question, and without a terminal to ask on, `stop` refuses
unless it is given.

The make targets wrap the same commands, for use from the checkout. `make help` lists them all:

| `make` target                   | What it does                                                                  |
| ------------------------------- | ----------------------------------------------------------------------------- |
| `run` / `run-detached`          | Start a workspace for `REPO` and show its QR code, following its logs or not  |
| `url`                           | Show a fresh QR code (`QR=false` prints only the link)                        |
| `login`                         | Sign Claude Code (or `AGENT=codex` or `AGENT=cursor`) in, for every workspace |
| `attach` / `logs` / `ping`      | Open the Herdr UI here, follow the log, or list workspaces and their health   |
| `down`                          | Stop `REPO`'s workspace, or all of them after asking (`YES=1` skips it)       |
| `install-cli` / `install-skill` | Install `go-remote` and `gr` (`BIN_DIR=` to change where), or the skill       |
| `upgrade`                       | `build`, `install-cli` and `install-skill` in one go, after a `git pull`      |
| `clean` / `clean-home`          | Remove the images, binaries and exported CAs, or (after asking) the logins    |

**`gr` and Oh My Zsh.** `make install-cli` links `gr` to `go-remote`. A `gr` already in that directory that isn't
go-remote's is kept as `gr.bak`, and the install warns about any other `gr` on your PATH. It cannot see shell aliases,
though: Oh My Zsh's git plugin, on by default, makes `gr` an alias for `git remote`, and an alias wins over a command.
Add `alias gr=go-remote` to `~/.zshrc`, after the line that loads Oh My Zsh.

`go-remote install-skill` offers to install the published skill from [skills.sh](https://skills.sh) with the official
`skills` CLI, when it is available there. Otherwise, or if you decline, it installs the copy built into `go-remote`.
`--embedded` installs that copy without asking, which is what `make upgrade` does, so the skill matches the CLI.

## Configuration

All settings live in `.env`, which is gitignored and should stay mode `600`; `go-remote doctor` and `make check` warn
when it is not. Most take effect when a workspace next starts.

| Variable               | Default           | Purpose                                                                       |
| ---------------------- | ----------------- | ----------------------------------------------------------------------------- |
| `ANTHROPIC_API_KEY`    | `""`              | API key for Claude Code. Leave empty to sign in with a subscription instead   |
| `OPENAI_API_KEY`       | `""`              | API key for Codex. Leave empty to sign in with a subscription instead         |
| `CURSOR_API_KEY`       | `""`              | API key for the Cursor Agent CLI. Leave empty to use `go-remote login cursor` |
| `GH_TOKEN`             | `""`              | Fine-grained GitHub token for `git push` and `gh` (see below)                 |
| `GR_UI`                | `web`             | What the QR code opens: `web` (herdr-web-ui) or [`shell`](#the-shell-mode)    |
| `GR_RELAY`             | `force`           | `force` connects the phone through the [relay](#networks-and-reliability)     |
| `GR_DEFAULT_AGENT`     | `auto`            | The agent a web workspace opens: `auto`, `claude`, `codex`, `cursor`, `none`  |
| `GR_MODEL`             | `""`              | The model a new agent starts on; see [below](#choosing-the-model)             |
| `BITBANG_PIN`          | `""`              | PIN that BitBang asks for before connecting                                   |
| `BITBANG_MAX_SESSIONS` | `3`               | Maximum concurrent shells across all browsers, in the shell mode              |
| `GR_WATCHDOG_INTERVAL` | `300`             | Seconds between listener health probes; `0` turns the watchdog off            |
| `GR_KEY_BAR`           | `true`            | `true` shows the tmux key bar; `false` hides it                               |
| `GR_NTFY_TOPIC`        | `""`              | ntfy topic for [alerts](#on-the-phone); empty turns them off                  |
| `GR_NTFY_SERVER`       | `https://ntfy.sh` | The ntfy server                                                               |
| `GR_NTFY_TOKEN`        | `""`              | Access token, for an ntfy server that requires one                            |
| `GR_MEMORY`            | `4g`              | Container memory limit                                                        |
| `GR_CPUS`              | `2`               | Container CPU limit                                                           |
| `GR_RUNTIME`           | `runc`            | Container runtime; `runsc` runs it under gVisor on Linux hosts that have it   |

`GR_DEFAULT_AGENT=auto` picks the first of Claude Code, Codex and Cursor that is signed in. With none signed in,
`go-remote start` offers to sign you in, and the phone's Repo Shell says how.

The container receives keys and tokens **only from `.env`**. Keys exported in your shell, such as an `ANTHROPIC_API_KEY`
set in `~/.zprofile`, never reach it. Anyone who gets into the workspace can read what the container holds, so `.env`
should hold only the keys the workspace needs. Commits use the `user.name` and `user.email` from the repo's git config,
or from your global one.

### Choosing the model

A new agent starts on its own default, which in a fresh container is the account's, not what you picked on the laptop.
Two things set it:

- **`GR_MODEL`** in `.env`, such as `claude-opus-5-5` or `opus`, is passed to a new agent as `--model`. Model ids differ
  between agents, so pair it with `GR_DEFAULT_AGENT`.
- **A `Model:` line** at the top of a handoff brief. `/go-remote` from an agent that cannot be resumed, such as Cursor,
  writes it from the model it runs on. It wins over `GR_MODEL`. A value that is not a plain model id is ignored.

A session moved with `--resume` keeps the model its transcript records, and neither setting changes it. The model shown
beside the phone's chat box only reports what the agent is running; change it with `/model` in the terminal view.

### Signing in

Long URLs and codes are hard to copy on a phone, so sign in from the laptop, once. You can use a subscription or an API
key, and mix them per agent.

- **Claude Code:** `go-remote login` runs `claude setup-token` on the laptop. You sign in in the browser as usual, and
  `go-remote` saves the long-lived token in `.env` as `CLAUDE_CODE_OAUTH_TOKEN`, without showing it. Every workspace
  then starts signed in, and `go-remote` offers to restart the running ones so they get it. To use a token you already
  have, put it in `.env` yourself. Without Claude Code on the laptop, it signs in inside a running workspace instead.
- **Codex:** with a workspace running, `go-remote login codex` runs `codex login --device-auth` in it, on your terminal:
  enter the code it shows on the page it names.
- **Cursor:** with a workspace running, `go-remote login cursor` signs the Cursor Agent CLI in inside it. Or set
  `CURSOR_API_KEY`.
- **API keys:** set `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in `.env`. Claude Code uses `ANTHROPIC_API_KEY` ahead of a
  token, so leave it empty to use your subscription.

Logins made in the container live in the `go-remote-home` volume, shared by every workspace, so you sign in once for all
repos. The volume also keeps shell history, global git config and moved sessions. `docker compose down -v` leaves it
alone, and `make clean-home` deletes it after asking. Each agent asks a few questions the first time it runs, which
would block the chat view on a phone, so the container answers them when a workspace starts: Claude Code's theme and
onboarding, whether to use the API key from `.env`, trust in the mounted repo, and Codex's review of the hook that tells
Herdr its session ID.

### GitHub access

The container holds no SSH keys. SSH remotes such as `git@github.com:org/repo.git` are rewritten to HTTPS, and
`GH_TOKEN` authenticates both `git` and `gh`. Create a
[fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with:

- **Repository access:** only the repo you mount
- **Permissions:** Contents read and write, Pull requests read and write, Metadata read
- **Expiration:** the shortest that suits your work

Leave `GH_TOKEN` empty and the container has no GitHub access at all. You can still commit there, and push from the
laptop.

### Adding tools

The image is read-only. Install tools into your home directory instead, for example `uv tool install ruff`, or
`npm config set prefix ~/.npm-global` followed by `npm install -g <package>`. The home volume keeps them.

## Security model

The container is built to limit what a shell, or an agent running in it, can reach on your machine.

| Control               | Setting                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Mounted files         | Only the repo (read-write, at its own path), the home volume, and `config/` (read-only); `go-remote` refuses `/`, `~` and system paths |
| User                  | Non-root `agent`, matching your uid on Linux                                                                                           |
| Linux capabilities    | All dropped, with `no-new-privileges`                                                                                                  |
| Root filesystem       | Read-only; `/tmp` is a `nosuid`, `nodev` tmpfs                                                                                         |
| Docker socket         | Not mounted                                                                                                                            |
| Published ports       | None; BitBang connects outbound only, and everything inside listens on loopback                                                        |
| Resource limits       | 1024 processes, plus the memory and CPU limits from `.env`                                                                             |
| Secrets               | Only those in `.env`; host shell variables are not passed through                                                                      |
| Web UI access         | A paired device, or a random access token that never leaves the container                                                              |
| Updates and telemetry | Off in Herdr, herdr-web-ui, Claude Code, Codex, Bun and `go-remote`; every component is pinned, and `make test` checks the pins        |

The isolation has these limits:

- **The link grants access.** In the shell mode, the URL grants a shell to anyone who has it. In the web mode, the URL
  alone reaches only the pairing screen, but the link in the QR code also carries a pairing code that lets one device
  in. `go-remote` shows the link only in an interactive terminal or in a window on your screen, never when its output
  goes to a pipe or an agent, and its logs take the URL out. Treat the QR code like a password: set `BITBANG_PIN` for a
  second factor, and use `QR=false` when someone can see your screen.
- **A paired device stays paired.** Pairings are kept per repo in the home volume, so they survive restarts. Revoke a
  lost phone in Herdr's settings.
- **Each workspace gets a new URL.** It stays the same while the container runs, including watchdog restarts. A fresh
  container (`go-remote stop` then `go-remote start`, or a changed `.env`) gets a fresh URL, and the old one stops
  working.
- **Network access is open.** The container can reach the internet and anything your host can reach, including your LAN
  and services listening on the host. Only the tools you have given it credentials for can act as you.
- **The repo is fully writable.** An agent can rewrite any file in it, including `.git` and git hooks that run the next
  time you use git on the host. Review changes before running git on the host.
- **Codex runs without its own sandbox.** Codex's sandbox needs user namespaces, which the container does not allow, so
  it would fail every command. The image sets `sandbox_mode = "danger-full-access"` with
  `approval_policy = "on-request"` in `/etc/codex/config.toml`, so the container's limits are the ones that apply, and
  Codex still asks before a command it judges risky. Your own settings in the container's `~/.codex/config.toml` take
  precedence. Claude Code asks for permissions as it does anywhere.
- **The Claude Code token signs in every workspace.** `CLAUDE_CODE_OAUTH_TOKEN` is in each container's environment, like
  the API keys, where anyone who gets into a workspace can read it. `go-remote login` never prints it, and keeps `.env`
  mode `600`.
- **A move ends the laptop's agent.** `/go-remote` leaves a `go-remote` helper running in the background. Once the turn
  ends, it stops the agent process that ran it (the one the session is open in, and no other) before resuming the
  session in the container. Its log, which holds no links, is in `~/.local/state/go-remote/`.
- **Moved sessions travel with the agent.** A transcript holds everything said in the session, including anything you
  pasted into it. `go-remote start --resume` copies it into the home volume, where anyone who gets into a workspace can
  read it.
- **A pulled session brings the container's work home.** `go-remote pull` copies what the container's agent wrote into
  your laptop's sessions, and the agent you resume it with there has none of the container's limits. Read what the agent
  did before you carry on, as you would its changes to the repo. `go-remote pull` writes only session files for the
  repo, and only inside `~/.claude` and `~/.codex`.
- **Git worktrees and submodules are not supported.** Their `.git` points outside the mount, so `go-remote` refuses to
  mount a worktree; mount the main checkout instead.
- **Signaling skips TLS verification.** BitBang does not verify the TLS certificate of its signaling server. Its
  [security model](https://github.com/richlegrand/bitbang-cli/blob/main/SECURITY.md) is that sessions are end-to-end
  encrypted and the signaling server cannot read or join them, so TLS on that leg is not what protects you. Anyone on
  the path can still block connections.
- **The upstream projects are new.** BitBang, Herdr and herdr-web-ui are early in development and change often. Read
  [BitBang's README](https://github.com/richlegrand/bitbang-cli) before you depend on it.

## Networks and reliability

**Watchdog.** If the host sleeps, BitBang's connection to the signaling server can die without either side noticing, and
browsers then report "Device not found". Every `GR_WATCHDOG_INTERVAL` seconds the container connects to its own URL, and
in the web mode also checks that the app answers through the adapter. After two failures in a row, it restarts the
listener with the same identity, so the URL keeps working. `go-remote list` shows the result of the most recent check.

**Sleep.** While a workspace runs, `go-remote` keeps the Mac awake (with `caffeinate`, until the container stops).
Closing the lid on battery still puts it to sleep, which drops the phone's connection; `go-remote` warns when the Mac is
on battery.

**Relays.** When a direct peer-to-peer path is impossible, BitBang falls back to the `bitba.ng` TURN relay, which is
time-limited. In testing on a Mac behind Zscaler, a phone on cellular was relayed. In an emulated iPhone browser left to
try a direct path first, it waited about eight seconds for a handshake that failed, and the relayed connection it fell
back to carried data at a tenth of the speed: the app took over a minute to load. So go-remote's links carry BitBang's
`relay` flag, and the browser uses the relay from the start. `GR_RELAY=auto` lets it try a direct path again, which may
suit a host the phone can reach on the same network. For long sessions, use your own TURN server: copy
`config/ice-servers.example.json` to `config/ice-servers.json`, fill in your provider's details (coturn, Cloudflare and
Twilio all work), and restart the workspace. That file is gitignored. A file that does not parse stops the listener at
startup instead of quietly falling back.

**Zscaler and other TLS-inspecting proxies.** Zscaler inspects TLS to some hosts, including `api.anthropic.com` and
`bitba.ng`. On macOS, `make build` and `make cli` export the `Zscaler Root CA` from the System keychain into `certs/`,
and the builds trust it. Any other `*.crt` you put in `certs/` before building is trusted too. If BitBang still cannot
connect through the proxy, temporarily turn off Zscaler Internet Security to confirm that it is the cause.

## Troubleshooting

| Symptom                                             | Fix                                                                                           |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Browser says "Device not found"                     | `go-remote list`; restart a stopped workspace, or wait for the watchdog                       |
| The phone shows the pairing screen                  | The code was used or expired; `go-remote qr` makes a new one                                  |
| `go-remote qr` times out                            | Run `go-remote logs`; a bad `config/ice-servers.json` stops the listener                      |
| `curl: (60)` or certificate errors in the container | Rerun `make build` so it re-exports your proxy's root CA                                      |
| Permission denied writing to the repo on Linux      | Rebuild with `make build` as the user that owns the repo                                      |
| `claude` uses an empty API key                      | Use `go-remote attach` or the phone's terminal, not a bare `docker exec`                      |
| macOS kills `go-remote` as soon as it starts        | `codesign --force --sign - ~/.local/bin/go-remote` (`make install-cli` does this when needed) |

`go-remote doctor` checks Docker, the image, `.env` and the agent CLIs on the laptop, and says what to fix.

## Pinned versions

Every component in the image is pinned, and checksum-verified where its project publishes one. `go-remote doctor` shows
the versions in the image you built.

| Component        | go-remote 0.1.0 | go-remote 0.2.0    | go-remote 0.3.0    | go-remote 0.4.0    |
| ---------------- | --------------- | ------------------ | ------------------ | ------------------ |
| BitBang          | 0.5.1           | 0.5.1              | 0.5.1              | 0.5.1              |
| Claude Code      | 2.1.302         | 2.1.302            | 2.1.302            | 2.1.302            |
| Codex            | 0.163.0         | 0.163.0            | 0.163.0            | 0.163.0            |
| Cursor Agent CLI | not included    | 2026.10.16-e3cb207 | 2026.10.16-e3cb207 | 2026.10.16-e3cb207 |
| Herdr            | not included    | 0.9.5              | 0.9.5              | 0.9.5              |
| herdr-web-ui     | not included    | 0.4.11             | 0.4.11             | 0.4.11             |
| Bun              | not included    | 1.4.2              | 1.4.2              | 1.4.2              |
| uv               | 0.13.1          | 0.13.1             | 0.13.1             | 0.13.1             |
| Node.js          | 24              | 24                 | 24                 | 24                 |

## Project layout

```text
go-remote/
├── Dockerfile               # The workspace image, with every component pinned
├── docker-compose.yml       # The one hardened workspace service
├── docker/                  # What runs in the container: entrypoint, agents, pairing, Herdr and tmux config
├── ingress/                 # go-remote-ingress, between BitBang and herdr-web-ui, and go-remote-alerts
├── cli/src/                 # The go-remote command, in Bun and TypeScript
├── skills/go-remote/        # The /go-remote skill, built into go-remote
├── e2e/                     # The Playwright phone test, and a stand-in Anthropic API
├── scripts/                 # Smoke and e2e tests, CA export, version bump, and the log.bash logger
├── config/                  # Mounted read-only at /etc/go-remote; TURN relay settings
├── certs/                   # Extra root CAs to bake into the image
├── Common.make              # Every make target; Makefile only includes it
├── .env.example             # The settings, copied to .env on first use
└── VERSION                  # The project version, changed only with make bump-version
```

## Development

All commands run through `make` (see `make help`).

```bash
make lint      # dprint formatting check, shellcheck, docker-compose.yml validation
make format    # apply dprint, shfmt and mbake formatting
make unit      # type-check and unit-test go-remote and go-remote-ingress, in Docker
make cli       # go-remote for macOS and Linux, arm64 and x64, into dist/
make test      # smoke test of both modes in a throwaway container (needs make build)
make e2e       # Playwright phone test through a real BitBang URL: chat with Claude Code, then a moved session
make bump-version X.Y.Z    # set VERSION and sync it into package.json
```

`make test` and `make e2e` use their own repo, env file and home volume, so they never read your `.env` or touch your
logins, and they never print a URL or pairing code. [AGENTS.md](AGENTS.md) covers the conventions, the recipes for
common changes, and which tests a change needs; [ARCHITECTURE.md](ARCHITECTURE.md) explains how the pieces fit together.

## See also

| Project                                                 | Notes                                                       |
| ------------------------------------------------------- | ----------------------------------------------------------- |
| [BitBang](https://github.com/richlegrand/bitbang)       | The peer-to-peer link from the phone to the container       |
| [Herdr](https://herdr.dev)                              | The runtime the agents run in, one tab each                 |
| [herdr-web-ui](https://github.com/devswha/herdr-web-ui) | The chat-and-terminal view the phone opens                  |
| [ntfy](https://ntfy.sh)                                 | Push notifications, for alerts when an agent needs you      |
| [skills.sh](https://skills.sh)                          | The skill directory `go-remote install-skill` installs from |

## Thanks to

- [Rich LeGrand](https://github.com/richlegrand) for BitBang, the peer-to-peer link
- [Herdr](https://github.com/herdrdev/herdr) and [herdr-web-ui](https://github.com/devswha/herdr-web-ui), which run the
  agents and their phone interface
- [Bun](https://bun.sh), [lean-qr](https://github.com/davidje13/lean-qr) and
  [xterm.js](https://github.com/xtermjs/xterm.js), which `go-remote` is built with

[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists everything Go Remote builds on, and its licenses.

## Contributing

Issues and pull requests are welcome. Read [AGENTS.md](AGENTS.md) first: it says which tests a change needs, and the
security rules a change must keep. Run `make lint` on every change.

## License

MIT; see [LICENSE](LICENSE). The components in the image keep their own licenses, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<!-- markdownlint-disable MD013 MD033 -->
<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/static/v1.svg?style=for-the-badge&label=License&message=MIT&logoColor=d9e0ee&colorA=363a4f&colorB=b7bdf8"/></a>
</p>
<!-- markdownlint-enable MD013 MD033 -->
