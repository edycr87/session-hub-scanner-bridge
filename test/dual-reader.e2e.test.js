const test = require("node:test");
const assert = require("node:assert/strict");
const { fork } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const { WebSocketServer } = require("ws");
const root = path.resolve(__dirname, "..");
const bridge = path.join(root, "bridge.js");
const fake = path.join(__dirname, "fixtures", "fake-serialport.js");
const ports = [
  { path: "COM6", serialNumber: "LEFT" },
  { path: "COM7", serialNumber: "RIGHT" },
];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function eventually(predicate, message) {
  for (let i = 0; i < 80; i += 1) {
    if (predicate()) return;
    await sleep(25);
  }
  assert.fail(message);
}
async function start(options = {}) {
  const messages = [];
  const server = new WebSocketServer({ port: 0 });
  await new Promise((resolve) => server.once("listening", resolve));
  server.on("connection", (socket) =>
    socket.on("message", (raw) => {
      const message = JSON.parse(raw);
      messages.push({ socket, message });
      if (message.type === "scanner.register") {
        if (
          !options.requireSecret ||
          message.payload.shared_secret === options.requireSecret
        )
          socket.send(
            JSON.stringify({ type: "scanner.registered", payload: {} }),
          );
        else
          socket.send(
            JSON.stringify({
              type: "session_hub.error",
              payload: { code: "SCANNER_AUTH_INVALID" },
            }),
          );
      }
      if (options.onMessage) options.onMessage({ socket, message, messages });
    }),
  );
  const readers = options.readers || [
    { reader_id: "left", serial_port: "COM6", scanner_device_id: "LEFT" },
    { reader_id: "right", serial_port: "COM7", scanner_device_id: "RIGHT" },
  ];
  const child = fork(
    bridge,
    [
      "--base-url",
      "http://127.0.0.1:" + server.address().port,
      "--host-id",
      "test-host",
      "--input-mode",
      "serial",
      ...(options.legacy
        ? ["--serial-port", options.legacyPort || "COM6"]
        : ["--readers", JSON.stringify(readers)]),
      "--ack-timeout-ms",
      String(options.ackTimeout || 500),
      ...(options.args || []),
    ],
    {
      cwd: root,
      silent: true,
      env: {
        ...process.env,
        SESSION_HUB_SERIALPORT_MODULE: fake,
        FAKE_SERIAL_PORTS: JSON.stringify(options.ports || ports),
      },
    },
  );
  const logs = [];
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
  await eventually(
    () => messages.some((entry) => entry.message.type === "scanner.register"),
    "bridge did not register",
  );
  return {
    child,
    server,
    messages,
    logs,
    emit(port, data) {
      child.send({ op: "data", port, data });
    },
    closePort(port) {
      child.send({ op: "close", port });
    },
    async close() {
      child.kill("SIGINT");
      await sleep(30);
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
function scans(run) {
  return run.messages.filter((entry) => entry.message.type === "scanner.scan");
}
function ack(entry) {
  entry.socket.send(
    JSON.stringify({
      type: "scanner.ack",
      payload: { scan_id: entry.message.payload.scan_id, ok: true },
    }),
  );
}
test("actual bridge isolates fragments, IDs and out-of-order ACKs", async () => {
  const run = await start();
  try {
    run.emit("COM6", "SA");
    run.emit("COM7", "SAME\n");
    run.emit("COM6", "ME\n");
    await eventually(() => scans(run).length === 1, "first scan missing");
    const first = scans(run)[0];
    first.socket.send(
      JSON.stringify({
        type: "scanner.ack",
        payload: { scan_id: "different-id", ok: true },
      }),
    );
    await sleep(60);
    assert.equal(scans(run).length, 1);
    ack(first);
    await eventually(() => scans(run).length === 2, "second scan missing");
    const second = scans(run)[1];
    assert.equal(first.message.payload.value, "SAME");
    assert.equal(second.message.payload.value, "SAME");
    assert.notEqual(
      first.message.payload.scan_id,
      second.message.payload.scan_id,
    );
    assert.notEqual(
      first.message.payload.reader_id,
      second.message.payload.reader_id,
    );
    assert.ok(first.message.payload.metadata.serial_port);
    ack(second);
  } finally {
    await run.close();
  }
});
test("same scan ID survives disconnect retry", async () => {
  let dropped = false;
  const run = await start({
    ackTimeout: 50,
    onMessage({ socket, message, messages }) {
      if (message.type === "scanner.scan" && !dropped) {
        dropped = true;
        socket.close();
      } else if (
        message.type === "scanner.scan" &&
        messages.filter((item) => item.message.type === "scanner.scan")
          .length >= 2
      )
        ack({ socket, message });
    },
  });
  try {
    run.emit("COM6", "RETRY\n");
    await eventually(() => scans(run).length >= 2, "scan did not retry");
    assert.equal(
      scans(run)[0].message.payload.scan_id,
      scans(run)[1].message.payload.scan_id,
    );
  } finally {
    await run.close();
  }
});
test("temporary backend ACK keeps the same ID and origin for retry", async () => {
  let retries = 0;
  const run = await start({
    onMessage({ socket, message }) {
      if (message.type !== "scanner.scan") return;
      retries += 1;
      if (retries === 1)
        socket.send(
          JSON.stringify({
            type: "scanner.ack",
            payload: {
              scan_id: message.payload.scan_id,
              ok: false,
              reason_code: "CONTROL_STOCK_CLIENT_NOT_CONNECTED",
            },
          }),
        );
      else ack({ socket, message });
    },
  });
  try {
    run.emit("COM7", "TEMPORAL\n");
    await eventually(
      () => scans(run).length >= 2,
      "temporary ACK did not retry",
    );
    assert.equal(
      scans(run)[0].message.payload.scan_id,
      scans(run)[1].message.payload.scan_id,
    );
    assert.equal(scans(run)[0].message.payload.reader_id, "right");
  } finally {
    await run.close();
  }
});
test("one COM disconnect leaves the other reader active", async () => {
  const run = await start();
  try {
    run.closePort("COM6");
    await sleep(30);
    run.emit("COM7", "ALIVE\n");
    await eventually(
      () => scans(run).length === 1,
      "healthy reader did not continue",
    );
    assert.equal(scans(run)[0].message.payload.reader_id, "right");
    ack(scans(run)[0]);
  } finally {
    await run.close();
  }
});
test("missing configured reader fails closed and one-reader legacy config works", async () => {
  const missing = await start({
    readers: [
      { reader_id: "missing", serial_port: "COM99", scanner_device_id: "NOPE" },
    ],
  });
  try {
    await eventually(
      () => missing.logs.some((line) => line.status === "serial.reader.failed"),
      "missing reader was not reported",
    );
    assert.equal(scans(missing).length, 0);
  } finally {
    await missing.close();
  }
  const legacy = await start({
    legacy: true,
    legacyPort: "COM6",
    ports: [ports[0]],
  });
  try {
    legacy.emit("COM6", "LEGACY\n");
    await eventually(() => scans(legacy).length === 1, "legacy reader failed");
    ack(scans(legacy)[0]);
  } finally {
    await legacy.close();
  }
});
test("installer and runner preserve readers configuration", () => {
  const installer = fs.readFileSync(
    path.join(root, "install-session-hub-scanner.ps1"),
    "utf8",
  );
  const runner = fs.readFileSync(
    path.join(root, "run-session-hub-bridge.ps1"),
    "utf8",
  );
  const tray = fs.readFileSync(
    path.join(root, "tray-session-hub-bridge.ps1"),
    "utf8",
  );
  assert.match(tray, /ReaderStates/);
  assert.match(tray, /BindingStatus/);
  assert.match(installer, /readers_json = \$Cfg\.ReadersJson/);
  assert.match(runner, /SESSION_HUB_SCANNER_READERS/);
  assert.match(runner, /SESSION_HUB_SCANNER_SHARED_SECRET/);
  assert.match(installer, /shared_secret = \$Cfg\.SharedSecret/);
  assert.match(runner, /scanner-bridge-config\.json/);
  assert.match(
    fs.readFileSync(path.join(root, "update-session-hub-scanner.ps1"), "utf8"),
    /Update-InstalledConfigVersion/,
  );
});

test("registration preserves shared-secret, symbology and local binding scanner state", async () => {
  const secret = "fixture-secret-only";
  const rejected = await start({ requireSecret: secret });
  try {
    await sleep(50);
    assert.equal(
      rejected.logs.some((line) => line.status === "scanner.registered"),
      false,
      "missing secret registered unexpectedly",
    );
  } finally {
    await rejected.close();
  }
  const run = await start({
    requireSecret: secret,
    args: ["--shared-secret", secret, "--symbology", "QR"],
    onMessage({ socket, message }) {
      if (message.type === "scanner.register") {
        assert.equal(message.payload.shared_secret, secret);
        assert.equal(message.payload.symbology, "QR");
        socket.send(
          JSON.stringify({
            type: "binding.updated",
            payload: {
              owner_mobile_session_id: "mobile-fixture",
              scanner_state: {
                status: "bound",
                target_type: "mobile",
                owner_mobile_session_id: "mobile-fixture",
              },
            },
          }),
        );
      }
    },
  });
  try {
    await eventually(
      () => run.logs.some((line) => line.status === "binding.bound"),
      "binding state was not observed",
    );
    run.emit("COM6", "AUTHED\n");
    await eventually(() => scans(run).length === 1, "scan missing");
    assert.equal(scans(run)[0].message.payload.symbology, "QR");
    assert.equal(
      scans(run)[0].message.payload.scanner_state.owner_mobile_session_id,
      "mobile-fixture",
    );
    assert.equal(
      run.logs.some((line) => JSON.stringify(line).includes(secret)),
      false,
      "secret leaked into local logs",
    );
    ack(scans(run)[0]);
  } finally {
    await run.close();
  }
});
test("delayed ACK after reconnect cannot consume a scan from the other reader", async () => {
  let firstId = null;
  let phase = 0;
  const run = await start({
    ackTimeout: 500,
    onMessage({ socket, message, messages }) {
      if (message.type !== "scanner.scan") return;
      if (phase === 0) {
        phase = 1;
        firstId = message.payload.scan_id;
        socket.close();
        return;
      }
      if (phase === 1) {
        phase = 2;
        ack({ socket, message });
        return;
      }
      if (phase === 2) {
        phase = 3;
        socket.send(
          JSON.stringify({
            type: "scanner.ack",
            payload: { scan_id: firstId, ok: true },
          }),
        );
        setTimeout(() => ack({ socket, message }), 60);
      }
    },
  });
  try {
    run.emit("COM6", "RECOVER-A\n");
    await eventually(
      () => scans(run).length >= 2,
      "first reader did not reconnect",
    );
    assert.equal(
      scans(run)[0].message.payload.scan_id,
      scans(run)[1].message.payload.scan_id,
    );
    run.emit("COM7", "RECOVER-B\n");
    await eventually(
      () => scans(run).length >= 3,
      "second reader scan missing",
    );
    const secondReaderId = scans(run)[2].message.payload.scan_id;
    await eventually(
      () =>
        run.logs.some(
          (line) =>
            line.status === "scanner.ack.unknown_scan_id" &&
            line.ack_id === firstId,
        ),
      "stale ACK was not rejected",
    );
    await sleep(20);
    assert.equal(scans(run)[2].message.payload.scan_id, secondReaderId);
  } finally {
    await run.close();
  }
});
