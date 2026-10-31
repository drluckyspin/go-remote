#!/usr/bin/env bash

# -----------------------------------------------------------------------------------------------------------
# Script Name: smoke-test.bash
#
# Description: Starts a throwaway workspace container against a temporary git repo, first in the web mode
#              (Herdr, herdr-web-ui and go-remote-ingress behind BitBang's proxy) and then in the shell mode
#              (BitBang's terminal on tmux). Asserts the hardening, the toolchain and its pins, git, both
#              UIs, and an end-to-end BitBang connection in each. Uses .env.example (never your .env) and
#              its own home volume, removes everything afterwards, and never prints a URL or pairing code.
#
# Usage: ./scripts/smoke-test.bash
# -----------------------------------------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=scripts/log.bash
# shellcheck disable=SC1091
source "$(dirname "$0")/log.bash"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="$$-${RANDOM}"
PROJECT="go-remote-smoke-test-${RUN_ID}"
IMAGE=go-remote:latest
PASSED=0
FAILED=0

# Never the real home volume: cleanup deletes whatever this names.
export GR_HOME_VOLUME="go-remote-smoke-test-home-${RUN_ID}"
export GR_ENV_FILE=.env.example
export GR_WATCHDOG_INTERVAL=10
export USER_UID="${USER_UID:-1000}"
export USER_GID="${USER_GID:-1000}"
export GIT_AUTHOR_NAME="Smoke Test" GIT_AUTHOR_EMAIL="smoke@example.invalid"
export GIT_COMMITTER_NAME="Smoke Test" GIT_COMMITTER_EMAIL="smoke@example.invalid"

# Canaries: keys exported on the host must never reach the container.
export ANTHROPIC_API_KEY=go-remote-smoke-canary OPENAI_API_KEY=go-remote-smoke-canary CURSOR_API_KEY=go-remote-smoke-canary GH_TOKEN=go-remote-smoke-canary

compose() {
  docker compose --project-directory "$ROOT_DIR" -f "$ROOT_DIR/docker-compose.yml" \
    --env-file "$ROOT_DIR/.env.example" -p "$PROJECT" "$@"
}

in_container() {
  compose exec -T workspace bash -c "$1"
}

pass() {
  log_indent log_success "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  log_indent log_error "$1"
  FAILED=$((FAILED + 1))
}

check() {
  local description="$1" command="$2"
  if in_container "$command" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

cleanup() {
  log_info_dim "Removing the smoke-test container, volume and repo"
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm "$GR_HOME_VOLUME" >/dev/null 2>&1 || true
  rm -rf "${GR_REPO:-}"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_workspace
# Description: (Re)create the workspace in a UI mode and wait for its listener to register. Sets URL.
# -----------------------------------------------------------------------------------------------------------
start_workspace() {
  local mode="$1"
  log_info_dim "Starting ${PROJECT} in the ${mode} mode"
  docker volume create "$GR_HOME_VOLUME" >/dev/null
  GR_UI="$mode" compose --progress quiet up -d --force-recreate
  wait_for_listener
  pass "Listener registered (${mode} mode)"
}

# Wait for the listener to register, which a (re)started container does on a new URL. Sets URL.
wait_for_listener() {
  local waited=0
  until [ "$(in_container 'cat /tmp/bitbang/health 2>/dev/null' 2>/dev/null)" = ok ]; do
    if [ "$waited" -ge 120 ]; then
      log_error "The listener never registered"
      compose logs workspace 2>&1 | sed -E 's#https://bitba\.ng/[^[:space:]]*#<url>#g' | tail -n 20
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  URL="$(in_container 'cat /tmp/bitbang/url')"
}

# A restarted container keeps its Herdr session; a new one (go-remote start after go-remote stop) starts afresh.
session_checks() {
  local tab='herdr tab list | jq -e '\''any(.result.tabs[]; .label == "smoke-tab")'\'''
  log_info "Herdr sessions across containers"
  in_container 'herdr tab create --cwd "$GR_REPO" --label smoke-tab >/dev/null'
  compose --progress quiet restart workspace
  wait_for_listener
  check "A restarted container brings its tabs back" "$tab"
  GR_UI=web compose --progress quiet up -d --force-recreate
  wait_for_listener
  check "A new container starts a new session, without the last one's tabs" "! $tab"
}

hardening_checks() {
  log_info "Hardening"
  check "Runs as a non-root user" '[ "$(id -u)" != 0 ]'
  check "PID 1 has no effective capabilities" 'grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/1/status'
  check "bitbang has no effective capabilities" \
    'grep -q "^CapEff:[[:space:]]*0000000000000000$" /proc/$(pgrep -o -x bitbang)/status'
  check "no_new_privs is set" 'grep -q "^NoNewPrivs:[[:space:]]*1$" /proc/1/status'
  check "Root filesystem is mounted read-only" 'awk '\''$2 == "/" { print $4 }'\'' /proc/mounts | grep -q "^ro\(,\|$\)"'
  check "/tmp is a tmpfs" 'awk '\''$2 == "/tmp" { print $3 }'\'' /proc/mounts | grep -qx tmpfs'
  check "Home volume is writable" 'touch /home/agent/.smoke && rm /home/agent/.smoke'
  check "No Docker socket is mounted" '[ ! -e /var/run/docker.sock ]'
  check "BitBang identity lives in tmpfs" '[ -f /tmp/bitbang/.bitbang/bitbang/identity.pem ] && [ ! -e /home/agent/.bitbang ]'
  check "TERM is set for tmux" '[ "$TERM" = xterm-256color ]'
  check "Host shell API keys and tokens do not leak in" '! env | grep -q go-remote-smoke-canary'
  # 127.0.0.11 is Docker's DNS resolver; /proc/net/tcp writes IPv4 addresses little-endian.
  check "Nothing listens beyond loopback" \
    '! awk '\''FNR > 1 && $4 == "0A" { print $2 }'\'' /proc/net/tcp /proc/net/tcp6 | grep -vE "^[0-9A-F]{6}7F:|^0{24}01000000:"'
}

toolchain_checks() {
  local tool label version command
  log_info "Toolchain"
  for tool in "bitbang version" "claude --version" "codex --version" "cursor-agent --version" "herdr --version" "bun --version" \
    "gh --version" "git --version" "node --version" "npm --version" "python3 --version" "uv --version" \
    "tmux -V" "rg --version" "jq --version" "make --version" "dprint --version" "shfmt --version" \
    "shellcheck --version" "mbake --version"; do
    check "$tool" "$tool"
  done
  check "Interactive shells have the aliases" 'bash -ic "alias ll && alias gs"'

  for label in bitbang bun claude-code codex cursor-agent dprint herdr herdr-web-ui mbake shellcheck shfmt; do
    version="$(docker image inspect "$IMAGE" --format "{{index .Config.Labels \"go-remote.version.${label}\"}}")"
    case "$label" in
      bitbang) command="bitbang version" ;;
      bun) command="bun --version" ;;
      claude-code) command="claude --version" ;;
      codex) command="codex --version" ;;
      cursor-agent) command="cursor-agent --version" ;;
      dprint) command="dprint --version" ;;
      herdr) command="herdr --version" ;;
      herdr-web-ui) command="jq -r .version /opt/herdr-web-ui/package.json" ;;
      mbake) command="mbake --version" ;;
      shellcheck) command="shellcheck --version" ;;
      shfmt) command="shfmt --version" ;;
    esac
    if [ -n "$version" ] && in_container "$command" 2>&1 | grep -qF -- "$version"; then
      pass "${label} is ${version}, as pinned"
    else
      fail "${label} matches its pin (${version:-the image has no label; rebuild it with make build})"
    fi
  done
}

git_checks() {
  log_info "Workspace and git"
  check "Workspace is writable and shared with the host" 'touch /workspace/.smoke && [ -f /workspace/.smoke ]'
  if [ -f "$GR_REPO/.smoke" ]; then
    pass "File written in the container is visible on the host"
  else
    fail "File written in the container is visible on the host"
  fi
  check "The repo is mounted at its host path" '[ "$(cd /workspace && pwd -P)" = "$GR_REPO" ] && mountpoint -q "$GR_REPO"'
  check "git commit works in /workspace" 'cd /workspace && git add .smoke && git commit -qm smoke'
  check "SSH GitHub remotes are rewritten to HTTPS" \
    'cd /workspace && git ls-remote --get-url origin | grep -q "^https://github.com/example/smoke.git$"'
  check "The web UI's uploads and go-remote's briefs stay out of git" \
    'grep -qxF /.herdr-web-ui/ "$GR_REPO/.git/info/exclude" && grep -qxF /.go-remote/ "$GR_REPO/.git/info/exclude"'
}

web_checks() {
  log_info "Web mode: Herdr, herdr-web-ui and go-remote-ingress"
  check "Herdr server answers, with a workspace for the repo" \
    'herdr pane list | jq -e --arg repo "$GR_REPO" '\''any(.result.panes[]; .cwd == $repo)'\'''
  check "herdr-web-ui and go-remote-ingress answer" \
    'curl -fsS -o /dev/null http://127.0.0.1:7317/api/health && curl -fsS -o /dev/null http://127.0.0.1:7300/__go-remote/health'
  # [b]un: the pattern must not match the command line of the shell running this check.
  check "Telemetry and self-updates are off" \
    'environ="$(tr "\0" "\n" <"/proc/$(pgrep -o -f "[b]un server/index.ts")/environ")" &&
     grep -qx HERDR_WEB_TELEMETRY=0 <<<"$environ" && grep -qx HERDR_WEB_AUTO_UPDATE=0 <<<"$environ" &&
     grep -qx DO_NOT_TRACK=1 <<<"$environ" &&
     grep -qx "version_check = false" "$HERDR_CONFIG_PATH" && grep -qx "manifest_check = false" "$HERDR_CONFIG_PATH"'
  check "Claude Code, Codex and Bun send no usage data or crash reports" \
    '[ "$DISABLE_TELEMETRY" = 1 ] && [ "$DISABLE_ERROR_REPORTING" = 1 ] && [ "$DO_NOT_TRACK" = 1 ] &&
     sed -n "/^\[analytics\]/,/^\[/p" /etc/codex/config.toml | grep -qx "enabled = false"'
  check "The repo's shell tab is named Repo Shell" \
    'herdr tab list | jq -e '\''any(.result.tabs[]; .label == "Repo Shell")'\'''
  check "Herdr learns Claude Code, Codex and Cursor session IDs" \
    'jq -e .hooks.SessionStart ~/.claude/settings.json | grep -q herdr && grep -q herdr ~/.codex/hooks.json && grep -q herdr ~/.cursor/hooks.json'
  check "The repo's pane runs bash, which takes the web UI's bracketed paste" \
    'pane="$(herdr pane list | jq -r --arg repo "$GR_REPO" '\''first(.result.panes[] | select(.cwd == $repo)) | .pane_id'\'')" &&
     pid="$(herdr pane process-info --pane "$pane" | jq -r .result.process_info.shell_pid)" &&
     [ "$(cat "/proc/${pid}/comm")" = bash ]'
  check "Claude Code's and Codex's first-run questions are answered for the repo" \
    'jq -e --arg repo "$GR_REPO" '\''.hasCompletedOnboarding and .projects[$repo].hasTrustDialogAccepted'\'' ~/.claude.json &&
     grep -qxF "[projects.\"${GR_REPO}\"]" ~/.codex/config.toml && grep -q "^trusted_hash = \"sha256:" ~/.codex/config.toml'
  check "Codex runs without its own sandbox, which cannot work in a container" \
    'cd "$GR_REPO" && codex debug prompt-input hi 2>/dev/null | grep -qF "\`sandbox_mode\` is \`danger-full-access\`"'
  check "With no agent signed in, the default agent waits and the repo's terminal says how to sign in" \
    'go-remote-agent status | jq -e '\''.state == "waiting"'\'' &&
     pane="$(herdr pane list | jq -r --arg repo "$GR_REPO" '\''first(.result.panes[] | select(.cwd == $repo)) | .pane_id'\'')" &&
     herdr pane read "$pane" | grep -qF "make login"'
  check "Cursor waits for a sign-in when selected as the default agent" \
    'GR_DEFAULT_AGENT=cursor go-remote-agent prepare &&
     go-remote-agent status | jq -e '\''.state == "waiting" and .agent == "cursor"'\'''
  check "The ingress lets only a same-origin page frame the app, and keeps its policy in the page" \
    'curl -fsS -D /tmp/smoke-headers -o /tmp/smoke-page.html http://127.0.0.1:7300/ &&
     tr -d "\r" </tmp/smoke-headers | grep -qix "content-security-policy: frame-ancestors '\''self'\''" &&
     ! grep -qi "^x-frame-options" /tmp/smoke-headers &&
     grep -q "<meta http-equiv=\"Content-Security-Policy\" content=\"[^\"]*script-src" /tmp/smoke-page.html &&
     grep -qF "<script src=\"/__go-remote/compat.js\"></script>" /tmp/smoke-page.html'
  check "The ingress serves its compat script" 'curl -fsS http://127.0.0.1:7300/__go-remote/compat.js | grep -q x-herdr-machine'
  check "An unpaired phone gets 401, even claiming a Tailscale identity" \
    '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "X-Forwarded-For: 203.0.113.7" \
       -H "Tailscale-User-Login: alice@example.com" http://127.0.0.1:7300/api/machines)" = 401 ]'
  check "Cross-origin writes are refused" \
    '[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Origin: https://attacker.example" \
       -H "Content-Type: application/json" -d "{}" http://127.0.0.1:7300/api/devices/pair)" = 403 ]'
  check "Pairing codes are six digits" 'go-remote-pair | jq -e '\''.code | test("^[0-9]{6}$")'\'''
  check "End-to-end BitBang connection reaches the proxy-only listener" \
    "HOME=/tmp timeout 60 bitbang connect '$URL' -nosave -timeout 30s -- true </dev/null 2>&1 |
     grep -qF 'does not advertise the \`shell\` capability'"
}

watchdog_checks() {
  local old_pid
  log_info "Listener supervision"
  old_pid="$(in_container 'pgrep -o -x bitbang')"
  in_container "kill $old_pid"
  check "Listener restarts with the same URL after it exits" \
    "for _ in \$(seq 20); do
       pid=\$(pgrep -o -x bitbang) && [ \"\$pid\" != $old_pid ] && [ \"\$(cat /tmp/bitbang/health)\" = ok ] && break
       sleep 1
     done
     [ \"\$(pgrep -o -x bitbang)\" != $old_pid ] && [ \"\$(cat /tmp/bitbang/url)\" = '$URL' ]"

  log_info_dim "Waiting for two watchdog probes"
  sleep 25
  check "Watchdog reports healthy" '[ "$(cat /tmp/bitbang/health)" = ok ]'
  if compose logs workspace 2>&1 | grep -q "probe failed"; then
    fail "Watchdog probes succeed"
  else
    pass "Watchdog probes succeed"
  fi
}

shell_checks() {
  local keybar_result
  log_info "Shell mode: BitBang's terminal on tmux"
  # [b]un: the pattern must not match the command line of the shell running this check.
  check "No Herdr or web UI runs" '! pgrep -x herdr && ! pgrep -f "[b]un server/index.ts"'
  # .env.example leaves ANTHROPIC_API_KEY empty, so the exec environment carries ANTHROPIC_API_KEY="".
  check "tmux session drops empty API keys and uses the home volume" \
    'go-remote-session -d && ! tmux show-environment -g ANTHROPIC_API_KEY 2>/dev/null &&
     tmux show-environment -g HOME | grep -qx HOME=/home/agent'
  in_container 'tmux kill-server' >/dev/null 2>&1 || true

  check "GR_KEY_BAR=false hides the phone key bar and true shows it" \
    'bar_is() {
       GR_KEY_BAR="$1" tmux -L "keybar-$1" new-session -d
       status="$(tmux -L "keybar-$1" show -gv status)"
       tmux -L "keybar-$1" kill-server
       [ "$status" = "$2" ]
     }
     for value in false False no off 0; do bar_is "$value" on || exit 1; done
     for value in true True yes 1 ""; do bar_is "$value" 2 || exit 1; done'

  if keybar_result="$(compose exec -T workspace python3 - <"$ROOT_DIR/scripts/keybar-test.py" 2>&1)"; then
    pass "Phone key bar sends Esc, Ctrl-C, Tab, Shift-Tab and arrows, and pages the scrollback"
  else
    fail "Phone key bar: ${keybar_result}"
  fi

  check "TLS to api.anthropic.com verifies" 'curl -sS -o /dev/null --max-time 15 https://api.anthropic.com/'
  check "End-to-end BitBang connection to the shell" \
    "HOME=/tmp timeout 60 bitbang connect '$URL' -nosave -timeout 30s -- true </dev/null 2>&1 | grep -q '^Connected.'"
}

main() {
  log_separator
  log_info "Smoke test"

  GR_REPO="$(mktemp -d "${TMPDIR:-/tmp}/go-remote-smoke.XXXXXX")"
  GR_REPO="$(cd "$GR_REPO" && pwd -P)"
  export GR_REPO
  trap cleanup EXIT

  git -C "$GR_REPO" init -q
  git -C "$GR_REPO" remote add origin git@github.com:example/smoke.git
  echo "smoke" >"$GR_REPO/README.md"
  git -C "$GR_REPO" add README.md
  git -C "$GR_REPO" -c user.name="Smoke Test" -c user.email=smoke@example.invalid commit -qm "initial"

  start_workspace web
  hardening_checks
  toolchain_checks
  git_checks
  web_checks
  watchdog_checks
  session_checks

  start_workspace shell
  shell_checks

  log_separator
  if [ "$FAILED" -eq 0 ]; then
    log_success "Smoke test passed (${PASSED} checks)"
  else
    log_error "Smoke test failed: ${FAILED} of $((PASSED + FAILED)) checks"
    exit 1
  fi
}

main "$@"
