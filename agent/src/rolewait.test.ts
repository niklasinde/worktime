import assert from "node:assert/strict";
import test from "node:test";
import { RoleWaits, timeoutMessage, type Timers } from "./rolewait.js";

/// Timers that run when the test says so.
function fakeTimers() {
  const scheduled = new Map<number, { run: () => void; ms: number }>();
  let next = 0;
  const timers: Timers = {
    set: (run, ms) => { scheduled.set(++next, { run, ms }); return next; },
    clear: (timer) => { scheduled.delete(timer as number); },
  };
  return { timers, scheduled, fire: (id: number) => scheduled.get(id)?.run() };
}

test("an answer resumes the waiting call and stops its timer", async () => {
  const { timers, scheduled } = fakeTimers();
  const waits = new RoleWaits(timers);
  const answer = waits.ask("1", "mcp__worktime__jira_issue", 30 * 60 * 1000);
  assert.equal(scheduled.size, 1);
  assert.equal(scheduled.get(1)?.ms, 1_800_000);
  assert.equal(waits.answer("1", { allow: true, add: true, session: false }), true);
  assert.deepEqual(await answer, { allow: true, add: true, session: false });
  assert.equal(scheduled.size, 0, "the timer is cleared");
  assert.equal(waits.answer("1", { allow: false, add: false, session: false }), false, "answered once");
});

test("an unattended wait ends after its limit as a denial that says nobody answered", async () => {
  const { timers, fire } = fakeTimers();
  const waits = new RoleWaits(timers);
  let told = 0;
  const answer = waits.ask("7", "mcp__worktime__jira_issue", 1000, () => told++);
  fire(1);
  const result = await answer;
  assert.equal(result.allow, false);
  assert.equal(result.timedOut, true);
  assert.equal(result.message, timeoutMessage("mcp__worktime__jira_issue"));
  assert.equal(told, 1, "the app is told");
  assert.equal(waits.size, 0);
});

test("an answer that comes after the limit is ignored", async () => {
  const { timers, fire } = fakeTimers();
  const waits = new RoleWaits(timers);
  const answer = waits.ask("2", "t", 500);
  fire(1);
  await answer;
  assert.equal(waits.answer("2", { allow: true, add: true, session: false }), false);
});

test("an interactive wait has no limit, and stopping the agent denies every waiting question", async () => {
  const { timers, scheduled } = fakeTimers();
  const waits = new RoleWaits(timers);
  const a = waits.ask("1", "a", undefined);
  const b = waits.ask("2", "b", 0);
  assert.equal(scheduled.size, 0);
  waits.denyAll("The user stopped the agent.");
  assert.deepEqual(await a, { allow: false, add: false, session: false, message: "The user stopped the agent." });
  assert.equal((await b).allow, false);
  assert.equal(waits.size, 0);
});
