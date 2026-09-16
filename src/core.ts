import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type Category = "project" | "application" | "system-service" | "unknown";
export type Confidence = "high" | "medium" | "none";
export type Scope = "local" | "lan";

export interface Listener {
  pid: number;
  command: string;
  uid?: number;
  user?: string;
  port: number;
  addresses: string[];
}

export interface ProcessFact {
  pid: number;
  ppid?: number;
  command: string;
  executablePath?: string;
}

export interface ProjectMarkerFact {
  name: string;
  root: string;
  source: string;
  markerPath: string;
}

export interface ApplicationBundleFact {
  name: string;
  path: string;
  sourcePid: number;
  relationship: "process" | "ancestor";
}

export interface ActivityFacts {
  listener: {
    port: number;
    addresses: string[];
    scope: Scope;
  };
  process: ProcessFact & {
    uid?: number;
    user?: string;
    cwd?: string;
  };
  parentChain: ProcessFact[];
  projectMarker?: ProjectMarkerFact;
  applicationBundle?: ApplicationBundleFact;
}

export interface OwnerInference {
  label: string;
  category: Category;
  confidence: Confidence;
  reason: string;
}

export interface Activity {
  facts: ActivityFacts;
  inference: OwnerInference;
}

export interface ScanResult {
  activities: Activity[];
  limitations: string[];
}

interface ProjectSearchResult {
  accepted?: ProjectMarkerFact;
}

function parseEndpoint(endpoint: string): { address: string; port: number } | undefined {
  const match = endpoint.match(/^(.*):(\d+)$/);
  if (!match) return undefined;

  const port = Number(match[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return undefined;

  return { address: match[1], port };
}

export function parseLsofListeners(output: string): Listener[] {
  let pid: number | undefined;
  let command = "unknown";
  let uid: number | undefined;
  let user: string | undefined;
  const listeners = new Map<string, Listener>();

  for (const rawLine of output.split(/\r?\n/)) {
    if (!rawLine) continue;

    const field = rawLine[0];
    const value = rawLine.slice(1);

    if (field === "p") {
      pid = Number(value);
      command = "unknown";
      uid = undefined;
      user = undefined;
      continue;
    }

    if (field === "c") {
      command = value || "unknown";
      continue;
    }

    if (field === "u") {
      const parsedUid = Number(value);
      uid = Number.isInteger(parsedUid) ? parsedUid : undefined;
      continue;
    }

    if (field === "L") {
      user = value || undefined;
      continue;
    }

    if (field !== "n" || pid === undefined || !Number.isInteger(pid)) continue;

    const endpoint = parseEndpoint(value);
    if (!endpoint) continue;

    const key = `${pid}:${endpoint.port}`;
    const existing = listeners.get(key);
    if (existing) {
      if (!existing.addresses.includes(endpoint.address)) existing.addresses.push(endpoint.address);
      continue;
    }

    listeners.set(key, {
      pid,
      command,
      uid,
      user,
      port: endpoint.port,
      addresses: [endpoint.address],
    });
  }

  return [...listeners.values()].sort((a, b) => a.port - b.port || a.pid - b.pid);
}

export function parseCwdOutput(output: string): Map<number, string> {
  const cwdByPid = new Map<number, string>();
  let pid: number | undefined;

  for (const rawLine of output.split(/\r?\n/)) {
    if (!rawLine) continue;
    if (rawLine[0] === "p") {
      pid = Number(rawLine.slice(1));
    } else if (rawLine[0] === "n" && pid !== undefined) {
      cwdByPid.set(pid, rawLine.slice(1));
    }
  }

  return cwdByPid;
}

export function parseExecutableOutput(output: string): Map<number, string> {
  const executableByPid = new Map<number, string>();
  let pid: number | undefined;

  for (const rawLine of output.split(/\r?\n/)) {
    if (!rawLine) continue;
    if (rawLine[0] === "p") {
      pid = Number(rawLine.slice(1));
    } else if (rawLine[0] === "n" && pid !== undefined && !executableByPid.has(pid)) {
      executableByPid.set(pid, rawLine.slice(1));
    }
  }

  return executableByPid;
}

export function parseProcessTable(output: string): Map<number, ProcessFact> {
  const processes = new Map<number, ProcessFact>();

  for (const line of output.split(/\r?\n/)) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+?)\s*$/);
    if (!match) continue;

    const pid = Number(match[1]);
    const ppid = Number(match[2]);
    const rawCommand = match[3];
    const executablePath = path.isAbsolute(rawCommand) ? rawCommand : undefined;
    processes.set(pid, {
      pid,
      ppid,
      command: executablePath ? path.basename(executablePath) : rawCommand,
      ...(executablePath ? { executablePath } : {}),
    });
  }

  return processes;
}

async function runLsof(args: string[]): Promise<string> {
  try {
    const result = await execFileAsync("/usr/sbin/lsof", args, {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
    });
    return result.stdout;
  } catch (error) {
    const failure = error as NodeJS.ErrnoException & { code?: string | number; stdout?: string };
    if (failure.code === 1) return failure.stdout ?? "";
    if (failure.code === "ENOENT") throw new Error("lsof is not available on this Mac.");
    throw error;
  }
}

export async function scanListeners(): Promise<Listener[]> {
  const output = await runLsof(["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcLun"]);
  return parseLsofListeners(output);
}

async function getLsofFacts(
  pids: number[],
  descriptor: "cwd" | "txt",
): Promise<Map<number, string>> {
  const result = new Map<number, string>();
  const chunkSize = 100;

  for (let offset = 0; offset < pids.length; offset += chunkSize) {
    const chunk = pids.slice(offset, offset + chunkSize);
    if (!chunk.length) continue;
    const output = await runLsof(["-a", "-p", chunk.join(","), "-d", descriptor, "-Fpn"]);
    const parsed = descriptor === "cwd" ? parseCwdOutput(output) : parseExecutableOutput(output);
    for (const [pid, value] of parsed) result.set(pid, value);
  }

  return result;
}

async function getProcessTable(): Promise<{ table: Map<number, ProcessFact>; limitation?: string }> {
  try {
    const result = await execFileAsync("/bin/ps", ["-axo", "pid=,ppid=,comm="], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
    });
    return { table: parseProcessTable(result.stdout) };
  } catch {
    return {
      table: new Map(),
      limitation: "The process table was unavailable, so parent-process evidence could not be collected.",
    };
  }
}

async function exists(filePath: string): Promise<boolean> {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function packageName(directory: string): Promise<string | undefined> {
  try {
    const packageJson = JSON.parse(await readFile(path.join(directory, "package.json"), "utf8"));
    return typeof packageJson.name === "string" && packageJson.name.trim()
      ? packageJson.name.trim()
      : undefined;
  } catch {
    return undefined;
  }
}

async function pyprojectName(directory: string): Promise<string | undefined> {
  try {
    const contents = await readFile(path.join(directory, "pyproject.toml"), "utf8");
    const projectSection = contents.match(/\[project\]([\s\S]*?)(?:\n\[|$)/);
    const name = projectSection?.[1].match(/^\s*name\s*=\s*["']([^"']+)["']/m)?.[1];
    return name?.trim() || undefined;
  } catch {
    return undefined;
  }
}

function isWithin(candidate: string, parent: string): boolean {
  const relative = path.relative(parent, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

export function projectPathRejectionReason(
  root: string,
  cwd: string,
  homeDirectory = os.homedir(),
): string | undefined {
  const resolvedRoot = path.resolve(root);
  const resolvedCwd = path.resolve(cwd);
  const segments = resolvedRoot.split(path.sep).filter(Boolean);
  const lowerSegments = segments.map((segment) => segment.toLowerCase());

  if (segments.some((segment) => segment.toLowerCase().endsWith(".app"))) {
    return "the marker is inside an application bundle";
  }

  const osManagedRoots = [
    "/Applications",
    "/System",
    "/Library",
    "/usr",
    "/bin",
    "/sbin",
    "/opt",
    "/private/var",
  ];
  if (osManagedRoots.some((managedRoot) => isWithin(resolvedRoot, managedRoot))) {
    return "the marker is inside an installed or operating-system-managed tree";
  }

  const userLibrary = path.join(homeDirectory, "Library");
  if (isWithin(resolvedRoot, userLibrary)) {
    return "the marker is inside the user Library used for application data and caches";
  }

  if (isWithin(resolvedRoot, homeDirectory)) {
    if (resolvedRoot === path.resolve(homeDirectory)) {
      return "the marker root is the user home rather than a specific project directory";
    }
    const relativeSegments = path.relative(homeDirectory, resolvedRoot).split(path.sep).filter(Boolean);
    if (relativeSegments[0]?.startsWith(".")) {
      return "the marker is inside a hidden per-user tool-data tree";
    }
  }

  if (lowerSegments.includes("node_modules")) {
    return "the marker is inside a dependency tree";
  }

  if (lowerSegments.some((segment) => segment === "cache" || segment === "caches" || segment === ".cache")) {
    return "the marker is inside a cache tree";
  }

  if (!isWithin(resolvedCwd, resolvedRoot)) {
    return "the working directory is not inside the marker root";
  }

  return undefined;
}

async function findProject(cwd: string): Promise<ProjectSearchResult> {
  if (!cwd || cwd === "/") return {};

  let directory = path.resolve(cwd);
  while (true) {
    const markers: Array<[string, string]> = [
      [".git", "git"],
      ["package.json", "package.json"],
      ["pyproject.toml", "pyproject.toml"],
      ["Cargo.toml", "Cargo.toml"],
      ["go.mod", "go.mod"],
    ];

    for (const [marker, source] of markers) {
      const markerPath = path.join(directory, marker);
      if (!(await exists(markerPath))) continue;
      if (projectPathRejectionReason(directory, cwd)) continue;

      const name =
        (source === "package.json" ? await packageName(directory) : undefined) ??
        (source === "pyproject.toml" ? await pyprojectName(directory) : undefined) ??
        path.basename(directory);

      return { accepted: { name, root: directory, source, markerPath } };
    }

    const parent = path.dirname(directory);
    if (parent === directory) return {};
    directory = parent;
  }
}

export function applicationBundleFromPath(
  executablePath: string,
): Omit<ApplicationBundleFact, "sourcePid" | "relationship"> | undefined {
  if (!path.isAbsolute(executablePath)) return undefined;
  const parts = executablePath.split(path.sep);
  const bundleIndex = parts.findIndex((part) => part.toLowerCase().endsWith(".app"));
  if (bundleIndex < 0) return undefined;

  const segment = parts[bundleIndex];
  const name = segment.slice(0, -4).trim();
  if (!name) return undefined;
  return { name, path: parts.slice(0, bundleIndex + 1).join(path.sep) || path.sep };
}

function parentChainFor(process: ProcessFact, table: Map<number, ProcessFact>): ProcessFact[] {
  const chain: ProcessFact[] = [];
  const seen = new Set([process.pid]);
  let parentPid = process.ppid;

  while (parentPid && parentPid > 0 && !seen.has(parentPid) && chain.length < 16) {
    seen.add(parentPid);
    const parent = table.get(parentPid);
    if (!parent) break;
    chain.push(parent);
    parentPid = parent.ppid;
  }

  return chain;
}

function findApplicationBundle(
  process: ProcessFact,
  parentChain: ProcessFact[],
): ApplicationBundleFact | undefined {
  if (process.executablePath) {
    const bundle = applicationBundleFromPath(process.executablePath);
    if (bundle) return { ...bundle, sourcePid: process.pid, relationship: "process" };
  }

  for (const ancestor of parentChain.slice(0, 1)) {
    if (!ancestor.executablePath) continue;
    const bundle = applicationBundleFromPath(ancestor.executablePath);
    if (bundle) return { ...bundle, sourcePid: ancestor.pid, relationship: "ancestor" };
  }

  return undefined;
}

function isSystemExecutable(executablePath?: string): boolean {
  if (!executablePath) return false;
  return ["/System", "/usr/bin", "/usr/sbin", "/usr/libexec", "/bin", "/sbin"].some((root) =>
    isWithin(executablePath, root),
  );
}

export function listenerScope(addresses: string[]): Scope {
  const loopback = addresses.every((address) => {
    const normalized = address.replace(/^\[|\]$/g, "").toLowerCase();
    return normalized === "127.0.0.1" || normalized === "::1" || normalized === "localhost";
  });
  return loopback ? "local" : "lan";
}

export function inferOwner(facts: ActivityFacts): OwnerInference {
  if (facts.projectMarker) {
    return {
      label: facts.projectMarker.name,
      category: "project",
      confidence: "high",
      reason: `CWD is within a project root containing ${facts.projectMarker.source} at ${facts.projectMarker.markerPath}.`,
    };
  }

  if (facts.applicationBundle) {
    const direct = facts.applicationBundle.relationship === "process";
    return {
      label: facts.applicationBundle.name,
      category: "application",
      confidence: direct ? "high" : "medium",
      reason: direct
        ? `The executable is inside ${facts.applicationBundle.path}.`
        : `Direct parent PID ${facts.applicationBundle.sourcePid} runs inside ${facts.applicationBundle.path}.`,
    };
  }

  if (isSystemExecutable(facts.process.executablePath)) {
    return {
      label: path.basename(facts.process.executablePath!),
      category: "system-service",
      confidence: "high",
      reason: `The executable path ${facts.process.executablePath} is in an operating-system-managed executable location.`,
    };
  }

  return {
    label: "Unknown",
    category: "unknown",
    confidence: "none",
    reason: "No accepted project marker, application bundle, or operating-system executable path established an owner.",
  };
}

export function buildActivity(
  listener: Listener,
  process: ProcessFact,
  cwd?: string,
  parentChain: ProcessFact[] = [],
  projectMarker?: ProjectMarkerFact,
): Activity {
  const resolvedProcess = { ...process, command: listener.command, uid: listener.uid, user: listener.user, cwd };
  const applicationBundle = findApplicationBundle(resolvedProcess, parentChain);
  const facts: ActivityFacts = {
    listener: {
      port: listener.port,
      addresses: listener.addresses,
      scope: listenerScope(listener.addresses),
    },
    process: resolvedProcess,
    parentChain,
    projectMarker,
    applicationBundle,
  };

  return { facts, inference: inferOwner(facts) };
}

export async function scanActivities(): Promise<ScanResult> {
  const listeners = await scanListeners();
  const pids = [...new Set(listeners.map((listener) => listener.pid))];
  const [cwdByPid, executableByPid, processTableResult] = await Promise.all([
    getLsofFacts(pids, "cwd"),
    getLsofFacts(pids, "txt"),
    getProcessTable(),
  ]);
  const projectByCwd = new Map<string, ProjectMarkerFact | undefined>();

  for (const cwd of new Set(cwdByPid.values())) {
    projectByCwd.set(cwd, (await findProject(cwd)).accepted);
  }

  const activities = listeners.map((listener) => {
    const tableProcess = processTableResult.table.get(listener.pid);
    const process: ProcessFact = {
      pid: listener.pid,
      ppid: tableProcess?.ppid,
      command: listener.command,
      executablePath: executableByPid.get(listener.pid) ?? tableProcess?.executablePath,
    };
    const cwd = cwdByPid.get(listener.pid);
    return buildActivity(
      listener,
      process,
      cwd,
      parentChainFor(process, processTableResult.table),
      cwd ? projectByCwd.get(cwd) : undefined,
    );
  });

  return {
    activities,
    limitations: processTableResult.limitation ? [processTableResult.limitation] : [],
  };
}

export function compactPath(inputPath?: string): string {
  if (!inputPath) return "—";
  const home = os.homedir();
  return inputPath === home || inputPath.startsWith(`${home}${path.sep}`)
    ? `~${inputPath.slice(home.length)}`
    : inputPath;
}
