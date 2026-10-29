/** go-remote qr, ls, attach, logs and stop: working with workspaces that already exist. */
import { resolveRoot } from "../config.ts";
import { agents, defaultAgent, linkTarget, mainPane } from "../handoff.ts";
import { redact, type View } from "../link.ts";
import { type LinkOptions, showLink } from "../present.ts";
import { inherit } from "../proc.ts";
import { confirm, printable, ui, UserError } from "../ui.ts";
import { attach as attachTo, checkDocker, compose, findWorkspace, listWorkspaces, requireRunning, stopTargets, waitForListener } from "../workspace.ts";

export async function qr(options: LinkOptions & { path?: string; open?: View; pane?: string }): Promise<Record<string, unknown>> {
  await checkDocker();
  const workspace = await findWorkspace(options.path);
  requireRunning(workspace);
  const url = await waitForListener(workspace);
  let pane = options.pane;
  let view: View = options.open ?? "terminal";
  if (workspace.ui === "web" && pane === undefined) {
    ({ pane, view } = linkTarget(await defaultAgent(workspace), (await mainPane(workspace))?.pane_id, options.open));
  }
  const shown = await showLink(workspace, url, { pane, view }, options);
  return { project: workspace.project, repo: workspace.repo, ui: workspace.ui, ...(pane ? { pane, view } : {}), ...shown };
}

export async function ls(options: { json: boolean }): Promise<Record<string, unknown>[] | undefined> {
  await checkDocker();
  const rows = [];
  for (const workspace of await listWorkspaces()) {
    let running: string[] = [];
    if (workspace.state === "running" && workspace.ui === "web") {
      running = await agents(workspace)
        .then((list) => list.map((info) => `${info.name ?? info.agent ?? "agent"} (${info.agent_status})`))
        .catch(() => []);
    }
    rows.push({
      project: workspace.project,
      repo: workspace.repo,
      state: workspace.state,
      health: workspace.health,
      ui: workspace.ui,
      agents: running,
    });
  }
  if (options.json) return rows;
  if (rows.length === 0) {
    ui.infoDim("No workspaces. Start one with: go-remote start /path/to/repo");
    return undefined;
  }
  for (const row of rows) {
    const status = row.state !== "running"
      ? `not running (${row.state})`
      : row.health === "healthy"
      ? "running; BitBang listener registered"
      : row.health === "starting"
      ? "starting"
      : "running, but the listener failed its last check (the watchdog restarts it)";
    process.stdout.write(`${row.project}\n  ${row.repo}\n  ${status}, ${row.ui} mode\n`);
    if (row.agents.length > 0) process.stdout.write(`  agents: ${row.agents.map(printable).join(", ")}\n`);
  }
  return undefined;
}

export async function attach(options: { path?: string; shell: boolean }): Promise<number> {
  await checkDocker();
  const workspace = await findWorkspace(options.path);
  requireRunning(workspace);
  if (process.stdin.isTTY !== true) throw new UserError("go-remote attach needs an interactive terminal");
  return attachTo(workspace, [options.shell ? "go-remote-session" : "go-remote-attach"]);
}

/** Follows the container's logs with BitBang URLs and connection ids taken out: go-remote qr shows the way in. */
export async function logs(options: { path?: string; follow: boolean; tail: string }): Promise<number> {
  await checkDocker();
  const workspace = await findWorkspace(options.path);
  const child = Bun.spawn(["docker", "logs", ...(options.follow ? ["-f"] : []), "--tail", options.tail, workspace.id], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const pump = async (stream: ReadableStream<Uint8Array>, out: NodeJS.WriteStream) => {
    const decoder = new TextDecoder();
    let pending = "";
    for await (const chunk of stream) {
      pending += decoder.decode(chunk, { stream: true });
      const lines = pending.split("\n");
      pending = lines.pop() ?? "";
      for (const line of lines) out.write(`${redact(line)}\n`);
    }
    if (pending) out.write(`${redact(pending)}\n`);
  };
  const stop = () => child.kill();
  process.on("SIGINT", stop);
  await Promise.all([pump(child.stdout, process.stdout), pump(child.stderr, process.stderr)]);
  process.off("SIGINT", stop);
  return child.exited;
}

export async function stop(options: { path?: string; all: boolean; yes: boolean; root?: string }): Promise<void> {
  await checkDocker();
  const root = resolveRoot(options.root);
  const { targets, ask } = stopTargets(await listWorkspaces(), { target: options.path, all: options.all });
  if (targets.length === 0) {
    ui.infoDim("No workspaces to stop.");
    return;
  }
  if (ask && !options.yes) {
    const names = targets.map((workspace) => workspace.project).join(", ");
    if (process.stdin.isTTY !== true || process.stderr.isTTY !== true) {
      throw new UserError(`Not stopping ${names} without asking`, "Pass --yes to stop them, or name one: go-remote stop ~/src/my-repo");
    }
    const what = targets.length === 1 ? names : `all ${targets.length} workspaces (${names})`;
    if (!(await confirm(`Stop ${what}? Their phone sessions end.`))) {
      ui.infoDim("Nothing stopped.");
      return;
    }
  }
  for (const workspace of targets) {
    ui.info(`Stopping ${workspace.project}`);
    const code = await inherit([...compose(root, workspace.project), "down", "--remove-orphans"], {
      stdoutToStderr: true,
      env: { GR_REPO: workspace.repo },
    });
    if (code !== 0) throw new UserError(`docker compose could not stop ${workspace.project}`);
  }
}
