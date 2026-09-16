import assert from "node:assert/strict";
import test from "node:test";

import {
  applicationBundleFromPath,
  buildActivity,
  inferOwner,
  listenerScope,
  parseCwdOutput,
  parseExecutableOutput,
  parseLsofListeners,
  parseProcessTable,
  projectPathRejectionReason,
  type ActivityFacts,
  type Listener,
  type ProcessFact,
  type ProjectMarkerFact,
} from "../src/core.ts";

const listener: Listener = {
  pid: 42,
  command: "node",
  uid: 501,
  user: "developer",
  port: 3000,
  addresses: ["127.0.0.1"],
};

test("parses listeners and merges IPv4 and IPv6 addresses for one PID and port", () => {
  const output = `p42
cnode
u501
Ldeveloper
f17
n*:3000
f18
n[::]:3000
f19
n127.0.0.1:5173
`;

  assert.deepEqual(parseLsofListeners(output), [
    {
      pid: 42,
      command: "node",
      uid: 501,
      user: "developer",
      port: 3000,
      addresses: ["*", "[::]"],
    },
    {
      pid: 42,
      command: "node",
      uid: 501,
      user: "developer",
      port: 5173,
      addresses: ["127.0.0.1"],
    },
  ]);
});

test("keeps different processes on the same port separate", () => {
  const output = `p10
cnode
n*:3000
p20
cpython
n127.0.0.1:3000
`;

  assert.deepEqual(
    parseLsofListeners(output).map(({ pid, port }) => ({ pid, port })),
    [
      { pid: 10, port: 3000 },
      { pid: 20, port: 3000 },
    ],
  );
});

test("parses batched cwd and first executable records", () => {
  const cwdOutput = `p10
fcwd
n/Users/developer/work/one
p20
fcwd
n/Users/developer/work/two
`;
  const executableOutput = `p10
ftxt
n/Applications/Example.app/Contents/MacOS/Example
ftxt
n/usr/lib/dyld
p20
ftxt
n/opt/tools/bin/server
`;

  assert.deepEqual([...parseCwdOutput(cwdOutput)], [
    [10, "/Users/developer/work/one"],
    [20, "/Users/developer/work/two"],
  ]);
  assert.deepEqual([...parseExecutableOutput(executableOutput)], [
    [10, "/Applications/Example.app/Contents/MacOS/Example"],
    [20, "/opt/tools/bin/server"],
  ]);
});

test("parses generic macOS process-table rows including paths with spaces", () => {
  const processes = parseProcessTable(`    1     0 /sbin/launchd
  200     1 /Applications/Example Browser.app/Contents/MacOS/Example Browser
  250   200 helper-process
`);

  assert.deepEqual(processes.get(200), {
    pid: 200,
    ppid: 1,
    command: "Example Browser",
    executablePath: "/Applications/Example Browser.app/Contents/MacOS/Example Browser",
  });
  assert.deepEqual(processes.get(250), { pid: 250, ppid: 200, command: "helper-process" });
});

test("extracts an outer application bundle without a product-name lookup", () => {
  assert.deepEqual(
    applicationBundleFromPath(
      "/Applications/Example Browser.app/Contents/Frameworks/Renderer.app/Contents/MacOS/Renderer",
    ),
    { name: "Example Browser", path: "/Applications/Example Browser.app" },
  );
});

test("project marker evidence takes precedence over a generic executable", () => {
  const marker: ProjectMarkerFact = {
    name: "sample-web",
    root: "/Users/developer/work/sample-web",
    source: "package.json",
    markerPath: "/Users/developer/work/sample-web/package.json",
  };
  const activity = buildActivity(
    { ...listener, addresses: ["*"] },
    { pid: 42, ppid: 10, command: "node", executablePath: "/opt/tools/bin/node" },
    "/Users/developer/work/sample-web",
    [],
    marker,
  );

  assert.deepEqual(activity.inference, {
    label: "sample-web",
    category: "project",
    confidence: "high",
    reason:
      "CWD is within a project root containing package.json at /Users/developer/work/sample-web/package.json.",
  });
  assert.equal(activity.facts.listener.scope, "lan");
});

test("uses direct and ancestor .app bundle paths as evidence", () => {
  const direct = buildActivity(listener, {
    pid: 42,
    command: "Example Browser",
    executablePath: "/Applications/Example Browser.app/Contents/MacOS/Example Browser",
  });
  assert.equal(direct.inference.label, "Example Browser");
  assert.equal(direct.inference.category, "application");
  assert.equal(direct.inference.confidence, "high");

  const parent: ProcessFact = {
    pid: 10,
    ppid: 1,
    command: "Example Editor",
    executablePath: "/Applications/Example Editor.app/Contents/MacOS/Example Editor",
  };
  const child = buildActivity(listener, { pid: 42, ppid: 10, command: "extension-host" }, undefined, [parent]);
  assert.equal(child.inference.label, "Example Editor");
  assert.equal(child.inference.confidence, "medium");
  assert.equal(child.facts.applicationBundle?.sourcePid, 10);

  const distant = buildActivity(
    listener,
    { pid: 42, ppid: 10, command: "server" },
    undefined,
    [
      { pid: 10, ppid: 5, command: "shell", executablePath: "/opt/tools/bin/shell" },
      parent,
    ],
  );
  assert.equal(distant.inference.label, "Unknown");
});

test("recognises system services only from operating-system executable paths", () => {
  const activity = buildActivity(listener, {
    pid: 42,
    ppid: 1,
    command: "exampled",
    executablePath: "/usr/libexec/exampled",
  });

  assert.equal(activity.inference.label, "exampled");
  assert.equal(activity.inference.category, "system-service");
  assert.equal(activity.inference.confidence, "high");
});

test("does not infer owners from product-like words in commands or paths", () => {
  for (const [command, cwd] of [
    ["popular-editor-indexer", "/Users/developer/work/plain-folder"],
    ["ai-assistant-helper", "/Users/developer/tmp/plain-folder"],
    ["browser-agent-proxy", "/Users/developer/Downloads/plain-folder"],
  ]) {
    const activity = buildActivity(
      { ...listener, command },
      { pid: 42, command, executablePath: `/Users/developer/bin/${command}` },
      cwd,
    );
    assert.equal(activity.inference.label, "Unknown");
    assert.equal(activity.inference.category, "unknown");
    assert.equal(activity.inference.confidence, "none");
  }
});

test("rejects marker roots in editor data, caches, installed trees, app bundles, and dependencies", () => {
  const home = "/Users/developer";
  const cases: Array<[string, string]> = [
    ["/Users/developer/.editor/extensions/language", "/Users/developer/.editor/extensions/language"],
    ["/Users/developer/Library/Caches/tool/package", "/Users/developer/Library/Caches/tool/package"],
    ["/opt/package-manager/Cellar/runtime/1.0/libexec", "/opt/package-manager/Cellar/runtime/1.0/libexec"],
    ["/Applications/Example.app/Contents/Resources/server", "/Applications/Example.app/Contents/Resources/server"],
    ["/Applications/LooseInstalledTree", "/Applications/LooseInstalledTree"],
    ["/Users/developer/work/site/node_modules/server", "/Users/developer/work/site/node_modules/server"],
    ["/Users/developer", "/Users/developer/work"],
  ];

  for (const [root, cwd] of cases) {
    assert.ok(projectPathRejectionReason(root, cwd, home), root);
  }
  assert.equal(
    projectPathRejectionReason("/Users/developer/work/site", "/Users/developer/work/site/src", home),
    undefined,
  );
});

test("unknown is explicit when facts do not establish an owner", () => {
  const facts: ActivityFacts = {
    listener: { port: 8080, addresses: ["127.0.0.1"], scope: "local" },
    process: {
      pid: 99,
      command: "server",
      executablePath: "/Users/developer/bin/server",
      cwd: "/Users/developer/tmp",
    },
    parentChain: [],
  };

  assert.deepEqual(inferOwner(facts), {
    label: "Unknown",
    category: "unknown",
    confidence: "none",
    reason:
      "No accepted project marker, application bundle, or operating-system executable path established an owner.",
  });
});

test("classifies only loopback addresses as local-only", () => {
  assert.equal(listenerScope(["127.0.0.1", "[::1]"]), "local");
  assert.equal(listenerScope(["127.0.0.1", "*"]), "lan");
});
