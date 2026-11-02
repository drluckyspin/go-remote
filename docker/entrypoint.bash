#!/usr/bin/env bash

# -----------------------------------------------------------------------------------------------------------
# Script Name: entrypoint.bash
#
# Description: Container entrypoint. Prepares git for the mounted repo, starts the workspace's services,
#              then runs the BitBang listener under a watchdog. The listener's identity lives in tmpfs, so
#              the URL is stable for the life of the container (watchdog restarts keep it) and gone once
#              the container stops.
#
#              GR_UI=web (default):  herdr server -> herdr-web-ui :7317 -> go-remote-ingress :7300 -> BitBang proxy
#              GR_UI=shell:          BitBang's own terminal, pinned to the tmux session
# -----------------------------------------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=scripts/log.bash
# shellcheck disable=SC1091
source /usr/local/lib/go-remote/log.bash

REPO="${GR_REPO:-}"
RUNTIME_DIR=/tmp/go-remote
BITBANG_HOME=/tmp/bitbang
ICE_SERVERS_FILE=/etc/go-remote/ice-servers.json
SESSION_COMMAND=go-remote-session
WATCHDOG_INTERVAL="${GR_WATCHDOG_INTERVAL:-300}"
WATCHDOG_MAX_FAILURES=2
READY_TIMEOUT=60

WEB_UI_DIR=/opt/herdr-web-ui
INGRESS_SCRIPT=/opt/go-remote/ingress/server.ts
ALERTS_SCRIPT=/opt/go-remote/ingress/alerts.ts
WEB_PORT="${GR_WEB_PORT:-7317}"
INGRESS_PORT="${GR_INGRESS_PORT:-7300}"
HERDR_SOCKET="${HOME}/.config/herdr/sessions/${HERDR_SESSION:-default}/herdr.sock"
SHELL_TAB="Repo Shell"

LISTENER_PID=""
RELAY_ONLY=""
SERVICE_PIDS=()

ui_mode() {
  case "$(printf '%s' "${GR_UI:-web}" | tr '[:upper:]' '[:lower:]')" in
    shell) echo shell ;;
    *) echo web ;;
  esac
}

# -----------------------------------------------------------------------------------------------------------
# Function: check_workspace
# Description: Refuse to start unless a host directory is mounted at GR_REPO, its host path. /workspace
#              is a symlink to it, for the shell and for anything that expects the old location.
# -----------------------------------------------------------------------------------------------------------
check_workspace() {
  if [ -z "$REPO" ] || [ "${REPO#/}" = "$REPO" ]; then
    log_error "GR_REPO must be the repo's absolute host path. Start the container with: make run-detached REPO=/path/to/repo"
    exit 1
  fi
  if ! mountpoint -q "$REPO"; then
    log_error "Nothing is mounted at ${REPO}. Start the container with: make run-detached REPO=/path/to/repo"
    exit 1
  fi
  if [ ! -d "${REPO}/.git" ]; then
    log_warning "${REPO} is not a git repository"
  fi
  ln -sfn "$REPO" "${RUNTIME_DIR}/workspace"
}

# -----------------------------------------------------------------------------------------------------------
# Function: configure_git
# Description: Global git config lives in the home volume, never in the mounted repo. SSH remotes are
#              rewritten to HTTPS because the container holds no SSH keys; GH_TOKEN authenticates HTTPS.
#              Files the web UI and go-remote keep in the repo (pasted images, handoff briefs) are excluded
#              locally, in .git/info/exclude, so they never show up as changes.
# -----------------------------------------------------------------------------------------------------------
configure_git() {
  local lock="${HOME}/.config/go-remote/git-config.lock"
  mkdir -p "$(dirname "$lock")"
  (
    flock -x 9
    configure_git_locked
  ) 9>"$lock"
}

configure_git_locked() {
  local dir pattern exclude="${REPO}/.git/info/exclude"

  for dir in "$REPO" /workspace; do
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$dir"; then
      git config --global --add safe.directory "$dir"
    fi
  done

  git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
  git config --global --add url."https://github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

  if [ -d "${REPO}/.git" ]; then
    mkdir -p "${REPO}/.git/info"
    for pattern in /.herdr-web-ui/ /.go-remote/; do
      if ! grep -qxF "$pattern" "$exclude" 2>/dev/null; then
        echo "$pattern" >>"$exclude"
      fi
    done
  fi

  if [ -n "${GH_TOKEN:-}" ]; then
    if gh auth setup-git >/dev/null 2>&1; then
      log_success "GitHub HTTPS credentials come from GH_TOKEN"
    else
      log_warning "gh auth setup-git failed; git push may prompt for credentials"
    fi
  else
    log_info_dim "GH_TOKEN is not set; the container has no GitHub credentials"
  fi
}

# -----------------------------------------------------------------------------------------------------------
# Function: keep_running
# Description: Run a service in the foreground of a background loop, restarting it when it exits, until
#              the container stops. Prefixes its output with its name in the container's logs.
# -----------------------------------------------------------------------------------------------------------
keep_running() {
  local name="$1" status
  shift
  while [ ! -e "${RUNTIME_DIR}/stopping" ]; do
    "$@" > >(sed -u "s/^/${name}: /") 2>&1 &
    echo $! >"${RUNTIME_DIR}/${name}.pid"
    status=0
    wait $! || status=$?
    [ -e "${RUNTIME_DIR}/stopping" ] && break
    log_warning "${name} exited (status ${status}); restarting in 2s"
    sleep 2
  done
}

start_service() {
  keep_running "$@" &
  SERVICE_PIDS+=($!)
}

# Wait up to READY_TIMEOUT seconds for a command to succeed.
wait_for() {
  local description="$1" waited=0
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$waited" -ge "$((READY_TIMEOUT * 2))" ]; then
      log_error "${description} did not start within ${READY_TIMEOUT}s"
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
}

# -----------------------------------------------------------------------------------------------------------
# Function: fresh_session
# Description: A new container starts a new Herdr session, so go-remote start opens a new conversation: the
#              tabs and agents of the last container are not brought back. Their transcripts stay, for
#              go-remote pull and --resume. A restarted container keeps its session; its hostname, the
#              container ID, tells the two apart.
# -----------------------------------------------------------------------------------------------------------
fresh_session() {
  local dir="${HOME}/.config/herdr/sessions/${HERDR_SESSION:-default}"
  local marker="${dir}/go-remote-container"

  if [ "$(cat "$marker" 2>/dev/null)" != "$HOSTNAME" ]; then
    rm -rf "${dir}/session.json" "${dir}/session-history.json" "${dir}/session-snapshots"
  fi
  mkdir -p "$dir"
  printf '%s\n' "$HOSTNAME" >"$marker"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_herdr
# Description: Start the Herdr server for this repo's session (named after the compose project, so
#              workspaces sharing the home volume never share a server), install the agent integrations
#              that report session IDs, and make sure the repo has a Herdr workspace. A restarted
#              container's session brings its old workspaces back, so one is created only when none
#              points at the repo; its first tab, the repo's shell, is named Repo Shell. The agents'
#              first-run questions are answered before the server restores any agent.
# -----------------------------------------------------------------------------------------------------------
start_herdr() {
  local agent tab

  mkdir -p "${HOME}/.claude" "${HOME}/.codex" "${HOME}/.cursor" "${HOME}/.config/cursor"
  for agent in claude codex cursor; do
    herdr integration install "$agent" >/dev/null 2>&1 || log_warning "Could not install Herdr's ${agent} integration"
  done
  go-remote-agent prepare
  fresh_session

  # Herdr writes its own log in the session directory; what it prints is a banner, kept out of docker logs.
  start_service herdr bash -c "exec go-remote-herdr server >>'${RUNTIME_DIR}/herdr-server.out' 2>&1"
  wait_for "The Herdr server" herdr workspace list

  if ! herdr pane list | jq -e --arg repo "$REPO" \
    '.result.panes[]? | select(.cwd == $repo or (.cwd // "" | startswith($repo + "/")))' >/dev/null; then
    tab="$(herdr workspace create --cwd "$REPO" --label "$(basename "$REPO")" --focus | jq -r '.result.tab.tab_id // empty')"
    if [ -z "$tab" ] || ! herdr tab rename "$tab" "$SHELL_TAB" >/dev/null; then
      log_warning "Could not name the repo's shell tab ${SHELL_TAB}"
    fi
  fi
  log_success "Herdr server is running (session ${HERDR_SESSION:-default})"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_default_agent
# Description: In the background, start the default agent (GR_DEFAULT_AGENT) in its own Herdr tab once
#              one is signed in, so the phone's Chat has an agent to talk to and the sign-in needs no restart.
#              Its state is in /tmp/go-remote/agent.json (go-remote-agent status).
# -----------------------------------------------------------------------------------------------------------
start_default_agent() {
  go-remote-agent watch &
  echo $! >"${RUNTIME_DIR}/agent-watch.pid"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_web_ui
# Description: Start herdr-web-ui on loopback behind a random access token that never leaves the
#              container's tmpfs. Phones get in by pairing (go-remote-pair), never with the token.
#              It runs from source, not through its supervisor, so it never updates itself.
# -----------------------------------------------------------------------------------------------------------
start_web_ui() {
  local token_file="${RUNTIME_DIR}/web-token"

  (umask 077 && head -c 32 /dev/urandom | base64 | tr -d '/+=\n' >"$token_file")

  start_service herdr-web-ui env -C "$WEB_UI_DIR" \
    HOST=127.0.0.1 \
    PORT="$WEB_PORT" \
    HERDR_SOCKET="$HERDR_SOCKET" \
    HERDR_WEB_TOKEN="$(cat "$token_file")" \
    HERDR_WEB_STATE_DIR="${HOME}/.config/herdr-web-ui/${HERDR_SESSION:-default}" \
    HERDR_WEB_HERDR_BIN=/usr/local/bin/herdr \
    HERDR_WEB_APP_NAME="$(basename "$REPO")" \
    HERDR_WEB_AUTO_UPDATE=0 \
    HERDR_WEB_TELEMETRY=0 \
    DO_NOT_TRACK=1 \
    bun server/index.ts
  wait_for "herdr-web-ui" curl -fsS "http://127.0.0.1:${WEB_PORT}/api/health"

  start_service go-remote-ingress env \
    GR_INGRESS_PORT="$INGRESS_PORT" \
    GR_INGRESS_UPSTREAM="127.0.0.1:${WEB_PORT}" \
    bun "$INGRESS_SCRIPT"
  wait_for "go-remote-ingress" curl -fsS "http://127.0.0.1:${INGRESS_PORT}/__go-remote/health"
  log_success "herdr-web-ui is running behind go-remote-ingress"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_alerts
# Description: With GR_NTFY_TOPIC set, post an alert to ntfy when an agent needs you or finishes.
# -----------------------------------------------------------------------------------------------------------
start_alerts() {
  if [ -z "${GR_NTFY_TOPIC:-}" ]; then
    return
  fi
  start_service go-remote-alerts env GR_REPO_NAME="$(basename "$REPO")" HERDR_SOCKET="$HERDR_SOCKET" bun "$ALERTS_SCRIPT"
  log_info "Agent alerts go to ntfy topic on ${GR_NTFY_SERVER:-https://ntfy.sh}"
}

# -----------------------------------------------------------------------------------------------------------
# Function: relay_only
# Description: Whether the listener uses only its own TURN relay: when config/ice-servers.json names a turn: or
#              turns: server and GR_RELAY is not auto. Behind Zscaler, UDP from the container to a relay port below
#              49152 is dropped after a packet or two. A listener that also offers its own address can settle on
#              that path to the phone's relay, and the phone then stalls at "Negotiating connection".
# -----------------------------------------------------------------------------------------------------------
relay_only() {
  [ "$(printf '%s' "${GR_RELAY:-force}" | tr '[:upper:]' '[:lower:]')" != auto ] || return 1
  jq -e '[(if type == "array" then . else (.iceServers // .ice_servers) end)[]
    | .urls | (if type == "string" then [.] else . end)[]
    | select(test("^turns?:"; "i"))] | length > 0' "$ICE_SERVERS_FILE" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------------------------------------
# Function: build_listener_args
# Description: Assemble the bitbang serve command line into the global LISTENER_ARGS array. The web UI
#              is served through BitBang's HTTP proxy, which stamps the browser's address as
#              X-Forwarded-For only in this single-target mode.
# -----------------------------------------------------------------------------------------------------------
build_listener_args() {
  LISTENER_ARGS=(serve -nocode -noqr)
  if [ "$(ui_mode)" = shell ]; then
    LISTENER_ARGS+=(-disable-shell-mirror -shell-max-sessions "${BITBANG_MAX_SESSIONS:-3}")
  else
    LISTENER_ARGS+=(-proxy-client-ip)
  fi
  if [ -n "${BITBANG_PIN:-}" ]; then
    LISTENER_ARGS+=(-pin "$BITBANG_PIN")
  fi
  if [ -e "$ICE_SERVERS_FILE" ]; then
    LISTENER_ARGS+=(-ice-servers "$ICE_SERVERS_FILE")
    log_info "Using TURN/STUN servers from config/ice-servers.json"
    if relay_only; then
      RELAY_ONLY=1
      LISTENER_ARGS+=(-relay)
      log_info "The listener connects only through that TURN relay (GR_RELAY=force)"
    fi
  fi
  if [ "$(ui_mode)" = shell ]; then
    LISTENER_ARGS+=(shell "$SESSION_COMMAND")
  else
    LISTENER_ARGS+=(proxy "127.0.0.1:${INGRESS_PORT}")
  fi
}

set_health() {
  echo "$1" >"${BITBANG_HOME}/health"
}

# -----------------------------------------------------------------------------------------------------------
# Function: start_listener
# Description: Start bitbang in the background with HOME on tmpfs, teeing its output to docker logs and
#              to serve.log, then wait until it has registered and record its URL.
# -----------------------------------------------------------------------------------------------------------
start_listener() {
  local log_file="${BITBANG_HOME}/serve.log"
  local waited=0

  : >"$log_file"
  HOME="$BITBANG_HOME" bitbang "${LISTENER_ARGS[@]}" > >(tee -a "$log_file") 2>&1 &
  LISTENER_PID=$!

  while ! grep -q '^Ready' "$log_file"; do
    if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
      log_error "bitbang exited before registering with the signaling server"
      return 1
    fi
    if [ "$waited" -ge "$((READY_TIMEOUT * 2))" ]; then
      log_error "bitbang did not register within ${READY_TIMEOUT}s"
      return 1
    fi
    sleep 0.5
    waited=$((waited + 1))
  done

  # Only the URL: line is ours. Other URLs follow it, such as the install link in the notice BitBang prints
  # after Ready once the signaling server reports a newer release.
  sed -n 's/^URL: *//p' "$log_file" | head -n 1 >"${BITBANG_HOME}/url"
  if ! grep -q '^https://' "${BITBANG_HOME}/url"; then
    log_error "bitbang registered without printing its URL"
    return 1
  fi
  set_health ok
}

stop_listener() {
  if [ -n "$LISTENER_PID" ] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill -TERM "$LISTENER_PID" 2>/dev/null || true
    wait "$LISTENER_PID" 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------------------------------------
# Function: probe_listener
# Description: Connect to our own URL end to end. The listener refuses the command, because it serves
#              tmux or the web UI rather than a free shell, but only after the WebRTC connection and the
#              control-stream handshake: "Connected." (shell mode) or the proxy-only listener's
#              capability refusal (web mode) proves the URL works. In web mode the app must also answer
#              through the ingress. A relay-only listener is probed through the relay too: a probe from the
#              container's own address would send UDP to the relay's ports, which Zscaler may drop.
# -----------------------------------------------------------------------------------------------------------
probe_listener() {
  local url output
  url="$(cat "${BITBANG_HOME}/url")"
  output="$(HOME="$BITBANG_HOME" timeout 60 bitbang connect "$url" -nosave -timeout 30s \
    ${RELAY_ONLY:+-relay} ${BITBANG_PIN:+-pin "$BITBANG_PIN"} -- true </dev/null 2>&1)" || true
  if [[ "$output" != *"Connected."* && "$output" != *"does not advertise the \`shell\` capability"* ]]; then
    log_warning "Watchdog probe failed: $(echo "$output" | tail -n 1)"
    return 1
  fi
  if [ "$(ui_mode)" = web ] && ! curl -fsS -o /dev/null "http://127.0.0.1:${INGRESS_PORT}/api/health"; then
    log_warning "Watchdog probe: herdr-web-ui is not answering through go-remote-ingress"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------------------------------------
# Function: supervise_listener
# Description: Probe every WATCHDOG_INTERVAL seconds and return once the listener has exited or has
#              failed WATCHDOG_MAX_FAILURES probes in a row (it is then stopped).
# -----------------------------------------------------------------------------------------------------------
supervise_listener() {
  local failures=0 sleep_pid

  if [ "$WATCHDOG_INTERVAL" -le 0 ]; then
    wait "$LISTENER_PID" || true
    set_health down
    return
  fi

  while kill -0 "$LISTENER_PID" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL" &
    sleep_pid=$!
    wait -n "$LISTENER_PID" "$sleep_pid" || true
    kill "$sleep_pid" 2>/dev/null || true
    kill -0 "$LISTENER_PID" 2>/dev/null || break

    if probe_listener; then
      failures=0
      set_health ok
      continue
    fi

    failures=$((failures + 1))
    if [ "$failures" -ge "$WATCHDOG_MAX_FAILURES" ]; then
      log_warning "Signaling server no longer reaches this listener; restarting it with the same URL"
      set_health stale
      stop_listener
      return
    fi
  done
  wait "$LISTENER_PID" 2>/dev/null || true
  set_health down
}

stop_services() {
  local pid_file
  touch "${RUNTIME_DIR}/stopping"
  for pid_file in "${RUNTIME_DIR}"/*.pid; do
    [ -e "$pid_file" ] || continue
    kill -TERM "$(cat "$pid_file")" 2>/dev/null || true
  done
  if [ "${#SERVICE_PIDS[@]}" -gt 0 ]; then
    wait "${SERVICE_PIDS[@]}" 2>/dev/null || true
  fi
}

shutdown() {
  stop_listener
  stop_services
  exit 0
}

# -----------------------------------------------------------------------------------------------------------
# Script entry point
# -----------------------------------------------------------------------------------------------------------
main() {
  install -d -m 0700 "$RUNTIME_DIR" "$BITBANG_HOME"
  set_health starting
  trap shutdown TERM INT

  check_workspace
  configure_git
  cd "$REPO"
  if [ "$(ui_mode)" = web ]; then
    start_herdr
    start_default_agent
    start_web_ui
    start_alerts
  fi
  build_listener_args

  start_listener || exit 1
  while true; do
    supervise_listener
    log_warning "BitBang listener stopped; restarting in 3s"
    sleep 3 &
    wait $! || true
    start_listener || exit 1
  done
}

main "$@"
