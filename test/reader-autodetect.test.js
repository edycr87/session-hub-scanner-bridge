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
const READER = { vendorId: "0c2e", productId: "0b61", serialNumber: "SN-A", manufacturer: "Scanner Co" };
const usb = (portPath, extra = {}) => ({ path: portPath, ...READER, ...extra });
const scale = { path: "COM8", vendorId: "0403", productId: "6001", serialNumber: "SCALE-1", manufacturer: "FTDI" };
const bluetooth = { path: "COM9", pnpId: "BTHENUM\\{00001101-0000-1000-8000-00805F9B34FB}\\7&2A", manufacturer: "Microsoft" };

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "scanner-autodetect-"));
}
function cleanup(dir) {
  for (const name of fs.readdirSync(dir)) {
    const entry = path.join(dir, name);
    if (fs.statSync(entry).isDirectory()) cleanup(entry);
    else fs.unlinkSync(entry);
  }
  fs.rmdirSync(dir);
}
// Boots the real bridge in auto mode (no serial port, no readers) against a
// local simulated server. `dir` keeps identity, state and the ui requests.
async function start(options = {}) {
  const dir = options.dir || tmpDir();
  const uiDir = path.join(dir, "ui");
  fs.mkdirSync(uiDir, { recursive: true });
  const messages = [];
  const connections = [];
  const server = new WebSocketServer({ port: 0 });
  await new Promise((resolve) => server.once("listening", resolve));
  server.on("connection", (socket) => {
    connections.push(socket);
    socket.on("message", (rawMessage) => {
      const message = JSON.parse(rawMessage);
      messages.push({ socket, message });
      if (message.type === "scanner.register" && !options.noRegistered)
        socket.send(JSON.stringify({ type: "scanner.registered", payload: { ok: true } }));
      if (options.onMessage) options.onMessage({ socket, message, messages });
    });
  });
  const child = fork(
    bridge,
    [
      "--base-url",
      "http://127.0.0.1:" + server.address().port,
      "--host-id",
      "test-host",
      "--input-mode",
      "serial",
      "--auto-poll-ms",
      "100",
      "--heartbeat-ms",
      "150",
      "--ack-timeout-ms",
      "500",
      "--state-file",
      path.join(dir, "bridge-state.json"),
      "--identity-file",
      path.join(dir, "reader-identity.json"),
      "--installation-file",
      path.join(dir, "installation-id.json"),
      "--ui-dir",
      uiDir,
      ...(options.args || []),
    ],
    {
      cwd: root,
      silent: true,
      env: {
        ...process.env,
        SESSION_HUB_SERIALPORT_MODULE: fake,
        FAKE_SERIAL_PORTS: JSON.stringify(options.ports || []),
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
  await eventually(() => messages.some((entry) => entry.message.type === "scanner.register"), "bridge did not register");
  const run = {
    dir,
    uiDir,
    child,
    server,
    messages,
    connections,
    logs,
    setPorts: (ports) => child.send({ op: "ports", ports }),
    addPort: (port) => child.send({ op: "add", port }),
    removePort: (portPath) => child.send({ op: "remove", path: portPath }),
    emit: (portPath, data) => child.send({ op: "data", port: portPath, data }),
    closePort: (portPath) => child.send({ op: "close", port: portPath }),
    scans: () => messages.filter((entry) => entry.message.type === "scanner.scan"),
    opened: () => logs.filter((line) => line.status === "serial.reader.open").map((line) => line.port),
    reader: () => {
      const beats = messages.filter((entry) => entry.message.type === "scanner.heartbeat");
      const last = beats[beats.length - 1];
      return last ? last.message.payload.readers[0] : null;
    },
    state: () => {
      try {
        return JSON.parse(fs.readFileSync(path.join(dir, "bridge-state.json"), "utf8"));
      } catch (_) {
        return null;
      }
    },
    readerState: () => {
      const state = run.state();
      return state && state.readers[0] ? state.readers[0].state : null;
    },
    identity: () => {
      try {
        return JSON.parse(fs.readFileSync(path.join(dir, "reader-identity.json"), "utf8"));
      } catch (_) {
        return null;
      }
    },
    choose(device, nonce = "n" + Date.now()) {
      fs.writeFileSync(
        path.join(uiDir, "reader-choice.request.json"),
        JSON.stringify({ schema: "session-hub-scanner-reader-choice/v1", action: "select", nonce, device }),
      );
      return nonce;
    },
    async stop(keepDir) {
      child.kill("SIGINT");
      await sleep(40);
      await new Promise((resolve) => server.close(resolve));
      if (!keepDir) cleanup(dir);
    },
  };
  return run;
}
function ack(entry) {
  entry.socket.send(JSON.stringify({ type: "scanner.ack", payload: { scan_id: entry.message.payload.scan_id, ok: true } }));
}

test("auto opens the only usb candidate and ignores bluetooth and non-usb ports", async () => {
  const run = await start({ ports: [usb("COM3"), bluetooth] });
  try {
    await eventually(() => run.opened().length === 1, "reader was not opened");
    assert.deepEqual(run.opened(), ["COM3"]);
    run.emit("COM3", "7791234567890\n");
    await eventually(() => run.scans().length === 1, "scan missing");
    assert.equal(run.scans()[0].message.payload.reader_id, "reader-1");
    assert.equal(run.scans()[0].message.payload.metadata.serial_port, "COM3");
    ack(run.scans()[0]);
    await eventually(() => run.identity(), "identity was not remembered");
    assert.equal(run.identity().vendor_id, "0c2e");
    assert.equal(run.identity().product_id, "0b61");
    assert.equal(run.identity().serial_number, "SN-A");
    assert.equal(run.identity().source, "auto");
  } finally {
    await run.stop();
  }
});

test("auto waits for a port that appears after start (the defect: reader on a port nobody configured)", async () => {
  const run = await start({ ports: [] });
  try {
    await eventually(() => run.readerState() === "waiting", "not waiting without a reader");
    assert.equal(run.opened().length, 0);
    run.addPort(usb("COM3"));
    await eventually(() => run.opened().includes("COM3"), "late reader was not picked up");
    run.emit("COM3", "LATE\n");
    await eventually(() => run.scans().length === 1, "scan from the late reader missing");
    assert.equal(run.scans()[0].message.payload.reader_id, "reader-1");
  } finally {
    await run.stop();
  }
});

test("two unknown usb candidates stay ambiguous and open none", async () => {
  const run = await start({ ports: [usb("COM3"), usb("COM4", { vendorId: "05e0", productId: "1200", serialNumber: "SN-B" })] });
  try {
    await eventually(() => run.readerState() === "ambiguous", "not ambiguous");
    await sleep(400);
    assert.equal(run.opened().length, 0, "must not open any candidate");
    assert.equal(run.identity(), null, "no identity may be persisted while ambiguous");
    await eventually(() => run.reader() && run.reader().state === "ambiguous", "heartbeat does not say ambiguous");
    assert.equal(run.reader().candidates.length, 2);
    assert.equal(run.state().readers[0].candidates.length, 2);
    assert.equal(run.state().readers[0].serial_port, null);
  } finally {
    await run.stop();
  }
});

test("same vid:pid twice without serial number stays ambiguous and does not move the binding by COM number", async () => {
  const dir = tmpDir();
  fs.writeFileSync(
    path.join(dir, "reader-identity.json"),
    JSON.stringify({ schema: "session-hub-scanner-reader-identity/v1", reader_id: "reader-1", vendor_id: "0c2e", product_id: "0b61", serial_number: null, source: "auto" }),
  );
  const noSerial = (p) => ({ path: p, vendorId: "0c2e", productId: "0b61" });
  const run = await start({ dir, ports: [noSerial("COM3"), noSerial("COM4")] });
  try {
    await eventually(() => run.readerState() === "ambiguous", "identical devices were not ambiguous");
    await sleep(300);
    assert.equal(run.opened().length, 0);
  } finally {
    await run.stop();
  }
});

test("same vid:pid with distinct serial numbers identifies each reader", async () => {
  const dir = tmpDir();
  fs.writeFileSync(
    path.join(dir, "reader-identity.json"),
    JSON.stringify({ schema: "session-hub-scanner-reader-identity/v1", reader_id: "reader-1", vendor_id: "0c2e", product_id: "0b61", serial_number: "SN-B", source: "user" }),
  );
  const run = await start({ dir, ports: [usb("COM3", { serialNumber: "SN-A" }), usb("COM4", { serialNumber: "SN-B" })] });
  try {
    await eventually(() => run.opened().length === 1, "known reader not opened");
    assert.deepEqual(run.opened(), ["COM4"]);
  } finally {
    await run.stop();
  }
});

test("a non reader serial device is never opened once the reader identity is learned", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.identity(), "identity not learned");
    run.setPorts([scale]);
    await eventually(() => run.readerState() === "waiting", "did not go back to waiting");
    await sleep(400);
    assert.deepEqual(run.opened(), ["COM3"], "the scale must not be opened");
  } finally {
    await run.stop();
  }
});

test("a different single usb device does not replace the remembered reader", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.identity(), "identity not learned");
    run.setPorts([usb("COM5", { vendorId: "1234", productId: "abcd", serialNumber: "OTHER" })]);
    await eventually(() => run.readerState() === "waiting", "did not wait");
    await sleep(400);
    assert.deepEqual(run.opened(), ["COM3"]);
  } finally {
    await run.stop();
  }
});

test("port disappears and returns with another COM number: reopens by device, same reader_id", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.opened().includes("COM3"), "not opened");
    run.emit("COM3", "BEFORE\n");
    await eventually(() => run.scans().length === 1, "first scan missing");
    ack(run.scans()[0]);
    run.removePort("COM3");
    run.closePort("COM3");
    await eventually(() => run.readerState() === "waiting" || run.readerState() === "disconnected", "disconnect not seen");
    run.addPort(usb("COM11"));
    await eventually(() => run.opened().includes("COM11"), "reader was not reopened on the new COM");
    run.emit("COM11", "AFTER\n");
    await eventually(() => run.scans().length === 2, "second scan missing");
    assert.equal(run.scans()[0].message.payload.reader_id, run.scans()[1].message.payload.reader_id);
    assert.equal(run.scans()[1].message.payload.reader_id, "reader-1");
    assert.equal(run.scans()[1].message.payload.metadata.serial_port, "COM11");
  } finally {
    await run.stop();
  }
});

test("an open reader that vanishes from the port list without a close event is detected", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.opened().includes("COM3"), "not opened");
    run.removePort("COM3");
    await eventually(() => run.readerState() === "waiting", "vanished port was not noticed");
    run.addPort(usb("COM6"));
    await eventually(() => run.opened().includes("COM6"), "not reopened");
  } finally {
    await run.stop();
  }
});

test("register and heartbeat carry the reader state and the active port", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.reader() && run.reader().state === "open", "heartbeat does not say open");
    const register = run.messages.find((entry) => entry.message.type === "scanner.register").message.payload;
    assert.ok(Array.isArray(register.capabilities.readers), "register has no capabilities.readers");
    assert.ok(["waiting", "open"].includes(register.capabilities.readers[0].state));
    const beat = run.messages.filter((entry) => entry.message.type === "scanner.heartbeat").pop().message.payload;
    assert.equal(beat.capabilities.readers[0].state, "open");
    assert.equal(beat.capabilities.readers[0].serial_port, "COM3");
    assert.equal(beat.capabilities.readers[0].vendor_id, "0c2e");
    assert.equal(beat.capabilities.readers[0].product_id, "0b61");
    // the heartbeat does not replace the registered capabilities with a fragment
    assert.equal(beat.capabilities.bridge, "session_hub_scanner_bridge");
  } finally {
    await run.stop();
  }
});

test("ambiguous: choosing one opens THAT device, persists it, and a restart remembers it", async () => {
  const dir = tmpDir();
  const ports = [usb("COM3", { serialNumber: "SN-A" }), usb("COM4", { serialNumber: "SN-B" })];
  const first = await start({ dir, ports });
  try {
    await eventually(() => first.readerState() === "ambiguous", "not ambiguous");
    first.choose({ vendor_id: "0c2e", product_id: "0b61", serial_number: "SN-B" });
    await eventually(() => first.opened().includes("COM4"), "chosen device was not opened");
    assert.deepEqual(first.opened(), ["COM4"]);
    await eventually(() => first.identity() && first.identity().source === "user", "choice not persisted");
    assert.equal(first.identity().serial_number, "SN-B");
    assert.equal(fs.existsSync(path.join(first.uiDir, "reader-choice.request.json")), false, "request was not consumed");
  } finally {
    await first.stop(true);
  }
  const second = await start({ dir, ports: [ports[1], ports[0]] });
  try {
    await eventually(() => second.opened().length === 1, "restart did not reopen the chosen reader");
    assert.deepEqual(second.opened(), ["COM4"]);
  } finally {
    await second.stop();
  }
});

test("the chosen reader disappears: the agent waits and does not take the other one", async () => {
  const run = await start({ ports: [usb("COM3", { serialNumber: "SN-A" }), usb("COM4", { serialNumber: "SN-B" })] });
  try {
    await eventually(() => run.readerState() === "ambiguous", "not ambiguous");
    run.choose({ vendor_id: "0c2e", product_id: "0b61", serial_number: "SN-A" });
    await eventually(() => run.opened().includes("COM3"), "chosen not opened");
    run.removePort("COM3");
    await eventually(() => run.readerState() === "waiting", "did not wait");
    await sleep(400);
    assert.deepEqual(run.opened(), ["COM3"], "must not fall back to the other reader");
    run.addPort(usb("COM12", { serialNumber: "SN-A" }));
    await eventually(() => run.opened().includes("COM12"), "chosen reader back on another COM was not reopened");
  } finally {
    await run.stop();
  }
});

test("a choice that is not a current candidate is rejected and changes nothing", async () => {
  const run = await start({ ports: [usb("COM3", { serialNumber: "SN-A" }), usb("COM4", { serialNumber: "SN-B" })] });
  try {
    await eventually(() => run.readerState() === "ambiguous", "not ambiguous");
    const nonce = run.choose({ vendor_id: "dead", product_id: "beef", serial_number: null });
    await eventually(() => run.state() && run.state().reader_choice && run.state().reader_choice.nonce === nonce, "no result reported");
    assert.equal(run.state().reader_choice.result, "rejected");
    assert.equal(run.state().reader_choice.code, "CHOICE_NOT_A_CANDIDATE");
    assert.equal(run.opened().length, 0);
    assert.equal(run.identity(), null);
    // malformed / oversized requests are ignored, not trusted
    fs.writeFileSync(path.join(run.uiDir, "reader-choice.request.json"), "x".repeat(10000));
    await sleep(300);
    assert.equal(run.opened().length, 0);
  } finally {
    await run.stop();
  }
});

test("identical devices without serial number cannot be chosen (not identifiable)", async () => {
  const noSerial = (p) => ({ path: p, vendorId: "0c2e", productId: "0b61" });
  const run = await start({ ports: [noSerial("COM3"), noSerial("COM4")] });
  try {
    await eventually(() => run.readerState() === "ambiguous", "not ambiguous");
    const nonce = run.choose({ vendor_id: "0c2e", product_id: "0b61", serial_number: null });
    await eventually(() => run.state().reader_choice && run.state().reader_choice.nonce === nonce, "no result");
    assert.equal(run.state().reader_choice.code, "CHOICE_NOT_IDENTIFIABLE");
    assert.equal(run.opened().length, 0);
  } finally {
    await run.stop();
  }
});

test("forget clears the remembered reader and allows a new one", async () => {
  const run = await start({ ports: [usb("COM3")] });
  try {
    await eventually(() => run.identity(), "identity not learned");
    fs.writeFileSync(
      path.join(run.uiDir, "reader-choice.request.json"),
      JSON.stringify({ schema: "session-hub-scanner-reader-choice/v1", action: "forget", nonce: "f1" }),
    );
    await eventually(() => run.identity() === null, "identity was not forgotten");
  } finally {
    await run.stop();
  }
});

test("manual pin by usb id wins over other candidates and over autodetection", async () => {
  const run = await start({
    args: ["--reader-usb-id", "0c2e:0b61/SN-B"],
    ports: [usb("COM3", { serialNumber: "SN-A" }), usb("COM4", { serialNumber: "SN-B" })],
  });
  try {
    await eventually(() => run.opened().length === 1, "pinned reader not opened");
    assert.deepEqual(run.opened(), ["COM4"]);
  } finally {
    await run.stop();
  }
});

test("a configured COM that does not exist still fails closed for an explicit pin", async () => {
  const run = await start({ args: ["--serial-port", "COM6"], ports: [usb("COM3")] });
  try {
    await eventually(() => run.logs.some((line) => line.status === "serial.reader.failed"), "explicit pin did not fail closed");
    await sleep(300);
    assert.equal(run.opened().length, 0);
  } finally {
    await run.stop();
  }
});
