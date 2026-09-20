#!/usr/bin/env node

import process from "node:process";
import { createInterface } from "node:readline/promises";
import {
  compactPath,
  scanActivities,
  type Activity,
  type Category,
} from "./core.ts";
import { executeClose, prepareClose, type ClosePlan } from "./close.ts";

const colorEnabled = process.stdout.isTTY && !process.argv.includes("--no-color") && !process.env.NO_COLOR;
const paint = (code: number, text: string): string =>
  colorEnabled ? `\u001b[${code}m${text}\u001b[0m` : text;
const bold = (text: string): string => paint(1, text);
const dim = (text: string): string => paint(2, text);
const green = (text: string): string => paint(32, text);
const yellow = (text: string): string => paint(33, text);
const cyan = (text: string): string => paint(36, text);

function help(): void {
  console.log(`
${bold("LeftOpen")} — See what your tools left running on localhost.

Usage:
  leftopen               Show all listening activity
  leftopen <port>        Explain who owns a port
  leftopen close <port>  Gracefully close the process listening on a port
  leftopen --json        Print machine-readable output

Options:
  --no-color             Disable colours
  --pid <pid>            Select a PID when multiple processes share a port
  --dry-run              Preview a close without signalling anything
  --yes                  Confirm a close without an interactive prompt
  -h, --help             Show this help
  -v, --version          Show the version
`);
}

function pad(value: string | number, width: number): string {
  const text = String(value);
  return text.length >= width ? text : text + " ".repeat(width - text.length);
}

function scopeLabel(activity: Activity): string {
  return activity.facts.listener.scope === "local" ? green("LOCAL") : yellow("LAN");
}

function printSection(title: string, activities: Activity[]): void {
  if (!activities.length) return;
  console.log(`\n${bold(title)} ${dim(`(${activities.length})`)}`);
  console.log(dim(`${pad("PORT", 8)}${pad("PID", 9)}${pad("OWNER", 29)}${pad("PROCESS", 25)}SCOPE`));

  for (const activity of activities) {
    const { listener, process } = activity.facts;
    console.log(
      `${pad(listener.port, 8)}${pad(process.pid, 9)}${pad(activity.inference.label.slice(0, 27), 29)}` +
        `${pad(process.command.slice(0, 23), 25)}${scopeLabel(activity)}`,
    );
    if (activity.facts.projectMarker?.root) {
      console.log(dim(`         ↳ ${compactPath(activity.facts.projectMarker.root)}`));
    }
  }
}

function printOverview(activities: Activity[]): void {
  const portCount = new Set(activities.map((activity) => activity.facts.listener.port)).size;
  const processCount = new Set(activities.map((activity) => activity.facts.process.pid)).size;
  const projectCount = new Set(
    activities
      .filter((activity) => activity.facts.projectMarker)
      .map((activity) => activity.facts.projectMarker!.root),
  ).size;
  const lanCount = new Set(
    activities
      .filter((activity) => activity.facts.listener.scope === "lan")
      .map((activity) => activity.facts.listener.port),
  ).size;

  console.log(bold("\nLEFT OPEN"));
  console.log(
    `${cyan(String(portCount))} listening ports · ${processCount} processes · ` +
      `${projectCount} projects · ${yellow(String(lanCount))} LAN-visible`,
  );

  const sections: Array<[Category, string]> = [
    ["project", "MY PROJECTS"],
    ["application", "APPLICATIONS"],
    ["system-service", "SYSTEM SERVICES"],
    ["unknown", "UNKNOWN"],
  ];

  for (const [category, title] of sections) {
    printSection(
      title,
      activities.filter((activity) => activity.inference.category === category),
    );
  }

  console.log(dim("\nLOCAL = this Mac only · LAN = may be reachable from your local network\n"));
}

function printDetail(port: number, activities: Activity[]): void {
  const matches = activities.filter((activity) => activity.facts.listener.port === port);
  if (!matches.length) {
    console.log(`\n${green("FREE")} Nothing is listening on port ${port}.\n`);
    return;
  }

  console.log(`\n${bold(`PORT ${port}`)} · ${matches.length} listener${matches.length === 1 ? "" : "s"}`);
  for (const [index, activity] of matches.entries()) {
    const { listener, process, parentChain, projectMarker, applicationBundle } = activity.facts;
    if (index) console.log(dim("─".repeat(56)));
    console.log(`Owner:     ${activity.inference.label}`);
    console.log(`Type:      ${activity.inference.category}`);
    console.log(`Confidence:${activity.inference.confidence === "none" ? " none" : ` ${activity.inference.confidence}`}`);
    console.log(`Process:   ${process.command}`);
    console.log(`PID:       ${process.pid}`);
    console.log(`PPID:      ${process.ppid ?? "unknown"}`);
    console.log(`User:      ${process.user ?? process.uid ?? "unknown"}`);
    console.log(`Scope:     ${scopeLabel(activity)}`);
    console.log(`Addresses: ${listener.addresses.join(", ")}`);
    console.log(`Executable:${process.executablePath ? ` ${compactPath(process.executablePath)}` : " unknown"}`);
    console.log(`CWD:       ${compactPath(process.cwd)}`);
    if (projectMarker) console.log(`Marker:    ${compactPath(projectMarker.markerPath)}`);
    if (applicationBundle) console.log(`App bundle:${` ${compactPath(applicationBundle.path)}`}`);
    if (parentChain.length) {
      console.log(`Parents:   ${parentChain.map((parent) => `${parent.command} (${parent.pid})`).join(" → ")}`);
    }
    console.log(`Reason:    ${activity.inference.reason}`);
  }
  console.log();
}

function parsePort(value?: string): number | undefined {
  if (!value || !/^\d+$/.test(value)) return undefined;
  const port = Number(value);
  return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : undefined;
}

async function confirmClose(plan: ClosePlan): Promise<boolean> {
  if (!process.stdin.isTTY) {
    throw new Error("An interactive terminal is required; use --yes only when you intend to close this PID.");
  }
  const terminal = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = await terminal.question(`Close PID ${plan.pid} listening on port ${plan.port}? [y/N] `);
    return answer.trim().toLowerCase() === "y" || answer.trim().toLowerCase() === "yes";
  } finally {
    terminal.close();
  }
}

async function runClose(args: string[]): Promise<void> {
  const dryRun = args.includes("--dry-run");
  const yes = args.includes("--yes");
  const pidIndex = args.indexOf("--pid");
  const pidText = pidIndex < 0 ? undefined : args[pidIndex + 1];
  const selectedPid = pidText && /^\d+$/.test(pidText) ? Number(pidText) : undefined;
  const remaining = args.filter((arg, index) =>
    arg !== "--dry-run" &&
    arg !== "--yes" &&
    (pidIndex < 0 || (index !== pidIndex && index !== pidIndex + 1)),
  );
  const port = parsePort(remaining[0]);

  if (
    port === undefined ||
    remaining.length !== 1 ||
    (pidIndex >= 0 && (!selectedPid || !Number.isSafeInteger(selectedPid)))
  ) {
    console.error("Usage: leftopen close <port> [--pid <pid>] [--dry-run] [--yes]");
    process.exitCode = 2;
    return;
  }

  const currentUid = process.getuid?.();
  if (currentUid === undefined) throw new Error("This platform cannot verify the current user ID.");

  const plan = await prepareClose({ port, pid: selectedPid, currentUid, currentPid: process.pid });
  console.log(`\n${bold(`CLOSE PORT ${port}`)} · PID ${plan.pid}`);
  console.log(`Owner:      ${plan.activity.inference.label} (${plan.activity.inference.confidence} confidence)`);
  console.log(`Process:    ${plan.activity.facts.process.command}`);
  console.log(`Executable: ${compactPath(plan.executablePath)}`);
  console.log(`CWD:        ${compactPath(plan.activity.facts.process.cwd)}`);
  console.log(`Started:    ${plan.startTime}`);
  if (plan.otherPorts.length) {
    console.log(yellow(`Warning: the same PID also listens on ${plan.otherPorts.join(", ")}; they may close too.`));
  }
  if (plan.peerPids.length) {
    console.log(yellow(`Other PIDs also listen on this port: ${plan.peerPids.join(", ")}. Only PID ${plan.pid} will be signalled.`));
  }

  if (dryRun) {
    console.log(green("Dry run: no signal sent.\n"));
    return;
  }
  if (!yes && !(await confirmClose(plan))) {
    console.log("Cancelled; no signal sent.\n");
    return;
  }

  const result = await executeClose(plan);
  if (result.portFree) {
    console.log(green(`Port ${port} is now free.\n`));
  } else if (result.targetStoppedListening) {
    console.log(yellow(`PID ${plan.pid} stopped listening, but port ${port} is now held by ${result.remainingPids.join(", ")}.\n`));
    process.exitCode = 1;
  } else {
    console.log(yellow(`SIGTERM was sent, but PID ${plan.pid} still listens on port ${port}. No force-kill was attempted.\n`));
    process.exitCode = 1;
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((arg) => arg !== "--no-color");
  if (args.includes("-h") || args.includes("--help")) return help();
  if (process.argv.includes("-v") || process.argv.includes("--version")) {
    console.log("0.3.1");
    return;
  }

  if (args[0] === "close") {
    return runClose(args.slice(1));
  }

  const json = args.includes("--json");
  const positional = args.filter((arg) => arg !== "--json");
  if (positional.length > 1 || (positional[0] && !/^\d+$/.test(positional[0]))) {
    console.error("Usage: leftopen [port] [--json]");
    process.exitCode = 2;
    return;
  }

  const port = positional[0] ? parsePort(positional[0]) : undefined;
  if (positional[0] && port === undefined) {
    console.error("Port must be between 1 and 65535.");
    process.exitCode = 2;
    return;
  }

  const result = await scanActivities();
  const { activities } = result;
  const selected =
    port === undefined
      ? activities
      : activities.filter((activity) => activity.facts.listener.port === port);
  if (json) {
    console.log(JSON.stringify({ activities: selected, limitations: result.limitations }, null, 2));
  } else if (port !== undefined) {
    printDetail(port, activities);
  } else {
    printOverview(activities);
  }

  if (!json && result.limitations.length) {
    console.log(yellow(`Limited evidence: ${result.limitations.join(" ")}`));
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  const action = process.argv[2] === "close" ? "close this port" : "scan this Mac";
  console.error(`LeftOpen could not ${action}: ${message}`);
  process.exitCode = 1;
});
