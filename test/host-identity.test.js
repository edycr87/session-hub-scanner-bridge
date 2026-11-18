const test = require("node:test");
const assert = require("node:assert/strict");
const { fork } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const { WebSocketServer } = require("ws");

const root = path.resolve(__dirname, "..");
const bridge = path.join(root, "bridge.js");
const fake = path.join(__dirname, "fixtures", "fake-serialport.js");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function eventually(predicate, message, ticks = 120) {
  for (let i = 0; i < ticks; i += 1) {
    if (predicate()) return;
    await sleep(25);
  }
  assert.fail(message);
}
function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "scanner-host-identity-"));
}
function cleanup(dir) {
  for (const name of fs.readdirSync(dir)) {
    const entry = path.join(dir, name);
    if (fs.statSync(entry).isDirectory()) cleanup(entry);
    else fs.unlinkSync(entry);
  }
  fs.rmdirSync(dir);
}
// Runs the real bridge against a simulated server. `hostname` replaces the OS
// name through the test-only SESSION_HUB_SCANNER_HOSTNAME variable.
async function start(options = {}) {
  const dir = options.dir || tmpDir();
  const messages = [];
  const connections = [];
  const server = new WebSocketServer({ port: 0 });
  await new Promise((resolve) => server.once("listening", resolve));
  server.on("connection", (socket) => {
    connections.push(socket);
    socket.on("message", (rawMessage) => {
      const message = JSON.parse(rawMessage);
      messages.push({ socket, message });
      if (options.onMessage) options.onMessage({ socket, message, messages, connections });
    });
  });
  const env = { ...process.env, SESSION_HUB_SERIALPORT_MODULE: fake, FAKE_SERIAL_PORTS: JSON.stringify(options.ports || []) };
  if (options.hostname !== undefined) env.SESSION_HUB_SCANNER_HOSTNAME = options.hostname;
  const child = fork(
    bridge,
    [
      "--base-url",
      "http://127.0.0.1:" + server.address().port,
      ...(options.noHostArgs ? [] : []),
      "--input-mode",
      "serial",
      "--auto-poll-ms",
      "100",
      "--heartbeat-ms",
      "150",
      "--state-file",
      path.join(dir, "bridge-state.json"),
      "--identity-file",
      path.join(dir, "reader-identity.json"),
      "--installation-file",
      path.join(dir, "installation-id.json"),
      "--ui-dir",
      path.join(dir, "ui"),
      ...(options.args || []),
    ],
    { cwd: root, silent: true, env },
  );
  const logs = [];
  let stderr = "";
  let exitCode = null;
  child.stdout.on("data", (chunk) =>
    chunk
      .toString()
      .split("\n")
      .filter(Boolean)
      .forEach((line) => {
        try {
          logs.push(JSON.parse(line));
        } catch (_) {}
      }),
  );
  child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
  child.on("exit", (code) => (exitCode = code));
  return {
    dir,
    child,
    server,
    messages,
    connections,
    logs,
    stderr: () => stderr,
    exitCode: () => exitCode,
    register: () => messages.find((entry) => entry.message.type === "scanner.register"),
    scans: () => messages.filter((entry) => entry.message.type === "scanner.scan"),
    state: () => {
      try {
        return JSON.parse(fs.readFileSync(path.join(dir, "bridge-state.json"), "utf8"));
      } catch (_) {
        return null;
      }
    },
    async stop(keepDir) {
      child.kill("SIGINT");
      await sleep(40);
      await new Promise((resolve) => server.close(resolve));
      if (!keepDir) cleanup(dir);
    },
  };
}
function registered(entry, payload = { ok: true }) {
  entry.socket.send(JSON.stringify({ type: "scanner.registered", payload }));
}
const autoRegister = ({ socket, message }) => {
  if (message.type === "scanner.register") socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
};

test("default host_id is the normalized hostname and display_name is the hostname as is", async () => {
  const cases = [
    ["DESKTOP-ÑANDÚ 01", "desktop-nandu-01"],
    ["Caja  Norte__2 ", "caja-norte-2"],
    ["PC.Deposito/Sur", "pc-deposito-sur"],
    ["A".repeat(60), "a".repeat(40)],
    ["--Puesto--", "puesto"],
  ];
  for (const [name, expected] of cases) {
    const run = await start({ hostname: name, onMessage: autoRegister });
    try {
      await eventually(() => run.register(), "bridge did not register for " + name);
      const payload = run.register().message.payload;
      assert.equal(payload.host_id, expected, name);
      assert.equal(payload.display_name, name.trim(), "display_name must be the hostname as is");
      assert.ok(payload.host_id.length <= 40 && /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(payload.host_id));
    } finally {
      await run.stop();
    }
  }
});

test("explicit host-id overrides the hostname; explicit display-name too", async () => {
  const run = await start({ hostname: "PC-CAJA-7", args: ["--host-id", "puesto-fijo", "--display-name", "Mi puesto"], onMessage: autoRegister });
  try {
    await eventually(() => run.register(), "no register");
    assert.equal(run.register().message.payload.host_id, "puesto-fijo");
    assert.equal(run.register().message.payload.display_name, "Mi puesto");
  } finally {
    await run.stop();
  }
});

test("a hostname that does not yield a valid name fails closed with a clear message and no shared fallback", async () => {
  for (const name of ["***", "---", "¡¿?!"]) {
    const run = await start({ hostname: name });
    try {
      await eventually(() => run.exitCode() !== null, "bridge kept running with an unusable hostname: " + name);
      assert.notEqual(run.exitCode(), 0);
      assert.match(run.stderr(), /host-id/);
      assert.equal(run.register(), undefined, "it must not register with an invented name");
    } finally {
      await run.stop();
    }
  }
});

test("a bridge without base-url fails with a clear message instead of assuming a server", async () => {
  const child = fork(bridge, ["--input-mode", "serial"], {
    cwd: root,
    silent: true,
    env: { ...process.env, SESSION_HUB_SCANNER_HOSTNAME: "pc-1", SESSION_HUB_SERIALPORT_MODULE: fake, SESSION_HUB_BASE_URL: "" },
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => (stderr += chunk.toString()));
  const code = await new Promise((resolve) => child.on("exit", resolve));
  assert.notEqual(code, 0);
  assert.match(stderr, /base-url/);
});

test("no shared default host id, display name, serial port or server address in the bridge", () => {
  const text = fs.readFileSync(bridge, "utf8");
  for (const forbidden of ["sucursal-1-caja-1", "Scanner Caja 1", "COM6", "devapp", "dimensioncomercial"])
    assert.equal(text.includes(forbidden), false, "bridge.js still carries " + forbidden);
});

test("installation id is generated once, is not a credential, and is stable across restarts", async () => {
  const dir = tmpDir();
  let first;
  const one = await start({ dir, hostname: "pc-id", onMessage: autoRegister });
  try {
    await eventually(() => one.register(), "no register");
    first = one.register().message.payload.installation_id;
    assert.match(first, /^[A-Za-z0-9_-]{8,64}$/);
    assert.equal(JSON.stringify(one.logs).includes(first), false, "id must not be written to the log");
  } finally {
    await one.stop(true);
  }
  const two = await start({ dir, hostname: "pc-id", onMessage: autoRegister });
  try {
    await eventually(() => two.register(), "no register after restart");
    assert.equal(two.register().message.payload.installation_id, first, "id changed after restart");
  } finally {
    await two.stop();
  }
  const other = await start({ hostname: "pc-id", onMessage: autoRegister });
  try {
    await eventually(() => other.register(), "no register for the other PC");
    assert.notEqual(other.register().message.payload.installation_id, first, "two installations share an id");
  } finally {
    await other.stop();
  }
});

test("SCANNER_HOST_ID_IN_USE: reports the conflict, stops its readers and does not reconnect in a loop", async () => {
  const run = await start({
    hostname: "pc-dup",
    ports: [{ path: "COM3", vendorId: "0c2e", productId: "0b61", serialNumber: "S" }],
    onMessage({ socket, message }) {
      if (message.type !== "scanner.register") return;
      socket.send(
        JSON.stringify({
          type: "scanner.registered",
          payload: { ok: false, error_code: "SCANNER_HOST_ID_IN_USE", host_id: "pc-dup", retry: false, message: "Ya hay otra instalacion activa con este nombre." },
        }),
      );
      socket.close(4409);
    },
  });
  try {
    await eventually(() => run.logs.some((line) => line.status === "host.conflict"), "conflict was not reported");
    await eventually(() => run.state() && run.state().host_state === "host_conflict", "state file does not say host_conflict");
    await sleep(3200); // base reconnect delays are 1 s, 2 s, 4 s
    assert.equal(run.connections.length, 1, "the agent reconnected after the rejection");
    assert.equal(run.logs.some((line) => line.label === "bridge.status" && line.status === "reconnecting"), false);
    assert.equal(run.exitCode(), null, "the agent must stay alive (an exit would make the scheduled task loop)");
    assert.equal(run.logs.filter((line) => line.status === "serial.reader.open").length, 0, "no reader may stay open while in conflict");
  } finally {
    await run.stop();
  }
});

test("scanner.superseded from the server stops reconnecting (the same installation opened another connection)", async () => {
  const run = await start({
    hostname: "pc-sup",
    onMessage({ socket, message }) {
      if (message.type !== "scanner.register") return;
      socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
      setTimeout(() => {
        socket.send(JSON.stringify({ type: "scanner.superseded", payload: { host_id: "pc-sup" } }));
        socket.close(4410);
      }, 150);
    },
  });
  try {
    await eventually(() => run.logs.some((line) => line.status === "host.superseded"), "superseded not reported");
    await sleep(2500);
    assert.equal(run.connections.length, 1);
  } finally {
    await run.stop();
  }
});

test("a stale socket that closes late does not stop the agent from reconnecting normally", async () => {
  let drops = 0;
  const run = await start({
    hostname: "pc-net",
    onMessage({ socket, message }) {
      if (message.type !== "scanner.register") return;
      socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
      if (drops === 0) {
        drops += 1;
        setTimeout(() => socket.close(), 100);
      }
    },
  });
  try {
    await eventually(() => run.connections.length >= 2, "normal network drop must still reconnect", 200);
  } finally {
    await run.stop();
  }
});

test("server rejection BOUND_TO_OTHER_TARGET or PAIRING_CONFLICT_ACTIVE_OWNER drops the scan, no retry", async () => {
  for (const code of ["CONTROL_STOCK_SCANNER_BOUND_TO_OTHER_TARGET", "PAIRING_CONFLICT_ACTIVE_OWNER"]) {
    const run = await start({
      hostname: "pc-bind",
      args: ["--ack-timeout-ms", "300", "--input-mode", "stdin"],
      onMessage({ socket, message }) {
        if (message.type === "scanner.register") socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
        if (message.type === "scanner.scan")
          socket.send(JSON.stringify({ type: "scanner.ack", payload: { scan_id: message.payload.scan_id, ok: false, reason_code: code } }));
      },
    });
    try {
      await eventually(() => run.register(), "no register");
      run.child.stdin.write(":scan 123\n");
      await eventually(() => run.scans().length === 1, "scan not sent");
      await sleep(1600);
      assert.equal(run.scans().length, 1, code + " was retried");
      assert.ok(run.logs.some((line) => line.status === "scanner.scan.failed" && line.reason === code), "failure not shown");
    } finally {
      await run.stop();
    }
  }
});

test("temporary MOBILE_CLIENT_NOT_CONNECTED still retries the same scan_id", async () => {
  let answered = 0;
  const run = await start({
    hostname: "pc-temp",
    args: ["--input-mode", "stdin"],
    onMessage({ socket, message }) {
      if (message.type === "scanner.register") socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
      if (message.type === "scanner.scan") {
        answered += 1;
        socket.send(
          JSON.stringify({
            type: "scanner.ack",
            payload: answered === 1 ? { scan_id: message.payload.scan_id, ok: false, reason_code: "MOBILE_CLIENT_NOT_CONNECTED" } : { scan_id: message.payload.scan_id, ok: true },
          }),
        );
      }
    },
  });
  try {
    await eventually(() => run.register(), "no register");
    run.child.stdin.write(":scan 456\n");
    await eventually(() => run.scans().length >= 2, "temporary rejection was not retried", 200);
    assert.equal(run.scans()[0].message.payload.scan_id, run.scans()[1].message.payload.scan_id);
  } finally {
    await run.stop();
  }
});
