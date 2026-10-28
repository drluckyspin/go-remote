/**
 * The container side of a handoff: copying sessions in, starting agents in Herdr panes, and finding what to
 * copy back. Files are written by the agent user through `docker exec`, which docker cp cannot do (it leaves
 * them owned by root, and the container has no capability to chown).
 */
import { CryptoHasher } from "bun";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { View } from "./link.ts";
import { capture, outputBytes } from "./proc.ts";
import {
  AGENT_NAMES,
  type AgentKind,
  claudeProjectDir,
  CONTAINER_STORES,
  isSessionId,
  type Session,
  type SessionAgentKind,
  type Stores,
  within,
} from "./sessions.ts";
import { hasControl, UserError } from "./ui.ts";
import { exec, herdr, listWorkspaces, type Workspace } from "./workspace.ts";

interface Pane {
  pane_id: string;
  workspace_id: string;
  cwd: string;
}

interface AgentInfo {
  name?: string;
  agent?: string;
  pane_id: string;
  agent_status: string;
  agent_session?: { value: string } | null;
}

/** How the container's copy of a session file stands against the laptop's. */
export type CopyState = "missing" | "same" | "older" | "diverged";

/**
 * Transcripts only grow, so a container copy that is a prefix of the laptop's is an older copy of the same
 * session. One that is longer, or different, holds turns the laptop's lacks.
 */
export function compareCopy(laptop: Uint8Array, container: { size: number; sha256: string } | undefined): CopyState {
  if (!container) return "missing";
  if (container.size > laptop.length) return "diverged";
  const prefix = new CryptoHasher("sha256").update(laptop.subarray(0, container.size)).digest("hex");
  if (prefix !== container.sha256) return "diverged";
  return container.size === laptop.length ? "same" : "older";
}

const STAT_SCRIPT = String.raw`
for file in "$@"; do
  if [ -f "$file" ]; then printf '%s %s\n' "$(stat -c %s "$file")" "$(sha256sum "$file" | cut -d' ' -f1)"; else echo -; fi
done`;

/**
 * Refuses a copy in that would lose work: the session still open in a workspace (they share the home volume),
 * or a container copy with turns the laptop's lacks, from working on the phone since the last move. Returns the
 * files that need copying.
 */
export async function checkCopyIn(workspace: Workspace, session: Session, stores: Stores): Promise<string[]> {
  const openIn = (await openAnywhere())(session.id);
  if (openIn) {
    throw new UserError(
      `${AGENT_NAMES[session.agent]} session ${session.id} is still open in ${openIn}`,
      "Quit it there first, so only one copy of the session is ever written to.",
    );
  }
  const containerStore = CONTAINER_STORES[session.agent];
  const paths = session.files.map((file) => `${containerStore}/${file}`);
  const stats = (await exec(workspace, ["sh", "-c", STAT_SCRIPT, "sh", ...paths])).split("\n");
  const toCopy: string[] = [];
  for (const [index, file] of session.files.entries()) {
    const [size, sha256] = (stats[index] ?? "-").split(" ");
    const container = size && size !== "-" && sha256 ? { size: Number(size), sha256 } : undefined;
    const state = compareCopy(new Uint8Array(readFileSync(join(stores[session.agent], file))), container);
    if (state === "diverged") {
      throw new UserError(
        `${workspace.project} has a copy of ${AGENT_NAMES[session.agent]} session ${session.id} with turns this computer's lacks`,
        `Bring it back first with go-remote pull ${workspace.repo}, then move it again.`,
      );
    }
    if (state !== "same") toCopy.push(file);
  }
  return toCopy;
}

export async function copyIn(workspace: Workspace, session: Session, stores: Stores): Promise<void> {
  const hostStore = stores[session.agent];
  const containerStore = CONTAINER_STORES[session.agent];
  for (const file of await checkCopyIn(workspace, session, stores)) {
    await exec(workspace, ["sh", "-c", 'mkdir -p "$(dirname "$1")" && cat >"$1"', "sh", `${containerStore}/${file}`], {
      stdin: Bun.file(join(hostStore, file)),
    });
  }
}

/** Whether the container's agent CLI is signed in. Its first-run questions are answered when the container starts. */
export async function agentReady(workspace: Workspace, agent: AgentKind): Promise<{ ok: boolean; reason?: string }> {
  const result = await capture(["docker", "exec", workspace.id, "go-remote-agent", "ready", agent]);
  if (result.code === 0) return { ok: true };
  if (result.code === 3) return { ok: false, reason: "it is not signed in yet" };
  if (result.code === 127) return { ok: false, reason: "the image is older than go-remote; rebuild it with make build" };
  return { ok: false, reason: "go-remote could not check its sign-in" };
}

/** The web mode's default agent, as the container's go-remote-agent watch records it. */
export interface DefaultAgent {
  state: "off" | "waiting" | "starting" | "running" | "failed";
  /** the agent started, being started, or (when GR_DEFAULT_AGENT names one) awaiting a sign-in */
  agent?: AgentKind;
  pane?: string;
}

const DEFAULT_AGENT_STATES: readonly DefaultAgent["state"][] = ["off", "waiting", "starting", "running", "failed"];

export function parseDefaultAgent(text: string): DefaultAgent {
  let parsed: { state?: unknown; agent?: unknown; pane?: unknown } | null;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { state: "off" };
  }
  if (typeof parsed !== "object" || parsed === null) return { state: "off" };
  const state = DEFAULT_AGENT_STATES.find((one) => one === parsed.state) ?? "off";
  const agent = parsed.agent === "claude" || parsed.agent === "codex" || parsed.agent === "cursor" ? parsed.agent : undefined;
  const pane = typeof parsed.pane === "string" && /^[\w:-]+$/.test(parsed.pane) ? parsed.pane : undefined;
  return { state, ...(agent ? { agent } : {}), ...(pane ? { pane } : {}) };
}

export async function defaultAgent(workspace: Workspace): Promise<DefaultAgent> {
  const result = await capture(["docker", "exec", workspace.id, "go-remote-agent", "status"]);
  return result.code === 0 ? parseDefaultAgent(result.stdout) : { state: "off" };
}

/**
 * The default agent once it has stopped starting, waiting up to `timeoutMs`. After a sign-in, `signedIn` also
 * waits out the watcher noticing it (it looks every few seconds).
 */
export async function settledDefaultAgent(workspace: Workspace, options: { timeoutMs?: number; signedIn?: boolean } = {}): Promise<DefaultAgent> {
  const deadline = Date.now() + (options.timeoutMs ?? 90_000);
  let current = await defaultAgent(workspace);
  while (Date.now() < deadline && (current.state === "starting" || (options.signedIn === true && current.state === "waiting"))) {
    await Bun.sleep(1000);
    current = await defaultAgent(workspace);
  }
  return current;
}

/** Where the phone's link opens: the default agent's chat once it runs, else the repo's own terminal. */
export function linkTarget(agent: DefaultAgent, mainPane: string | undefined, open?: View): { pane?: string; view: View } {
  if (agent.state === "running" && agent.pane) return { pane: agent.pane, view: open ?? "chat" };
  return { pane: mainPane, view: open ?? "terminal" };
}

export async function panes(workspace: Workspace): Promise<Pane[]> {
  return (await herdr<{ panes: Pane[] }>(workspace, ["pane", "list"])).panes;
}

export async function agents(workspace: Workspace): Promise<AgentInfo[]> {
  return (await herdr<{ agents: AgentInfo[] }>(workspace, ["agent", "list"])).agents;
}

/** The repo's own pane: the one the entrypoint opened at the repo root. */
export async function mainPane(workspace: Workspace): Promise<Pane | undefined> {
  const all = await panes(workspace);
  return all.find((pane) => pane.cwd === workspace.repo) ?? all.find((pane) => within(pane.cwd, workspace.repo));
}

/** The label of the tab an agent runs in: Claude for the agent named claude, Claude 2 for claude-2. */
export function tabLabel(agent: AgentKind, name: string): string {
  const title = agent.charAt(0).toUpperCase() + agent.slice(1);
  return name === agent ? title : `${title} ${name.slice(agent.length + 1)}`;
}

// The only shape that reaches --model, so a flag or a shell word never gets onto a command line. docker/agent.bash
// checks GR_MODEL against the same pattern.
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

/**
 * The model a handoff brief asks for, from a `Model: <id>` line near its top. The writing agent knows its own model and
 * go-remote cannot see it, so the brief carries it. An agent writes the brief, so anything that is not a plain model id
 * is ignored.
 */
export function briefModel(text: string): string | undefined {
  const found = /^model:[ \t]*(\S+)[ \t]*$/im.exec(text.split("\n").slice(0, 20).join("\n"));
  return found?.[1] && MODEL_ID.test(found[1]) ? found[1] : undefined;
}

/** The container's GR_MODEL (from .env, through compose): the model a new agent starts on when the brief names none. */
export async function containerModel(workspace: Workspace): Promise<string | undefined> {
  const result = await capture(["docker", "exec", workspace.id, "printenv", "GR_MODEL"]);
  const value = result.stdout.trim();
  return result.code === 0 && MODEL_ID.test(value) ? value : undefined;
}

/**
 * Starts an agent in a new tab at `cwd`, so the repo's own shell stays as it was. Returns the agent's name,
 * its tab's label, its pane, and whether Herdr saw it come up ready for input.
 */
export async function startAgent(
  workspace: Workspace,
  agent: AgentKind,
  cwd: string,
  args: string[],
): Promise<{ name: string; tab: string; pane: string; ready: boolean }> {
  const taken = new Set((await agents(workspace)).map((info) => info.name));
  let name: string = agent;
  for (let n = 2; taken.has(name); n++) name = `${agent}-${n}`;
  const label = tabLabel(agent, name);

  const home = await mainPane(workspace);
  const tab = await herdr<{ root_pane: { pane_id: string } }>(workspace, [
    "tab",
    "create",
    ...(home ? ["--workspace", home.workspace_id] : []),
    "--cwd",
    cwd,
    "--label",
    label,
    "--focus",
  ]);
  const pane = tab.root_pane.pane_id;
  const command = [
    "docker",
    "exec",
    workspace.id,
    "herdr",
    "agent",
    "start",
    name,
    "--kind",
    agent,
    "--pane",
    pane,
    "--timeout",
    "90000",
    "--",
    ...(agent === "cursor" ? ["--disable-auto-update"] : []),
    ...args,
  ];
  // a new tab's shell may not have reached its prompt yet
  const deadline = Date.now() + 15_000;
  let started = await capture(command);
  while (`${started.stdout}${started.stderr}`.includes("agent_pane_busy") && Date.now() < deadline) {
    await Bun.sleep(500);
    started = await capture(command);
  }
  let ready = started.code === 0;
  try {
    ready = ready && !JSON.parse(started.stdout).error;
  } catch {
    ready = false;
  }
  return { name, tab: label, pane, ready };
}

export async function prompt(workspace: Workspace, agent: string, text: string): Promise<void> {
  await herdr(workspace, ["agent", "prompt", agent, text]);
}

/** Session ids the container is still using: an agent Herdr tracks, or a process naming the id. */
export async function openSessions(workspace: Workspace): Promise<(id: string) => boolean> {
  // The shell mode runs no Herdr; the process list still catches agents started in its tmux session.
  const tracked = workspace.ui === "web" ? await agents(workspace) : [];
  const values = tracked.map((info) => info.agent_session?.value ?? "").filter(Boolean);
  const processes = (await capture(["docker", "exec", workspace.id, "ps", "-eo", "args="])).stdout;
  return (id) => values.some((value) => value.includes(id)) || processes.includes(id);
}

/** The workspace a session id is open in, if any: every workspace shares the home volume, so any of them can write it. */
export async function openAnywhere(): Promise<(id: string) => string | undefined> {
  const running = (await listWorkspaces()).filter((candidate) => candidate.state === "running");
  const checks = await Promise.all(running.map(async (workspace) => ({ project: workspace.project, isOpen: await openSessions(workspace) })));
  return (id) => checks.find((check) => check.isOpen(id))?.project;
}

export interface ContainerFile {
  agent: SessionAgentKind;
  /** relative to the agent's folder */
  file: string;
  sha256: string;
  size: number;
  modified: number;
  /** set on transcripts: the session's id and directory */
  id?: string;
  cwd?: string;
}

/**
 * One pass over the container's session folders for this repo. Claude's folders are picked by name and their
 * transcripts by the directory they record; Codex rollouts by the directory in their first line.
 */
const LIST_SCRIPT = String.raw`
set -u
repo="$1" prefix="$2"
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(sha256sum "$3" | cut -d' ' -f1)" "$(stat -c %s "$3")" "$(stat -c %Y "$3")" "$4" "$5"; }
cd /home/agent/.claude 2>/dev/null && for dir in projects/"$prefix" projects/"$prefix"-*; do
  [ -d "$dir" ] || continue
  find "$dir" -type f ! -name '*.bak' | while read -r file; do
    case "$file" in
      "$dir"/*/*) emit claude "$file" "$file" "" "" ;;
      *.jsonl)
        id="$(basename "$file" .jsonl)"
        cwd="$(head -n 50 "$file" | jq -r 'select(type == "object" and (.cwd | type) == "string") | .cwd' 2>/dev/null | head -n 1)"
        emit claude "$file" "$file" "$id" "$cwd" ;;
    esac
  done
done
cd /home/agent/.codex 2>/dev/null && find sessions -type f -name 'rollout-*.jsonl' 2>/dev/null | while read -r file; do
  meta="$(head -n 1 "$file" | jq -r 'select(.type == "session_meta") | [.payload.id, .payload.cwd] | @tsv' 2>/dev/null)"
  [ -n "$meta" ] || continue
  emit codex "$file" "$file" "$(printf '%s' "$meta" | cut -f1)" "$(printf '%s' "$meta" | cut -f2)"
done
exit 0
`;

export async function containerFiles(workspace: Workspace): Promise<ContainerFile[]> {
  const listing = await exec(workspace, ["sh", "-c", LIST_SCRIPT, "sh", workspace.repo, claudeProjectDir(workspace.repo)]);
  const files: ContainerFile[] = [];
  for (const line of listing.split("\n")) {
    const [agent, file, sha256, size, modified, id, cwd] = line.split("\t");
    if ((agent !== "claude" && agent !== "codex") || !file || !sha256) continue;
    files.push({ agent, file, sha256, size: Number(size), modified: Number(modified) * 1000, id: id || undefined, cwd: cwd || undefined });
  }
  return files;
}

/**
 * Whether go-remote pull may write a path the container listed onto the laptop: a plain relative path in the agent's
 * session folders for this repo. An agent in the container can name files so that the listing says anything.
 */
export function pullable(agent: SessionAgentKind, file: string, repo: string): boolean {
  const parts = file.split("/");
  if (hasControl(file) || parts.some((part) => part === "" || part === "." || part === "..")) return false;
  if (agent === "codex") return parts[0] === "sessions" && parts.length >= 2 && /^rollout-.+\.jsonl(\.zst)?$/.test(parts.at(-1) ?? "");
  const prefix = claudeProjectDir(repo);
  const dir = parts[1] ?? "";
  return parts[0] === "projects" && parts.length >= 3 && (dir === prefix || dir.startsWith(`${prefix}-`));
}

/** Whether a listed transcript is the file its session id names, so one session cannot claim another's. */
function namesSession(file: ContainerFile, id: string): boolean {
  const parts = file.file.split("/");
  const name = parts.at(-1) ?? "";
  if (file.agent === "claude") return parts.length === 3 && name === `${id}.jsonl`;
  return name.endsWith(`-${id}.jsonl`) || name.endsWith(`-${id}.jsonl.zst`);
}

export interface ContainerSession {
  agent: SessionAgentKind;
  id: string;
  cwd: string;
  files: ContainerFile[];
}

/** Container sessions for this repo, each with every file that belongs to it. */
export function groupSessions(files: ContainerFile[], repo: string): ContainerSession[] {
  const sessions = new Map<string, ContainerSession>();
  for (const file of files) {
    const { id, cwd } = file;
    if (!id || !cwd || !isSessionId(id) || hasControl(cwd) || !within(cwd, repo)) continue;
    if (!pullable(file.agent, file.file, repo) || !namesSession(file, id)) continue;
    sessions.set(`${file.agent}:${id}`, { agent: file.agent, id, cwd, files: [file] });
  }
  for (const file of files) {
    if (file.agent !== "claude" || file.id || !pullable("claude", file.file, repo)) continue;
    // projects/<dir>/<id>/... belongs to projects/<dir>/<id>.jsonl
    const [, dir, id, ...inside] = file.file.split("/");
    const session = id && inside.length > 0 ? sessions.get(`claude:${id}`) : undefined;
    if (session && session.files[0]?.file === `projects/${dir}/${id}.jsonl`) session.files.push(file);
  }
  return [...sessions.values()];
}

/**
 * What go-remote pull does with one container file. The laptop's copy is kept when it is the same, or when the
 * container's is an older prefix of it: the session went on here after the last pull.
 */
export function pullState(laptop: Uint8Array | undefined, container: { size: number; sha256: string }): "copy" | "same" | "ahead" {
  if (!laptop) return "copy";
  const state = compareCopy(laptop, container);
  return state === "same" ? "same" : state === "older" ? "ahead" : "copy";
}

export function hostCopy(store: string, file: string): Uint8Array | undefined {
  const path = join(store, file);
  return existsSync(path) ? new Uint8Array(readFileSync(path)) : undefined;
}

export async function fetchFile(workspace: Workspace, agent: SessionAgentKind, file: string): Promise<Uint8Array> {
  return outputBytes(["docker", "exec", workspace.id, "cat", `${CONTAINER_STORES[agent]}/${file}`]);
}

export function requireWeb(workspace: Workspace, what: string): void {
  if (workspace.ui !== "web") {
    throw new UserError(`${what} needs the web mode`, "This workspace runs with GR_UI=shell; set GR_UI=web in .env and start it again.");
  }
}
