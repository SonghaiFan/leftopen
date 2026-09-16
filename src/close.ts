import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  scanActivities,
  scanListeners,
  type Activity,
  type Listener,
} from "./core.ts";

const execFileAsync = promisify(execFile);

export interface ClosePlan {
  port: number;
  pid: number;
  uid: number;
  executablePath: string;
  startTime: string;
  activity: Activity;
  otherPorts: number[];
  peerPids: number[];
}

export interface CloseOptions {
  port: number;
  pid?: number;
  currentUid: number;
  currentPid: number;
}

export interface CloseDependencies {
  scan: typeof scanActivities;
  listeners: typeof scanListeners;
  startTime: (pid: number) => Promise<string | undefined>;
  signal: (pid: number) => void;
  wait: (milliseconds: number) => Promise<void>;
}

const defaultDependencies: CloseDependencies = {
  scan: scanActivities,
  listeners: scanListeners,
  startTime: processStartTime,
  signal: (pid) => process.kill(pid, "SIGTERM"),
  wait: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
};

function isProtectedExecutable(executablePath: string): boolean {
  return ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"].some(
    (prefix) => executablePath.startsWith(prefix),
  );
}

export function selectCloseTarget(
  activities: Activity[],
  options: CloseOptions,
): { activity: Activity; otherPorts: number[]; peerPids: number[] } {
  const matches = activities.filter((activity) => activity.facts.listener.port === options.port);
  if (!matches.length) throw new Error(`Nothing is listening on port ${options.port}.`);

  const pids = [...new Set(matches.map((activity) => activity.facts.process.pid))];
  if (options.pid === undefined && pids.length > 1) {
    throw new Error(`Port ${options.port} has multiple owning PIDs (${pids.join(", ")}); specify --pid.`);
  }

  const pid = options.pid ?? pids[0];
  const activity = matches.find((candidate) => candidate.facts.process.pid === pid);
  if (!activity) throw new Error(`PID ${pid} is not listening on port ${options.port}.`);

  const { process: target, applicationBundle } = activity.facts;
  if (options.currentUid === 0) {
    throw new Error("Running close as root is not supported; refusing to signal a system-level process.");
  }
  if (pid <= 1 || pid === options.currentPid) throw new Error(`PID ${pid} is protected.`);
  if (target.uid === undefined) throw new Error(`PID ${pid} has no verified user ID; refusing to close it.`);
  if (target.uid !== options.currentUid) throw new Error(`PID ${pid} belongs to another user; refusing to close it.`);
  if (!target.executablePath) throw new Error(`PID ${pid} has no verified executable path; refusing to close it.`);
  if (isProtectedExecutable(target.executablePath)) {
    throw new Error(`PID ${pid} runs from an operating-system executable location; refusing to close it.`);
  }
  if (applicationBundle) {
    throw new Error(`PID ${pid} belongs to an application bundle; closing it could disrupt the app.`);
  }

  const otherPorts = [
    ...new Set(
      activities
        .filter((candidate) => candidate.facts.process.pid === pid && candidate.facts.listener.port !== options.port)
        .map((candidate) => candidate.facts.listener.port),
    ),
  ].sort((a, b) => a - b);

  return { activity, otherPorts, peerPids: pids.filter((candidate) => candidate !== pid) };
}

export async function processStartTime(pid: number): Promise<string | undefined> {
  try {
    const result = await execFileAsync("/bin/ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      maxBuffer: 1024,
    });
    const value = result.stdout.trim();
    return value || undefined;
  } catch {
    return undefined;
  }
}

export async function prepareClose(
  options: CloseOptions,
  dependencies: CloseDependencies = defaultDependencies,
): Promise<ClosePlan> {
  const snapshot = await dependencies.scan();
  const { activity, otherPorts, peerPids } = selectCloseTarget(snapshot.activities, options);
  const { process: target } = activity.facts;
  const startTime = await dependencies.startTime(target.pid);
  if (!startTime) {
    throw new Error(`PID ${target.pid} has no verified start time; refusing to close it.`);
  }

  return {
    port: options.port,
    pid: target.pid,
    uid: target.uid!,
    executablePath: target.executablePath!,
    startTime,
    activity,
    otherPorts,
    peerPids,
  };
}

export function verifyCloseTarget(plan: ClosePlan, activities: Activity[], startTime?: string): void {
  const matches = activities.filter((activity) => activity.facts.listener.port === plan.port);
  const matchingPid = matches.find((activity) => activity.facts.process.pid === plan.pid);
  if (!matchingPid) throw new Error(`PID ${plan.pid} no longer listens on port ${plan.port}; nothing was signalled.`);
  const freshPeerPids = [...new Set(matches.map((activity) => activity.facts.process.pid))]
    .filter((pid) => pid !== plan.pid);
  if (freshPeerPids.some((pid) => !plan.peerPids.includes(pid))) {
    throw new Error(`Port ${plan.port} acquired a new owning PID; nothing was signalled.`);
  }

  const target = matchingPid.facts.process;
  if (
    !startTime ||
    startTime !== plan.startTime ||
    target.uid !== plan.uid ||
    target.executablePath !== plan.executablePath
  ) {
    throw new Error(`PID ${plan.pid} changed identity since the preview; nothing was signalled.`);
  }
  if (
    isProtectedExecutable(target.executablePath!) ||
    matchingPid.facts.applicationBundle
  ) {
    throw new Error(`PID ${plan.pid} is now a protected process; nothing was signalled.`);
  }
}

export interface CloseResult {
  targetStoppedListening: boolean;
  portFree: boolean;
  remainingPids: number[];
}

export async function executeClose(
  plan: ClosePlan,
  dependencies: CloseDependencies = defaultDependencies,
): Promise<CloseResult> {
  const fresh = await dependencies.scan();
  const startTime = await dependencies.startTime(plan.pid);
  verifyCloseTarget(plan, fresh.activities, startTime);

  dependencies.signal(plan.pid);

  let latest: Listener[] = [];
  for (let attempt = 0; attempt < 10; attempt += 1) {
    await dependencies.wait(500);
    latest = (await dependencies.listeners()).filter((listener) => listener.port === plan.port);
    if (!latest.some((listener) => listener.pid === plan.pid)) break;
  }

  return {
    targetStoppedListening: !latest.some((listener) => listener.pid === plan.pid),
    portFree: latest.length === 0,
    remainingPids: [...new Set(latest.map((listener) => listener.pid))],
  };
}
