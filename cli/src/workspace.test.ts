import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compose, pickWorkspace, projectName, relayForced, reservedConflict, resolveRepo, stopTargets, uiMode, type Workspace } from "./workspace.ts";

test("compose reads its settings from the env file GR_ENV_FILE picks, when it exists", () => {
  const root = mkdtempSync(join(tmpdir(), "go-remote-compose-"));
  const saved = process.env.GR_ENV_FILE;
  try {
    process.env.GR_ENV_FILE = "throwaway.env";
    expect(compose(root, "go-remote-app")).not.toContain("--env-file");
    writeFileSync(join(root, "throwaway.env"), "GR_UI=shell\n");
    const args = compose(root, "go-remote-app");
    expect(args.slice(args.indexOf("--env-file"), args.indexOf("--env-file") + 2)).toEqual(["--env-file", join(root, "throwaway.env")]);
  } finally {
    if (saved === undefined) delete process.env.GR_ENV_FILE;
    else process.env.GR_ENV_FILE = saved;
  }
});

test("uiMode reads GR_UI as the entrypoint does, and an image without it as the shell", () => {
  expect(uiMode(["PATH=/usr/bin", "GR_UI=web"])).toBe("web");
  expect(uiMode(["GR_UI=Shell"])).toBe("shell");
  expect(uiMode(["PATH=/usr/bin"])).toBe("shell");
});

test("relayForced is off only for GR_RELAY=auto", () => {
  expect(relayForced(["GR_RELAY=force"])).toBe(true);
  expect(relayForced(["GR_RELAY=Auto"])).toBe(false);
  expect(relayForced(["PATH=/usr/bin"])).toBe(true);
});

describe("projectName", () => {
  test("matches Common.make's tr pipeline", () => {
    expect(projectName("/Users/me/src/My Repo.v2")).toBe("go-remote-my-repo-v2");
    expect(projectName("/Users/me/src/my_repo")).toBe("go-remote-my_repo");
    // tr works on bytes: é is two of them
    expect(projectName("/Users/me/src/café")).toBe("go-remote-caf--");
  });
});

describe("reservedConflict", () => {
  test("refuses paths that cover or land inside the container's own", () => {
    expect(reservedConflict("/usr/local/src/app")).toBe("/usr");
    expect(reservedConflict("/home/agent")).toBe("/home/agent");
    expect(reservedConflict("/home")).toBe("/home/agent");
    expect(reservedConflict("/tmp")).toBe("/tmp/go-remote");
    expect(reservedConflict("/workspace/app")).toBe("/workspace");
  });

  test("allows ordinary checkouts", () => {
    for (const path of ["/Users/me/src/app", "/home/todd/src/app", "/tmp/app", "/private/var/folders/x/T/repo", "/srv/app"]) {
      expect(reservedConflict(path)).toBeUndefined();
    }
  });
});

describe("resolveRepo", () => {
  test("resolves symlinks and spots a repo", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "go-remote-repo-")));
    mkdirSync(join(dir, ".git"));
    expect(resolveRepo(dir)).toEqual({ path: dir, isGit: true });
  });

  test("refuses a worktree, whose .git points outside the mount", () => {
    const dir = mkdtempSync(join(tmpdir(), "go-remote-worktree-"));
    writeFileSync(join(dir, ".git"), "gitdir: /elsewhere/.git/worktrees/x\n");
    expect(() => resolveRepo(dir)).toThrow("worktree");
  });

  test("refuses what does not exist, and the home directory", () => {
    expect(() => resolveRepo("/nonexistent/go-remote")).toThrow("does not exist");
    expect(() => resolveRepo("~")).toThrow("Refusing to mount");
  });
});

describe("pickWorkspace", () => {
  const workspace = (repo: string): Workspace => ({
    id: repo,
    project: projectName(repo),
    repo,
    state: "running",
    health: "healthy",
    ui: "web",
    relay: true,
  });

  test("finds a workspace by its name, even when its repo has gone", () => {
    const moved = workspace("/nonexistent/src/old-name");
    const other = workspace(realpathSync(mkdtempSync(join(tmpdir(), "go-remote-pick-"))));
    expect(pickWorkspace([moved, other], "go-remote-old-name")).toBe(moved);
    expect(pickWorkspace([moved, other], other.project)).toBe(other);
  });

  test("still finds one by its repo path", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "go-remote-pick-")));
    const found = workspace(dir);
    expect(pickWorkspace([workspace("/nonexistent/src/a"), found], dir)).toBe(found);
    expect(pickWorkspace([workspace("/nonexistent/src/a")], "/nonexistent/src/a").repo).toBe("/nonexistent/src/a");
  });

  test("names an unknown workspace as such, and asks for one when several exist", () => {
    const both = [workspace("/nonexistent/src/a"), workspace("/nonexistent/src/b")];
    expect(() => pickWorkspace(both, "go-remote-c")).toThrow("No workspace named go-remote-c");
    expect(() => pickWorkspace(both, undefined, tmpdir())).toThrow("Several workspaces exist");
    expect(pickWorkspace(both.slice(0, 1), undefined, tmpdir()).repo).toBe("/nonexistent/src/a");
  });

  test("with no target, picks the workspace for the repo the current directory is in", () => {
    const outer = realpathSync(mkdtempSync(join(tmpdir(), "go-remote-pick-")));
    const inner = join(outer, "vendor", "lib");
    mkdirSync(join(inner, "src"), { recursive: true });
    const outerWorkspace = workspace(outer);
    const innerWorkspace = workspace(inner);
    const all = [workspace("/nonexistent/src/a"), outerWorkspace, innerWorkspace];
    expect(pickWorkspace(all, undefined, outer)).toBe(outerWorkspace);
    expect(pickWorkspace(all, undefined, join(outer, "vendor"))).toBe(outerWorkspace);
    expect(pickWorkspace(all, undefined, join(inner, "src"))).toBe(innerWorkspace);
    expect(() => pickWorkspace(all, undefined, tmpdir())).toThrow("Several workspaces exist");
  });

  test("does not take a sibling whose path merely starts the same", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "go-remote-pick-")));
    mkdirSync(join(dir, "app-two"));
    const both = [workspace(join(dir, "app")), workspace(join(dir, "other"))];
    expect(() => pickWorkspace(both, undefined, join(dir, "app-two"))).toThrow("Several workspaces exist");
  });

  test("stopTargets: the repo's own workspace inside it, else all of them, asking before stopping several", () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "go-remote-stop-")));
    const here = workspace(dir);
    const all = [workspace("/nonexistent/src/a"), here, workspace("/nonexistent/src/b")];
    expect(stopTargets(all, { all: false }, dir)).toEqual({ targets: [here], ask: false });
    expect(stopTargets(all, { target: "go-remote-a", all: false }, dir)).toEqual({ targets: all.slice(0, 1), ask: false });
    expect(stopTargets(all, { all: false }, tmpdir())).toEqual({ targets: all, ask: true });
    expect(stopTargets(all.slice(0, 1), { all: false }, tmpdir())).toEqual({ targets: all.slice(0, 1), ask: false });
    expect(stopTargets(all, { all: true }, dir)).toEqual({ targets: all, ask: true });
    expect(stopTargets(all.slice(0, 1), { all: true }, dir)).toEqual({ targets: all.slice(0, 1), ask: true });
    expect(stopTargets([], { all: false }, tmpdir())).toEqual({ targets: [], ask: false });
    expect(stopTargets([], { all: true }, tmpdir())).toEqual({ targets: [], ask: false });
  });
});
