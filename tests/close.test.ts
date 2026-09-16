import assert from "node:assert/strict";
import test from "node:test";

import { buildActivity, type Activity, type Listener } from "../src/core.ts";
import {
  executeClose,
  prepareClose,
  selectCloseTarget,
  verifyCloseTarget,
  type CloseDependencies,
  type CloseOptions,
} from "../src/close.ts";

const options: CloseOptions = { port: 3000, currentUid: 501, currentPid: 900 };

function activity(overrides: Partial<Listener> = {}, executablePath = "/opt/bin/node"): Activity {
  const listener: Listener = {
    pid: 42,
    command: "node",
    uid: 501,
    port: 3000,
    addresses: ["127.0.0.1"],
    ...overrides,
  };
  return buildActivity(listener, { pid: listener.pid, command: listener.command, executablePath });
}

function fakeDependencies(snapshots: Activity[][], startTimes = ["start-A", "start-A"]): {
  dependencies: CloseDependencies;
  signalled: number[];
} {
  let scanIndex = 0;
  let startIndex = 0;
  const signalled: number[] = [];
  let listening = true;

  return {
    signalled,
    dependencies: {
      scan: async () => ({ activities: snapshots[Math.min(scanIndex++, snapshots.length - 1)], limitations: [] }),
      listeners: async () =>
        listening
          ? [{ pid: 42, command: "node", uid: 501, port: 3000, addresses: ["127.0.0.1"] }]
          : [],
      startTime: async () => startTimes[Math.min(startIndex++, startTimes.length - 1)],
      signal: (pid) => {
        signalled.push(pid);
        listening = false;
      },
      wait: async () => {},
    },
  };
}

test("close refuses ambiguity until a PID is selected", () => {
  const first = activity();
  const second = activity({ pid: 43, addresses: ["[::1]"] });
  assert.throws(() => selectCloseTarget([first, second], options), /multiple owning PIDs/);
  assert.equal(selectCloseTarget([first, second], { ...options, pid: 43 }).activity.facts.process.pid, 43);
  assert.throws(() => selectCloseTarget([first], { ...options, pid: 43 }), /not listening/);
});

test("close refuses other users, unknown identity, own PID, system executables, and app processes", () => {
  assert.throws(() => selectCloseTarget([activity({ uid: 0 })], { ...options, currentUid: 0 }), /as root/);
  assert.throws(() => selectCloseTarget([activity({ uid: 502 })], options), /another user/);
  assert.throws(() => selectCloseTarget([activity({ uid: undefined })], options), /no verified user ID/);
  assert.throws(() => selectCloseTarget([activity({ pid: 900 })], options), /protected/);
  assert.throws(() => selectCloseTarget([activity({}, "/usr/libexec/exampled")], options), /operating-system/);
  assert.throws(
    () => selectCloseTarget([activity({}, "/Applications/Example.app/Contents/MacOS/Example")], options),
    /application bundle/,
  );
  const appChild = buildActivity(
    { pid: 42, command: "helper", uid: 501, port: 3000, addresses: ["127.0.0.1"] },
    { pid: 42, ppid: 10, command: "helper", executablePath: "/opt/bin/helper" },
    undefined,
    [{ pid: 10, command: "Example", executablePath: "/Applications/Example.app/Contents/MacOS/Example" }],
  );
  assert.throws(() => selectCloseTarget([appChild], options), /application bundle/);
});

test("close preview reports other ports owned by the same PID", async () => {
  const { dependencies, signalled } = fakeDependencies([[activity(), activity({ port: 4000 })]]);
  const plan = await prepareClose(options, dependencies);
  assert.deepEqual(plan.otherPorts, [4000]);
  assert.equal(plan.startTime, "start-A");
  assert.deepEqual(signalled, []);
});

test("close refuses a target when its start time is unavailable", async () => {
  const { dependencies, signalled } = fakeDependencies([[activity()]], [""]);
  await assert.rejects(prepareClose(options, dependencies), /no verified start time/);
  assert.deepEqual(signalled, []);
});

test("close aborts if the target changes identity or port ownership", async () => {
  const original = activity();
  const { dependencies, signalled } = fakeDependencies([[original]]);
  const plan = await prepareClose(options, dependencies);
  assert.throws(() => verifyCloseTarget(plan, [activity({ uid: 502 })], "start-A"), /changed identity/);
  assert.throws(() => verifyCloseTarget(plan, [activity()], "start-B"), /changed identity/);
  assert.throws(() => verifyCloseTarget(plan, [activity({}, "/opt/bin/python")], "start-A"), /changed identity/);
  assert.throws(() => verifyCloseTarget(plan, [], "start-A"), /no longer listens/);
  assert.throws(() => verifyCloseTarget(plan, [original, activity({ pid: 43 })], "start-A"), /new owning PID/);
  assert.deepEqual(signalled, []);
});

test("explicit --pid can close one of the original PIDs sharing a port", async () => {
  const first = activity();
  const second = activity({ pid: 43 });
  const { dependencies, signalled } = fakeDependencies([[first, second], [first, second]]);
  dependencies.listeners = async () => [
    { pid: 43, command: "node", uid: 501, port: 3000, addresses: ["[::1]"] },
  ];
  const plan = await prepareClose({ ...options, pid: 42 }, dependencies);
  assert.deepEqual(plan.peerPids, [43]);
  const result = await executeClose(plan, dependencies);
  assert.deepEqual(signalled, [42]);
  assert.deepEqual(result, { targetStoppedListening: true, portFree: false, remainingPids: [43] });
});

test("close signals only the verified PID and checks the listener afterward", async () => {
  const original = activity();
  const { dependencies, signalled } = fakeDependencies([[original], [original]]);
  const plan = await prepareClose(options, dependencies);
  const result = await executeClose(plan, dependencies);
  assert.deepEqual(signalled, [42]);
  assert.deepEqual(result, { targetStoppedListening: true, portFree: true, remainingPids: [] });
});

test("close distinguishes a stopped target from a port reoccupied by another PID", async () => {
  const original = activity();
  const { dependencies, signalled } = fakeDependencies([[original], [original]]);
  dependencies.listeners = async () => [
    { pid: 43, command: "server", uid: 501, port: 3000, addresses: ["127.0.0.1"] },
  ];
  const plan = await prepareClose(options, dependencies);
  const result = await executeClose(plan, dependencies);
  assert.deepEqual(signalled, [42]);
  assert.deepEqual(result, { targetStoppedListening: true, portFree: false, remainingPids: [43] });
});

test("close never signals a PID reused between preview and confirmation", async () => {
  const original = activity();
  const { dependencies, signalled } = fakeDependencies([[original], [original]], ["start-A", "start-B"]);
  const plan = await prepareClose(options, dependencies);
  await assert.rejects(executeClose(plan, dependencies), /changed identity/);
  assert.deepEqual(signalled, []);
});
