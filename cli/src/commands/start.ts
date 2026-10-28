/**
 * go-remote start: brings up the workspace for a repo, optionally hands it an agent session from the laptop, and
 * shows the phone the way in.
 */
import { copyFileSync, mkdirSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { resolveRoot } from "../config.ts";
import { checkEnv } from "../env.ts";
import { agentReady, checkCopyIn, containerModel, copyIn, linkTarget, mainPane, prompt, requireWeb, settledDefaultAgent, startAgent } from "../handoff.ts";
import { keepAwake, onBattery } from "../host.ts";
import type { View } from "../link.ts";
import { type AgentProcess, callingAgent, inTurn, movePending, otherSession, spawnMove } from "../move.ts";
import { interactive, type LinkOptions, showLink } from "../present.ts";
import { capture } from "../proc.ts";
import {
  AGENT_NAMES,
  type AgentKind,
  findHostSession,
  hostStores,
  parseSessionRef,
  resumeArgs,
  type Session,
  type SessionRef,
  within,
} from "../sessions.ts";
import { confirm, ui, UserError } from "../ui.ts";
import { hostVersion, PIN_LABELS, skewWarning } from "../versions.ts";
import {
  checkDocker,
  composeUp,
  imageLabels,
  IMAGE,
  listWorkspaces,
  projectName,
  resolveRepo,
  waitForListener,
  type Workspace,
} from "../workspace.ts";
import { hostClaude, saveClaudeToken, signIn } from "./login.ts";

export interface StartOptions extends LinkOptions {
  path?: string;
  root?: string;
  agent?: AgentKind;
  resume?: string;
  fork: boolean;
  brief?: string;
  open?: View;
}

/** A transcript written to this recently may still be open on the laptop. */
const LIVE_MS = 60_000;
const BRIEF = ".go-remote/handoff.md";

async function uncommitted(repo: string): Promise<number> {
  const status = await capture(["git", "-C", repo, "status", "--porcelain"]);
  return status.code === 0 ? status.stdout.split("\n").filter(Boolean).length : 0;
}

/**
 * The session to hand over, after the checks that keep it to one writer. `moving` is a session still in the
 * turn that runs go-remote: its own agent asked for the move, and the move waits for that turn to end.
 */
async function sessionToHand(
  ref: SessionRef,
  repo: string,
  fork: boolean,
): Promise<{ session: Session; moving: boolean; caller?: AgentProcess }> {
  const session = findHostSession(ref);
  if (!session) {
    throw new UserError(`No ${AGENT_NAMES[ref.agent]} session ${ref.id} on this computer`, `go-remote sessions ${repo} lists them.`);
  }
  if (!session.cwd || !within(session.cwd, repo)) {
    throw new UserError(
      `That session ran in ${session.cwd ?? "an unknown directory"}, outside ${repo}`,
      "Start the workspace for the repo it belongs to.",
    );
  }
  if (fork) return { session, moving: false };
  if (inTurn(session, LIVE_MS)) {
    if (movePending(ref)) throw new UserError("This session is already moving", "Its QR code opens once the reply that started the move ends.");
    // Only the session's own agent, running go-remote from inside the turn, is a process the move can end.
    const caller = await callingAgent(ref.agent);
    if (!caller || otherSession(ref)) {
      throw new UserError(
        `That ${AGENT_NAMES[ref.agent]} session is in the middle of a turn on this computer`,
        "Let the turn finish and quit it there, then run this again, or use --fork to continue a copy.",
      );
    }
    return { session, moving: true, caller };
  }
  if (Date.now() - session.modified < LIVE_MS) {
    ui.warn(`The session changed in the last minute, so it may still be open on the laptop. Two copies writing to one ${AGENT_NAMES[ref.agent]} session interleave.`);
    if (!(await confirm("Quit it on the laptop first. Continue anyway?"))) {
      throw new UserError("Not handing over a session that may still be open", "Quit it on the laptop, or use --fork to continue a copy.");
    }
  }
  return { session, moving: false };
}

/**
 * Offers, on a terminal, to sign an agent in now. Claude Code signs in on this computer when it is installed
 * here, and the workspace restarts to get the token. Returns the workspace once the agent is signed in; the
 * caller says what to do otherwise.
 */
async function offerSignIn(
  root: string,
  workspace: Workspace,
  agent: AgentKind,
  options: LinkOptions,
  handingOff: boolean,
): Promise<Workspace | undefined> {
  if (!interactive(options) || !(await confirm(`Sign in to ${AGENT_NAMES[agent]} now?`, true))) return undefined;
  if (agent === "claude" && hostClaude()) {
    if (!(await saveClaudeToken(root))) return undefined;
    ui.info(`Restarting ${workspace.project} with the token`);
    return composeUp(root, workspace.repo, workspace.project, { handingOff, recreate: true });
  }
  if (await signIn(workspace, agent)) return workspace;
  ui.warn(`${AGENT_NAMES[agent]} is not signed in.`);
  return undefined;
}

/** With `handingOff`, the container starts no default agent: go-remote starts the one asked for. */
async function bringUp(root: string, repo: string, project: string, handingOff: boolean): Promise<Workspace> {
  const existing = (await listWorkspaces()).find((workspace) => workspace.project === project);
  if (existing && existing.repo !== repo) {
    throw new UserError(`${project} already serves ${existing.repo}`, `Stop it first: go-remote stop ${existing.repo}`);
  }
  if (existing?.state === "running") {
    ui.infoDim(`${project} is already running`);
    return existing;
  }
  ui.info(`Starting ${project} for ${repo}`);
  return composeUp(root, repo, project, { handingOff });
}

/** Writes the handoff brief into the repo, where the container sees it (.go-remote/ is excluded from git there). */
function placeBrief(repo: string, brief: string): void {
  const target = join(repo, BRIEF);
  mkdirSync(join(repo, ".go-remote"), { recursive: true });
  let same = false;
  try {
    same = realpathSync(brief) === realpathSync(target);
  } catch {
    // the target does not exist yet
  }
  if (!same) copyFileSync(brief, target);
}

export async function start(options: StartOptions): Promise<Record<string, unknown>> {
  const root = resolveRoot(options.root);
  const { path: repo, isGit } = resolveRepo(options.path ?? process.cwd());
  const ref = options.resume ? parseSessionRef(options.resume) : undefined;
  if (ref && options.agent && options.agent !== ref.agent) {
    throw new UserError(`--agent ${options.agent} does not match the ${ref.agent} session in --resume`);
  }
  if (options.fork && !ref) throw new UserError("--fork needs --resume");
  const agent = ref?.agent ?? options.agent ?? (options.brief ? "claude" : undefined);
  const { session, moving, caller } = ref ? await sessionToHand(ref, repo, options.fork) : { session: undefined, moving: false, caller: undefined };

  await checkDocker();
  const labels = await imageLabels();
  if (!labels) throw new UserError(`Image ${IMAGE} not found`, "Build it with: make build");
  if (agent) {
    const warning = skewWarning(agent, await hostVersion(agent), labels[PIN_LABELS[agent]]);
    if (warning && ref) ui.warn(warning);
  }
  await checkEnv(root);
  if (!isGit) ui.warn(`${repo} is not a git repository; mounting it anyway`);

  const project = projectName(repo);
  let workspace = await bringUp(root, repo, project, agent !== undefined);
  await waitForListener(workspace);
  ui.success(`${project} is running; its BitBang listener is registered`);

  const changes = await uncommitted(repo);
  if (changes > 0) {
    ui.warn(`${repo} has ${changes} uncommitted change${changes === 1 ? "" : "s"}. The laptop and the container now share them; give each agent its own worktree to keep them apart.`);
  }

  let pane: string | undefined;
  let agentName: string | undefined;
  let defaultState: string | undefined;
  let view: View = options.open ?? (agent ? "chat" : "terminal");
  if (agent) {
    requireWeb(workspace, "Starting an agent");
    const ready = await agentReady(workspace, agent);
    if (!ready.ok) {
      if (moving) {
        throw new UserError(
          `${AGENT_NAMES[agent]} cannot work in the container yet: ${ready.reason}`,
          "The session stays here. Sign the container in with go-remote login, in a terminal, then move it again.",
        );
      }
      ui.warn(`${AGENT_NAMES[agent]} cannot work in the container yet: ${ready.reason}.`);
      const signedIn = await offerSignIn(root, workspace, agent, options, true);
      if (signedIn) workspace = signedIn;
      else ui.dim(`It opens signed out; sign it in with: go-remote login ${agent}`);
    }
    if (options.brief) placeBrief(repo, options.brief);
    if (moving && ref && session) {
      await checkCopyIn(workspace, session, hostStores());
      const log = spawnMove({
        root,
        project,
        repo,
        ref,
        transcript: session.transcript,
        agent: caller,
        ...(options.brief ? { brief: join(repo, BRIEF) } : {}),
        window: options.window,
      });
      ui.success(`${project} is ready. The session moves there once this turn ends; then its QR code opens in a window.`);
      return { project, repo, ui: workspace.ui, session: `${ref.agent}:${ref.id}`, moving: true, qr: "pending", log };
    }
    if (session) {
      await copyIn(workspace, session, hostStores());
      ui.success(`Copied ${AGENT_NAMES[session.agent]} session ${session.id} into the container`);
    }
    // a resumed session keeps the model its transcript records; a fresh agent starts on GR_MODEL, when it is set
    const model = ref ? undefined : await containerModel(workspace);
    if (model) ui.infoDim(`Starting ${AGENT_NAMES[agent]} on ${model}, as GR_MODEL says`);
    const started = await startAgent(workspace, agent, session?.cwd ?? repo, ref ? resumeArgs(ref, options.fork) : model ? ["--model", model] : []);
    pane = started.pane;
    agentName = started.name;
    if (started.ready) {
      ui.success(`${AGENT_NAMES[agent]} is running in the ${started.tab} tab${ref ? (options.fork ? ", on a copy of the session" : ", resuming the session") : ""}`);
      if (options.brief) {
        await prompt(workspace, started.name, `Read ${join(repo, BRIEF)} and continue the work it describes.`);
        ui.success("Gave it the handoff brief");
      }
    } else {
      ui.warn(`${AGENT_NAMES[agent]} was started in the ${started.tab} tab but is not ready for input yet; open its terminal view to see why.`);
    }
  } else if (workspace.ui === "web") {
    let current = await settledDefaultAgent(workspace);
    if (current.state === "waiting") {
      const awaited = current.agent ?? "claude";
      ui.warn("No agent is signed in in the container yet, so the phone's Chat has none to talk to.");
      const signedIn = await offerSignIn(root, workspace, awaited, options, false);
      if (signedIn) {
        workspace = signedIn;
        current = await settledDefaultAgent(workspace, { signedIn: true });
      }
      if (current.state === "waiting") ui.dim("Sign in once with make login (or go-remote login); the agent then starts on its own.");
    }
    if (current.state === "running" && current.agent) {
      ui.success(`${AGENT_NAMES[current.agent]} is ready in its own tab; the link opens its chat`);
    } else if (current.state === "failed") {
      ui.warn("The default agent did not start; open its tab on the phone to see why.");
    }
    const target = linkTarget(current, (await mainPane(workspace))?.pane_id, options.open);
    pane = target.pane;
    view = target.view;
    defaultState = current.state;
  }

  // a sign-in may have restarted the workspace, which gives it a new link
  const url = await waitForListener(workspace);
  const awake = await keepAwake(workspace.id);
  if (awake === "started") ui.dim("This Mac stays awake while the workspace runs.");
  if (awake !== "unsupported" && (await onBattery())) {
    ui.warn("The Mac is on battery: closing the lid still puts it to sleep, which drops the phone's connection.");
  }
  const shown = await showLink(workspace, url, { pane, view }, options);
  return {
    project,
    repo,
    ui: workspace.ui,
    ...(agentName ? { agent: agentName, kind: agent } : {}),
    ...(defaultState ? { default_agent: defaultState } : {}),
    ...(ref ? { session: `${ref.agent}:${ref.id}`, fork: options.fork } : {}),
    ...(pane ? { pane, view } : {}),
    ...shown,
  };
}
