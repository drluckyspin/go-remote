#!/usr/bin/env bun
/** go-remote: start hardened workspaces, hand agent sessions to them, and open them on a phone. */
import { parseArgs, type ParseArgsConfig } from "node:util";
import pkg from "../../package.json" with { type: "json" };
import { doctor } from "./commands/doctor.ts";
import { login } from "./commands/login.ts";
import { saveRoot } from "./config.ts";
import { pull, sessions } from "./commands/sessions.ts";
import { installPreferredSkill, installSkill } from "./commands/skill.ts";
import { start } from "./commands/start.ts";
import { attach, logs, ls, qr, stop } from "./commands/workspaces.ts";
import type { View } from "./link.ts";
import { finishMove, type MovePlan } from "./move.ts";
import type { AgentKind } from "./sessions.ts";
import { ui, UserError } from "./ui.ts";

const dim = process.stdout.isTTY === true && !process.env.NO_COLOR ? (text: string) => `\x1b[2m${text}\x1b[0m` : (text: string) => text;
const HELP_COLUMN = 40;

type HelpRow = readonly [usage: string, ...description: string[]];

function helpRows(rows: readonly HelpRow[]): string {
  return rows.map(([usage, ...description]) => {
    const prefix = `  ${usage}`;
    const continuation = " ".repeat(HELP_COLUMN);
    return description.map((line, index) => `${index === 0 ? prefix.padEnd(HELP_COLUMN) : continuation}${dim(line)}`).join("\n");
  }).join("\n");
}

const HELP = `go-remote: hardened coding-agent workspaces for your repos, on your phone over BitBang

Usage: go-remote <command> [options]   (gr for short)

Commands:
${helpRows([
  ["start [path]", "Start (or reuse) the workspace for a repo and show its QR code."],
  ["  --agent claude|codex|cursor", "Start an agent in a new tab, on a new conversation."],
  ["  --resume <agent:id>", "Move a session from this computer there (go-remote sessions lists them). Run from inside that session,", "by /go-remote; it moves once the turn ends, the session here closes, and the QR code opens in a window."],
  ["  --fork", "Continue a copy of it, so the laptop's can carry on too."],
  ["  --brief <file>", "Give the agent a handoff brief (copied to .go-remote/handoff.md in the repo)."],
  ["  --open chat|terminal", "What the phone opens (default: chat with an agent, else the terminal)."],
  ["login [claude|codex|cursor] [path]", "Sign Claude Code (default), Codex or Cursor in, once for every workspace. Claude Code signs in here,", "with claude setup-token, and go-remote keeps the token in .env; Codex, Cursor (or Claude Code when it is not", "installed here) sign in inside the container."],
  ["qr [path]", "Show a fresh QR code for a workspace (--open, --pane <id>)."],
  ["list", "List workspaces, their health and their agents."],
  ["sessions [path]", "List the Claude Code and Codex sessions on this computer that ran in a repo."],
  ["pull [path] [agent:id]", "Copy the container's sessions for a repo back to this computer."],
  ["attach [path]", "Open the workspace's Herdr terminal UI here (--shell for the tmux shell)."],
  ["logs [path]", "Show a workspace's logs with its URL taken out (--no-follow, --tail <n>)."],
  ["stop [path]", "Stop a workspace: the one for the repo you are in, else, after asking, every one (--all asks too,", "--yes skips the question). Logins stay in the home volume."],
  ["doctor", "Check Docker, the image, .env and the agent CLIs on this computer."],
  ["install-skill", "Install the /go-remote skill for Claude Code, Codex and Cursor (--embedded: the copy built into", "this go-remote, without offering skills.sh's)."],
  ["setup --root <dir>", "Remember the go-remote checkout (make install-cli runs this)."],
])}

Options:
${helpRows([
  ["--json", "Machine-readable output. The link is never printed: the QR code opens in a window instead,", "as it does whenever stdout is not a terminal."],
  ["--no-qr", "Print the link without drawing the QR code."],
  ["--no-window", "Never open a window for the QR code."],
  ["--root <dir>", "The go-remote checkout (default: GR_ROOT, then the one make install-cli recorded)."],
])}

The path defaults to the current directory for start and sessions. The other commands take the workspace for the repo
you are in, else the only one (stop: else all of them), and otherwise need the repo's path or the workspace's name, as
go-remote list shows it: go-remote stop /path/to/repo.
`;

const LINK_OPTIONS = {
  json: { type: "boolean" },
  "no-qr": { type: "boolean" },
  "no-window": { type: "boolean" },
} as const satisfies ParseArgsConfig["options"];

const ROOT_OPTION = { root: { type: "string" } } as const satisfies ParseArgsConfig["options"];

function parse<O extends NonNullable<ParseArgsConfig["options"]>>(args: string[], options: O) {
  try {
    return parseArgs({ args, options: { ...options, help: { type: "boolean", short: "h" } }, allowPositionals: true, strict: true });
  } catch (error) {
    throw new UserError(error instanceof Error ? error.message : String(error), "go-remote help lists the options.");
  }
}

function oneOf<T extends string>(name: string, value: string | undefined, allowed: readonly T[]): T | undefined {
  if (value === undefined) return undefined;
  if (!(allowed as readonly string[]).includes(value)) throw new UserError(`--${name} must be one of: ${allowed.join(", ")}`);
  return value as T;
}

function atMostOnePath(positionals: string[]): string | undefined {
  if (positionals.length > 1) throw new UserError(`Expected one path, got: ${positionals.join(" ")}`);
  return positionals[0];
}

function print(result: unknown): void {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

async function main(argv: string[]): Promise<number> {
  const [command = "help", ...rest] = argv;
  switch (command) {
    case "help":
    case "--help":
    case "-h":
      process.stdout.write(HELP);
      return 0;
    case "version":
    case "--version":
      process.stdout.write(`go-remote ${pkg.version}\n`);
      return 0;
    case "start": {
      const { values, positionals } = parse(rest, {
        ...LINK_OPTIONS,
        ...ROOT_OPTION,
        agent: { type: "string" },
        resume: { type: "string" },
        fork: { type: "boolean" },
        brief: { type: "string" },
        open: { type: "string" },
      });
      if (values.help) break;
      const result = await start({
        path: atMostOnePath(positionals),
        root: values.root,
        agent: oneOf<AgentKind>("agent", values.agent, ["claude", "codex", "cursor"]),
        resume: values.resume,
        fork: values.fork === true,
        brief: values.brief,
        open: oneOf<View>("open", values.open, ["chat", "terminal"]),
        json: values.json === true,
        qr: values["no-qr"] !== true,
        window: values["no-window"] !== true,
      });
      if (values.json) print(result);
      return 0;
    }
    case "qr": {
      const { values, positionals } = parse(rest, { ...LINK_OPTIONS, open: { type: "string" }, pane: { type: "string" } });
      if (values.help) break;
      const result = await qr({
        path: atMostOnePath(positionals),
        open: oneOf<View>("open", values.open, ["chat", "terminal"]),
        pane: values.pane,
        json: values.json === true,
        qr: values["no-qr"] !== true,
        window: values["no-window"] !== true,
      });
      if (values.json) print(result);
      return 0;
    }
    case "login": {
      const { values, positionals } = parse(rest, ROOT_OPTION);
      if (values.help) break;
      const agent = positionals.find((value): value is AgentKind => value === "claude" || value === "codex" || value === "cursor");
      await login({ path: atMostOnePath(positionals.filter((value) => value !== agent)), agent, root: values.root });
      return 0;
    }
    case "__move": {
      // the background half of a move that go-remote start began (see move.ts); not for people
      await finishMove(JSON.parse(rest[0] ?? "{}") as MovePlan);
      return process.exitCode === 1 ? 1 : 0;
    }
    case "list": {
      const { values } = parse(rest, { json: { type: "boolean" } });
      if (values.help) break;
      const rows = await ls({ json: values.json === true });
      if (values.json) print(rows);
      return 0;
    }
    case "sessions": {
      const { values, positionals } = parse(rest, { json: { type: "boolean" } });
      if (values.help) break;
      const rows = await sessions({ path: atMostOnePath(positionals), json: values.json === true });
      if (values.json) print(rows);
      return 0;
    }
    case "pull": {
      const { values, positionals } = parse(rest, { json: { type: "boolean" } });
      if (values.help) break;
      const ref = positionals.find((value) => /^(claude|codex):/.test(value));
      const rows = await pull({
        path: atMostOnePath(positionals.filter((value) => value !== ref)),
        ref,
        json: values.json === true,
      });
      if (values.json) print(rows);
      return 0;
    }
    case "attach": {
      const { values, positionals } = parse(rest, { shell: { type: "boolean" } });
      if (values.help) break;
      return attach({ path: atMostOnePath(positionals), shell: values.shell === true });
    }
    case "logs": {
      const { values, positionals } = parse(rest, { "no-follow": { type: "boolean" }, tail: { type: "string" } });
      if (values.help) break;
      if (values.tail !== undefined && !/^(\d+|all)$/.test(values.tail)) throw new UserError("--tail takes a number of lines, or all");
      return logs({ path: atMostOnePath(positionals), follow: values["no-follow"] !== true, tail: values.tail ?? "100" });
    }
    case "stop": {
      const { values, positionals } = parse(rest, { ...ROOT_OPTION, all: { type: "boolean" }, yes: { type: "boolean" } });
      if (values.help) break;
      await stop({ path: atMostOnePath(positionals), all: values.all === true, yes: values.yes === true, root: values.root });
      return 0;
    }
    case "doctor": {
      const { values } = parse(rest, { ...ROOT_OPTION, json: { type: "boolean" } });
      if (values.help) break;
      const result = await doctor({ json: values.json === true, root: values.root });
      if (values.json) print(result);
      return result.ok ? 0 : 1;
    }
    case "install-skill": {
      const { values } = parse(rest, { embedded: { type: "boolean" } });
      if (values.help) break;
      if (values.embedded) installSkill();
      else await installPreferredSkill();
      return 0;
    }
    case "setup": {
      const { values } = parse(rest, ROOT_OPTION);
      if (values.help) break;
      if (!values.root) throw new UserError("go-remote setup needs --root <dir>, the go-remote checkout");
      const saved = saveRoot(values.root);
      ui.success(`Recorded ${saved.root} in ${saved.file}`);
      return 0;
    }
    default:
      throw new UserError(`Unknown command: ${command}`, "go-remote help lists the commands.");
  }
  process.stdout.write(HELP);
  return 0;
}

/**
 * A compiled go-remote is the Bun runtime, which on macOS uploads a report of its own crashes unless DO_NOT_TRACK is
 * in the environment it starts with. Without it, go-remote runs itself again with it set, passing on the terminal,
 * the exit code, and any signal sent to this process alone.
 */
async function rerunUntracked(): Promise<number | undefined> {
  if (process.env.DO_NOT_TRACK || process.platform !== "darwin" || !Bun.main.startsWith("/$bunfs/")) return undefined;
  const child = Bun.spawn([process.execPath, ...process.argv.slice(2)], {
    env: { ...process.env, DO_NOT_TRACK: "1" },
    stdio: ["inherit", "inherit", "inherit"],
  });
  // Ctrl+C reaches the child from the terminal itself; this process only has to outlive it
  process.on("SIGINT", () => {});
  for (const signal of ["SIGTERM", "SIGHUP"] as const) process.on(signal, () => child.kill(signal));
  await child.exited;
  return child.exitCode ?? 1;
}

try {
  process.exitCode = (await rerunUntracked()) ?? (await main(process.argv.slice(2)));
} catch (error) {
  if (error instanceof UserError) {
    ui.error(error.message);
    if (error.hint) ui.dim(error.hint);
  } else {
    ui.error(error instanceof Error ? error.message : String(error));
    if (process.env.GR_DEBUG && error instanceof Error && error.stack) ui.dim(error.stack);
  }
  process.exitCode = 1;
}
