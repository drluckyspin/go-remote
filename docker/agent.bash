#!/usr/bin/env bash

# -----------------------------------------------------------------------------------------------------------
# Script Name: agent.bash
#
# Description: The web mode's default agent. Answers Claude Code's and Codex's first-run questions for the
#              mounted repo, starts the default agent (GR_DEFAULT_AGENT) in its own Herdr tab as soon as
#              one is signed in, and keeps its state in /tmp/go-remote/agent.json for go-remote and the shell's hint.
#              GR_MODEL, when set, is the model it starts on.
#              An agent opened before anyone signed in sits at its sign-in screen; once the sign-in happens
#              elsewhere (go-remote login), it is restarted in its tab.
#
# Usage: go-remote-agent prepare         Answer the first-run questions and record the starting state
#        go-remote-agent watch           Start the default agent once it is signed in (the entrypoint)
#        go-remote-agent ready <agent>   Exit 0 when claude, codex or cursor is signed in, 3 when it is not
#        go-remote-agent status          Print the default agent's state as JSON
#        go-remote-agent hint            Say how to sign in while no agent is (interactive shells)
#        go-remote-agent login [agent]   Sign in to claude, codex or cursor (default: the one being waited for)
# -----------------------------------------------------------------------------------------------------------

set -euo pipefail

# shellcheck source=scripts/log.bash
# shellcheck disable=SC1091
source /usr/local/lib/go-remote/log.bash

REPO="${GR_REPO:-/workspace}"
RUNTIME_DIR=/tmp/go-remote
STATE_FILE="${RUNTIME_DIR}/agent.json"
LOCK_FILE="${HOME}/.config/go-remote/agent-config.lock"
POLL_SECONDS="${GR_AGENT_POLL_SECONDS:-3}"

configured() {
  printf '%s' "${GR_DEFAULT_AGENT:-auto}" | tr '[:upper:]' '[:lower:]'
}

# The agents GR_DEFAULT_AGENT allows, in order of preference: none for `none` (or a typo).
candidates() {
  case "$(configured)" in
    auto) echo claude codex cursor ;;
    claude | codex | cursor) configured ;;
  esac
}

# The agent a sign-in is awaited for, when GR_DEFAULT_AGENT names one.
awaited() {
  case "$(configured)" in
    claude | codex | cursor) configured ;;
  esac
}

signed_in() {
  case "$1" in
    claude)
      [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
        [ -s "${HOME}/.claude/.credentials.json" ]
      ;;
    codex) [ -s "${HOME}/.codex/auth.json" ] ;;
    cursor) [ -n "${CURSOR_API_KEY:-}" ] || [ -s "${HOME}/.config/cursor/auth.json" ] ;;
    *) return 1 ;;
  esac
}

write_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  jq -n --arg state "$1" --arg agent "${2:-}" --arg pane "${3:-}" --arg configured "$(configured)" \
    '{state: $state, configured: $configured,
      agent: (if $agent == "" then null else $agent end), pane: (if $pane == "" then null else $pane end)}' >"$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# Replaces a file in one step, keeping it private.
replace_file() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  cat >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"
}

toml_string() {
  local value="${1//\\/\\\\}"
  printf '"%s"' "${value//\"/\\\"}"
}

# -----------------------------------------------------------------------------------------------------------
# Function: prepare_claude
# Description: Skip Claude Code's theme picker and onboarding, trust the mounted repo (whose folder the user
#              chose to hand to agents), and approve the ANTHROPIC_API_KEY from .env, which Claude otherwise
#              offers to ignore. Claude remembers an approved key by its last 20 characters.
# -----------------------------------------------------------------------------------------------------------
prepare_claude() {
  local config="${HOME}/.claude.json" key="${ANTHROPIC_API_KEY:-}" current updated
  [ "${#key}" -le 20 ] || key="${key: -20}"
  current="$(cat "$config" 2>/dev/null || true)"
  [ -n "$current" ] || current='{}'
  updated="$(jq --arg repo "$REPO" --arg key "$key" '
    .hasCompletedOnboarding = true
    | .theme //= "dark"
    | .projects[$repo].hasTrustDialogAccepted = true
    | if $key == "" then . else
        .customApiKeyResponses.approved = (((.customApiKeyResponses.approved // []) - [$key]) + [$key])
        | .customApiKeyResponses.rejected = ((.customApiKeyResponses.rejected // []) - [$key])
      end' <<<"$current")" || return 1
  if [ "$updated" != "$(jq . <<<"$current")" ]; then
    replace_file "$config" <<<"$updated"
  fi
}

# -----------------------------------------------------------------------------------------------------------
# Function: prepare_codex
# Description: Save the OPENAI_API_KEY from .env the way Codex's own "Provide your own API key" does (a
#              ChatGPT sign-in is left alone), trust the mounted repo, and trust Herdr's session hook, which
#              Codex otherwise holds for review and which reports the sessions the web UI's chat reads.
# -----------------------------------------------------------------------------------------------------------
prepare_codex() {
  local config="${HOME}/.codex/config.toml" auth="${HOME}/.codex/auth.json" saved table
  touch "$config"
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    saved="$(jq -r 'if .auth_mode == "apikey" then .OPENAI_API_KEY // "" else "other" end' "$auth" 2>/dev/null || true)"
    if [ "$saved" != other ] && [ "$saved" != "$OPENAI_API_KEY" ]; then
      printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || return 1
    fi
  fi
  table="[projects.$(toml_string "$REPO")]"
  if ! grep -qxF "$table" "$config"; then
    printf '\n%s\ntrust_level = "trusted"\n' "$table" >>"$config"
  fi
  trust_herdr_hook
}

# Codex trusts a hook by a SHA-256 of its normalized declaration, as compact JSON with sorted keys, kept
# under hooks.state."<hooks file>:<event>:<group>:<handler>" in config.toml. Only Herdr's own hook is trusted.
trust_herdr_hook() {
  local hooks="${HOME}/.codex/hooks.json" config="${HOME}/.codex/config.toml" group handler identity header line
  [ -f "$hooks" ] || return 0
  while IFS=$'\t' read -r group handler identity; do
    [ -n "$identity" ] || continue
    header="[hooks.state.$(toml_string "${hooks}:session_start:${group}:${handler}")]"
    line="trusted_hash = \"sha256:$(printf '%s' "$identity" | sha256sum | cut -d' ' -f1)\""
    if awk -v header="$header" -v line="$line" '
      $0 == header { inside = 1; next }
      inside && /^\[/ { inside = 0 }
      inside && $0 == line { found = 1 }
      END { exit !found }' "$config"; then
      continue
    fi
    {
      awk -v header="$header" '$0 == header { skip = 1; next } skip && /^\[/ { skip = 0 } !skip' "$config"
      printf '\n%s\n%s\n' "$header" "$line"
    } | replace_file "$config" || return 1
  done < <(jq -r '
    (.hooks.SessionStart // []) | to_entries[] | .key as $group | .value as $matcher_group
    | ($matcher_group.hooks // []) | to_entries[]
    | select(.value.type == "command" and ((.value.command // "") | contains("herdr-agent-state")))
    | ({event_name: "session_start",
        hooks: [{async: false, command: .value.command, timeout: (.value.timeout // 600), type: "command"}]}
       + (if $matcher_group.matcher then {matcher: $matcher_group.matcher} else {} end)) as $identity
    | "\($group)\t\(.key)\t\($identity | tojson)"' "$hooks")
}

initial_state() {
  local agent
  if [ -z "$(candidates)" ]; then
    write_state off
    return
  fi
  for agent in $(candidates); do
    if signed_in "$agent"; then
      write_state starting "$agent"
      return
    fi
  done
  write_state waiting "$(awaited)"
}

prepare() {
  mkdir -p "$RUNTIME_DIR" "$(dirname "$LOCK_FILE")" "${HOME}/.claude" "${HOME}/.codex" "${HOME}/.cursor" "${HOME}/.config/cursor"
  (
    flock -x 9
    prepare_claude || log_warning "Could not pre-answer Claude Code's first-run questions"
    prepare_codex || log_warning "Could not pre-answer Codex's first-run questions"
  ) 9>"$LOCK_FILE"
  initial_state
}

# The agents Herdr runs in the repo, one per line: name, kind and pane.
repo_agents() {
  herdr agent list | jq -r --arg repo "$REPO" '
    .result.agents[]? | select(.cwd == $repo or ((.cwd // "") | startswith($repo + "/")))
    | [(.name // .agent), .agent, .pane_id] | @tsv'
}

# Whether a pane shows its agent's sign-in (or first-run) screen. Claude Code, its onboarding done, opens to
# its prompt even when signed out, and reads a sign-in made elsewhere only when it starts.
at_sign_in() {
  local screen
  screen="$(herdr pane read "$1" --source visible --format text 2>/dev/null)" || return 1
  case "$2" in
    claude) grep -qE 'Not logged in|Select login method|Paste code here if prompted|OAuth error|Choose the text style|Detected a custom API key' <<<"$screen" ;;
    codex) grep -qE 'Sign in with ChatGPT|Sign in with Device Code|Provide your own API key' <<<"$screen" ;;
    # Cursor's sign-in screen wording changes between CLI releases. The watcher relies on its credential file
    # instead, so it does not accidentally restart a signed-in Cursor session.
    cursor) return 1 ;;
    *) return 1 ;;
  esac
}

start_in_pane() {
  local name="$1" kind="$2" pane="$3" deadline=$((SECONDS + 15)) result
  local -a args=()
  [ "$kind" != cursor ] || args=(--disable-auto-update)
  # same shape the CLI accepts from a brief: a flag or a shell word must never come through here
  if [[ "${GR_MODEL:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    args+=(--model "$GR_MODEL")
  elif [ -n "${GR_MODEL:-}" ]; then
    log_warning "Ignoring GR_MODEL: it is not a plain model id"
  fi
  while true; do
    if result="$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 90000 -- "${args[@]}" 2>&1)" &&
      ! jq -e '.error' <<<"$result" >/dev/null 2>&1; then
      return 0
    fi
    # a new tab's shell may not have reached its prompt yet
    if [[ "$result" == *agent_pane_busy* ]] && [ "$SECONDS" -lt "$deadline" ]; then
      sleep 0.5
      continue
    fi
    log_warning "Could not start ${kind} in pane ${pane}: $(jq -r '.error.message // empty' <<<"$result" 2>/dev/null || true)"
    return 1
  done
}

# Stops the agent in a pane (its shell stays) and starts it again there.
restart_in_pane() {
  local name="$1" kind="$2" pane="$3" group deadline=$((SECONDS + 10))
  group="$(herdr pane process-info --pane "$pane" | jq -r '.result.process_info
    | select(.foreground_process_group_id != .shell_pid) | .foreground_process_group_id // empty')"
  if [ -n "$group" ]; then
    kill -TERM -- "-${group}" 2>/dev/null || true
  fi
  while repo_agents | awk -F'\t' -v pane="$pane" '$3 == pane { found = 1 } END { exit !found }'; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log_warning "${kind} in pane ${pane} did not stop"
      return 1
    fi
    sleep 0.5
  done
  start_in_pane "$name" "$kind" "$pane"
}

# Prints the pane of a one-pane tab at the repo, labelled after the agent, whose shell is idle at its prompt:
# a tab opened for the agent by hand, which Herdr restores as a bare shell when the agent left no session.
idle_tab_pane() {
  local kind="$1" pane
  while read -r pane; do
    if herdr pane process-info --pane "$pane" |
      jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' >/dev/null 2>&1; then
      printf '%s\n' "$pane"
      return 0
    fi
  done < <(jq -rn --arg repo "$REPO" --arg kind "$kind" \
    --argjson tabs "$(herdr tab list | jq '.result.tabs // []')" \
    --argjson panes "$(herdr pane list | jq '.result.panes // []')" \
    --argjson agents "$(herdr agent list | jq '[.result.agents[]?.pane_id]')" '
    ($tabs | map(select(((.label // "") | ascii_downcase) == $kind and .pane_count == 1) | .tab_id)) as $named
    | $panes[] | select((.tab_id | IN($named[])) and .cwd == $repo and (.pane_id | IN($agents[]) | not))
    | .pane_id')
  return 1
}

# The label of the tab an agent runs in: Claude for the agent named claude, Claude 2 for claude-2.
tab_label() {
  local name="$1" kind="$2" label="${2^}"
  if [ "$name" != "$kind" ]; then
    label="${label} ${name#"${kind}-"}"
  fi
  printf '%s\n' "$label"
}

# Starts an agent at the repo, in an idle tab already named after it or else a new one; prints its pane.
start_in_tab() {
  local kind="$1" name="$1" n=2 taken workspace tab pane
  taken="$(herdr agent list | jq -r '.result.agents[]?.name // empty')"
  while grep -qxF "$name" <<<"$taken"; do
    name="${kind}-${n}"
    n=$((n + 1))
  done
  if pane="$(idle_tab_pane "$kind")"; then
    start_in_pane "$name" "$kind" "$pane" || return 1
    printf '%s\n' "$pane"
    return 0
  fi
  workspace="$(herdr pane list | jq -r --arg repo "$REPO" '[.result.panes[]?
    | select(.cwd == $repo or ((.cwd // "") | startswith($repo + "/")))] | first.workspace_id // empty')"
  if [ -z "$workspace" ]; then
    log_warning "The repo has no Herdr workspace to start ${kind} in"
    return 1
  fi
  tab="$(herdr tab create --workspace "$workspace" --cwd "$REPO" --label "$(tab_label "$name" "$kind")" --focus)" || return 1
  pane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$tab")"
  [ -n "$pane" ] || return 1
  start_in_pane "$name" "$kind" "$pane" || return 1
  printf '%s\n' "$pane"
}

# -----------------------------------------------------------------------------------------------------------
# Function: watch
# Description: Until an agent is up: take one that already runs (Herdr restores them with their sessions),
#              restarting it first if it was opened before its sign-in; else start the first signed-in
#              candidate in its own tab; else wait for a sign-in. Never starts a second default agent.
# -----------------------------------------------------------------------------------------------------------
watch() {
  local warned="" name kind pane agent found_name found_kind found_pane
  if [ -z "$(candidates)" ]; then
    [ "$(configured)" = none ] || log_warning "Ignoring GR_DEFAULT_AGENT=${GR_DEFAULT_AGENT}; use auto, claude, codex, cursor or none."
    write_state off
    return 0
  fi
  while [ ! -e "${RUNTIME_DIR}/stopping" ]; do
    found_name="" found_kind="" found_pane=""
    while IFS=$'\t' read -r name kind pane; do
      if [ -z "$pane" ] || ! signed_in "$kind"; then
        continue
      fi
      if at_sign_in "$pane" "$kind"; then
        log_info "Restarting ${kind} in the ${name} tab: it was opened before it was signed in"
        restart_in_pane "$name" "$kind" "$pane" || continue
      fi
      if [ -z "$found_pane" ]; then
        found_name="$name" found_kind="$kind" found_pane="$pane"
      fi
    done < <(repo_agents)
    if [ -n "$found_pane" ]; then
      write_state running "$found_kind" "$found_pane"
      log_success "${found_kind} is ready in the ${found_name} tab"
      return 0
    fi

    for agent in $(candidates); do
      signed_in "$agent" || continue
      write_state starting "$agent"
      if pane="$(start_in_tab "$agent")"; then
        write_state running "$agent" "$pane"
        log_success "Started ${agent} in its own Herdr tab"
      else
        write_state failed "$agent"
        log_warning "Could not start ${agent}; open its tab to see why"
      fi
      return 0
    done

    if [ -z "$warned" ]; then
      write_state waiting "$(awaited)"
      log_warning "No agent is signed in yet. Sign in once with make login (or go-remote login); the default agent then starts on its own."
      warned=1
    fi
    sleep "$POLL_SECONDS"
  done
}

status() {
  if [ -s "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    jq -n '{state: "off", configured: null, agent: null, pane: null}'
  fi
}

hint() {
  [ "$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)" = waiting ] || return 0
  cat <<'EOF'
No agent is signed in yet. Sign in once and
it opens in its own tab, ready to chat:
  On your Mac:  make login  (or go-remote login)
  Or here:      claude auth login
                codex login --device-auth
                cursor-agent login
EOF
}

login() {
  local agent="${1:-}" var
  [ -n "$agent" ] || agent="$(awaited)"
  [ -n "$agent" ] || agent=claude
  # compose passes unset .env values as empty strings
  for var in ANTHROPIC_API_KEY OPENAI_API_KEY CURSOR_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    if [ -z "${!var:-}" ]; then
      unset "$var"
    fi
  done
  cd "$REPO" 2>/dev/null || true
  case "$agent" in
    claude) claude auth login ;;
    codex) codex login --device-auth ;;
    cursor) cursor-agent login ;;
    *)
      log_error "Unknown agent ${agent}; use claude, codex or cursor"
      return 2
      ;;
  esac
  signed_in "$agent"
}

main() {
  local command="${1:-}"
  [ $# -eq 0 ] || shift
  case "$command" in
    prepare) prepare ;;
    watch) watch ;;
    ready) signed_in "${1:-}" || return 3 ;;
    status) status ;;
    hint) hint ;;
    login) login "$@" ;;
    *)
      echo "Usage: go-remote-agent prepare|watch|ready <agent>|status|hint|login [agent]" >&2
      return 2
      ;;
  esac
}

main "$@"
