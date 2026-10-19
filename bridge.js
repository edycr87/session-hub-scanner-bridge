const WebSocket = require("ws");
const readline = require("readline");
const crypto = require("crypto");
const path = require("path");
const fs = require("fs");

function log(label, payload) {
  console.log(
    JSON.stringify({ label, ts: new Date().toISOString(), ...(payload || {}) }),
  );
}
function argsOf(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const raw = argv[i];
    if (!raw.startsWith("--")) continue;
    const [key, inline] = raw.slice(2).split("=", 2);
    if (inline !== undefined) out[key] = inline;
    else if (argv[i + 1] && !argv[i + 1].startsWith("--")) {
      out[key] = argv[i + 1];
      i += 1;
    } else out[key] = "true";
  }
  return out;
}
function first(...items) {
  return items.find(
    (item) => item !== undefined && item !== null && String(item).trim() !== "",
  );
}
function posInt(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}
function wsUrl(baseUrl) {
  const url = new URL(baseUrl);
  if (!/^https?:$/.test(url.protocol))
    throw new Error("base-url must start with http:// or https://");
  return (
    (url.protocol === "https:" ? "wss:" : "ws:") +
    "//" +
    url.host +
    "/session-hub/scanner"
  );
}
function bool(value, fallback) {
  if (value === undefined || value === null) return fallback;
  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return fallback;
}
function scanId() {
  return crypto.randomUUID
    ? crypto.randomUUID()
    : crypto.randomBytes(16).toString("hex");
}
function normalize(value) {
  return String(value).replace(/\r/g, "").trim();
}
function getPath(port) {
  return typeof port === "string"
    ? port
    : port &&
        (port.path ||
          port.comName ||
          port.com_name ||
          port.portName ||
          port.name);
}
function candidate(port) {
  const serial = String(port.serialNumber || "").trim();
  const pnp = String(port.pnpId || "").trim();
  const usb = (
    String(port.vendorId || "") +
    ":" +
    String(port.productId || "")
  ).replace(/^:|:$/g, "");
  return {
    path: getPath(port),
    device: serial || pnp || usb || String(getPath(port) || "").toLowerCase(),
  };
}
function same(a, b) {
  return (
    String(a || "")
      .trim()
      .toLowerCase() ===
    String(b || "")
      .trim()
      .toLowerCase()
  );
}
function serialModule() {
  return process.env.SESSION_HUB_SERIALPORT_MODULE
    ? require(path.resolve(process.env.SESSION_HUB_SERIALPORT_MODULE))
    : require("serialport");
}
function serialCtor(mod) {
  return typeof mod === "function" ? mod : mod.SerialPort || mod.default;
}
function listPorts(mod) {
  const ctor = serialCtor(mod);
  const fn = mod.list || (ctor && ctor.list);
  if (!fn) return Promise.resolve([]);
  try {
    const result = fn.call(mod);
    if (result && result.then)
      return result.then((items) => (Array.isArray(items) ? items : []));
    if (Array.isArray(result)) return Promise.resolve(result);
  } catch (_) {}
  return new Promise((resolve) =>
    fn.call(mod, (_, items) => resolve(Array.isArray(items) ? items : [])),
  );
}
function openPort(mod, serialPath, baudRate) {
  const Ctor = serialCtor(mod);
  let port;
  try {
    port = new Ctor({ path: serialPath, baudRate, autoOpen: false });
  } catch (_) {
    port = new Ctor(serialPath, { baudRate, autoOpen: false });
  }
  return new Promise((resolve, reject) => {
    let done = false;
    const finish = (error) => {
      if (!done) {
        done = true;
        error ? reject(error) : resolve(port);
      }
    };
    port.once("open", () => finish());
    port.once("error", finish);
    try {
      const result = port.open(finish);
      if (result && result.then) result.then(() => finish()).catch(finish);
    } catch (error) {
      finish(error);
    }
  });
}

const raw = argsOf(process.argv.slice(2));
const legacy = {
  reader_id: first(
    raw["reader-id"],
    process.env.SESSION_HUB_SCANNER_READER_ID,
    process.env.SESSION_HUB_SCANNER_DEVICE_ID,
    raw["serial-port"],
    process.env.SESSION_HUB_SCANNER_SERIAL_PORT,
    "legacy",
  ),
  serial_port: first(
    raw["serial-port"],
    process.env.SESSION_HUB_SCANNER_SERIAL_PORT,
  ),
  scanner_device_id: first(
    raw["scanner-device-id"],
    raw["reader-id"],
    process.env.SESSION_HUB_SCANNER_DEVICE_ID,
    process.env.SESSION_HUB_SCANNER_READER_ID,
    process.env.SESSION_HUB_SCANNER_READER,
  ),
  serial_baud_rate: posInt(
    first(
      raw["serial-baud-rate"],
      process.env.SESSION_HUB_SCANNER_SERIAL_BAUD_RATE,
    ),
    9600,
  ),
  serial_wait_ms: posInt(
    first(
      raw["serial-wait-ms"],
      process.env.SESSION_HUB_SCANNER_SERIAL_WAIT_MS,
    ),
    1000,
  ),
  legacy: true,
};
const readersRaw = first(
  raw.readers,
  raw["readers-json"],
  process.env.SESSION_HUB_SCANNER_READERS,
);
let readerConfig;
if (readersRaw) {
  let parsed;
  try {
    parsed = JSON.parse(readersRaw);
  } catch (_) {
    throw new Error("readers must be a JSON array");
  }
  if (!Array.isArray(parsed) || !parsed.length)
    throw new Error("readers must be a non-empty JSON array");
  const ids = new Set();
  readerConfig = parsed.map((item, index) => {
    const reader_id = String(item.reader_id || item.readerId || "").trim();
    const serial_port = String(
      item.serial_port || item.serialPort || "",
    ).trim();
    const scanner_device_id = String(
      item.scanner_device_id || item.scannerDeviceId || item.device_id || "",
    ).trim();
    if (
      !reader_id ||
      (!serial_port && !scanner_device_id) ||
      ids.has(reader_id)
    )
      throw new Error(
        "each configured reader needs a unique reader_id and serial_port or scanner_device_id",
      );
    ids.add(reader_id);
    return {
      reader_id,
      serial_port: serial_port || null,
      scanner_device_id: scanner_device_id || null,
      serial_baud_rate: posInt(
        item.serial_baud_rate || item.serialBaudRate,
        legacy.serial_baud_rate,
      ),
      serial_wait_ms: posInt(
        item.serial_wait_ms || item.serialWaitMs,
        legacy.serial_wait_ms,
      ),
      legacy: false,
    };
  });
} else readerConfig = [legacy];
const requestedInputMode = String(
  first(raw["input-mode"], process.env.SESSION_HUB_SCANNER_INPUT_MODE, "stdin"),
).toLowerCase();
const cfg = {
  baseUrl: first(raw["base-url"], process.env.SESSION_HUB_BASE_URL),
  hostId: first(raw["host-id"], process.env.SESSION_HUB_SCANNER_HOST_ID),
  displayName: first(
    raw["display-name"],
    process.env.SESSION_HUB_SCANNER_DISPLAY_NAME,
    "Session Hub Scanner Bridge",
  ),
  inputMode: ["serial", "stdin"].includes(requestedInputMode)
    ? requestedInputMode
    : "stdin",
  requestedInputMode,
  heartbeatMs: posInt(
    first(raw["heartbeat-ms"], process.env.SESSION_HUB_SCANNER_HEARTBEAT_MS),
    10000,
  ),
  ackTimeoutMs: posInt(
    first(
      raw["ack-timeout-ms"],
      process.env.SESSION_HUB_SCANNER_ACK_TIMEOUT_MS,
    ),
    5000,
  ),
  maxPending: posInt(
    first(
      raw["max-pending-scans"],
      process.env.SESSION_HUB_SCANNER_MAX_PENDING_SCANS,
    ),
    30,
  ),
  sharedSecret: first(
    raw["shared-secret"],
    process.env.SESSION_HUB_SCANNER_SHARED_SECRET,
    process.env.SESSION_HUB_SCANNER_BRIDGE_SHARED_SECRET,
  ),
  symbology: first(
    raw.symbology,
    process.env.SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY,
  ),
  serialFallback: bool(
    first(
      raw["serial-fallback"],
      process.env.SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN,
    ),
    false,
  ),
  serialInteractive: bool(
    first(
      raw["serial-interactive"],
      process.env.SESSION_HUB_SCANNER_SERIAL_INTERACTIVE,
    ),
    false,
  ),
  readersConfigured: Boolean(readersRaw),
  stateFile: first(
    raw["state-file"],
    process.env.SESSION_HUB_SCANNER_STATE_FILE,
  ),
  drainFile: first(
    raw["drain-file"],
    process.env.SESSION_HUB_SCANNER_DRAIN_FILE,
  ),
  drainQuietMs: posInt(
    first(
      raw["drain-quiet-ms"],
      process.env.SESSION_HUB_SCANNER_DRAIN_QUIET_MS,
    ),
    3000,
  ),
};
if (!cfg.baseUrl || !cfg.hostId)
  throw new Error("base-url and host-id are required");
const endpoint = wsUrl(cfg.baseUrl);
const readers = new Map(
  readerConfig.map((item) => [
    item.reader_id,
    {
      ...item,
      buffer: "",
      port: null,
      activePath: null,
      activeDevice: null,
      retry: null,
      attempts: 0,
      state: "pending",
      connecting: false,
    },
  ]),
);
let socket;
let ready = false;
let stopped = false;
let reconnectAttempts = 0;
let inFlight = null;
let stdinCapture = null;
let stdinPartial = "";
let bindingStatus = null;
const queue = [];
// OTA support (opt-in): a local state file the updater reads to decide whether
// the host is idle, and a drain request file the updater writes to ask the
// bridge to exit by itself once no scan or ACK is pending. Nothing here is
// persisted across restarts: the queue stays in memory, so the updater must
// wait for it to be empty instead of killing the process.
function readBridgeVersion() {
  try {
    const value = fs
      .readFileSync(path.join(__dirname, "package-version.txt"), "utf8")
      .replace(/^\uFEFF/, "")
      .trim();
    if (value) return value;
  } catch (_) {}
  try {
    return String(require("./package.json").version || "0.0.0");
  } catch (_) {
    return "0.0.0";
  }
}
const bridgeVersion = readBridgeVersion();
const startedAtMs = Date.now();
let registeredOnce = false;
let lastCaptureMs = null;
let drainState = { requested: false, nonce: null, since: null };
let exiting = false;
let stateQueued = false;
const scannerState = {
  status: "ready",
  owner_mobile_session_id: null,
  target_type: "mobile",
};
function scannerStateSnapshot() {
  return { ...scannerState };
}
function partialInput() {
  return Boolean(stdinPartial) || Array.from(readers.values()).some((reader) => Boolean(reader.buffer));
}
function pendingTotal() {
  return queue.length + (inFlight ? 1 : 0);
}
function writeState(extra) {
  if (!cfg.stateFile) return;
  const snapshot = {
    schema: "session-hub-scanner-bridge-state/v1",
    pid: process.pid,
    version: bridgeVersion,
    host_id: cfg.hostId,
    started_at: new Date(startedAtMs).toISOString(),
    updated_at: new Date().toISOString(),
    ws_ready: ready,
    registered_once: registeredOnce,
    queue_length: queue.length,
    in_flight: Boolean(inFlight),
    pending_total: pendingTotal(),
    partial_input: partialInput(),
    last_capture_at: lastCaptureMs ? new Date(lastCaptureMs).toISOString() : null,
    readers: states(),
    drain: {
      requested: drainState.requested,
      nonce: drainState.nonce,
      since: drainState.since ? new Date(drainState.since).toISOString() : null,
    },
    drained: false,
    ...(extra || {}),
  };
  const tmp = cfg.stateFile + ".tmp-" + process.pid;
  try {
    fs.writeFileSync(tmp, JSON.stringify(snapshot));
    fs.renameSync(tmp, cfg.stateFile);
  } catch (error) {
    log("bridge.error", { status: "state.write.failed", message: error.message });
  }
}
function markState() {
  if (!cfg.stateFile || stateQueued || exiting) return;
  stateQueued = true;
  setImmediate(() => {
    stateQueued = false;
    if (!exiting) writeState();
  });
}
function readDrainRequest() {
  try {
    const text = fs
      .readFileSync(cfg.drainFile, "utf8")
      .replace(/^\uFEFF/, "")
      .trim();
    const parsed = JSON.parse(text);
    const requestedAt = Date.parse((parsed && parsed.requested_at) || "");
    // A request written before this process started is stale (for example a
    // power cut during a previous drain): it must never stop a fresh bridge.
    if (Number.isFinite(requestedAt) && requestedAt < startedAtMs) return null;
    return { nonce: String((parsed && parsed.nonce) || "") || "unnamed" };
  } catch (error) {
    if (error && error.code === "ENOENT") return null;
    // Present but unreadable/partial: treat as a request; it can only delay.
    return { nonce: "unreadable" };
  }
}
function checkDrain() {
  if (!cfg.drainFile || exiting) return;
  const request = readDrainRequest();
  if (!request) {
    if (drainState.requested) {
      log("bridge.status", { status: "drain.cancelled", nonce: drainState.nonce });
      drainState = { requested: false, nonce: null, since: null };
      markState();
    }
    return;
  }
  if (!drainState.requested || drainState.nonce !== request.nonce) {
    drainState = { requested: true, nonce: request.nonce, since: Date.now() };
    log("bridge.status", { status: "drain.requested", nonce: request.nonce });
    markState();
  }
  const quietSince = lastCaptureMs || startedAtMs;
  const idle =
    pendingTotal() === 0 &&
    !partialInput() &&
    Date.now() - quietSince >= cfg.drainQuietMs;
  if (!idle) return;
  exiting = true;
  writeState({ drained: true, drain_nonce: drainState.nonce, exit_reason: "drain" });
  log("bridge.status", { status: "drain.completed", nonce: drainState.nonce });
  stop();
  setTimeout(() => process.exit(0), 50);
}
function readBinding(payload) {
  return (
    (payload &&
      (payload.binding_status ||
        payload.binding ||
        payload.bindingStatus ||
        (payload.data &&
          (payload.data.binding_status || payload.data.binding)))) ||
    (payload.scanner_state ||
    payload.owner_mobile_session_id ||
    payload.bound_mobile ||
    payload.mobile_session_id
      ? payload
      : null)
  );
}
function applyBinding(next, event) {
  if (!next || typeof next !== "object") return;
  const prior =
    (bindingStatus &&
      (bindingStatus.owner_mobile_session_id ||
        bindingStatus.bound_mobile ||
        bindingStatus.mobile_session_id)) ||
    null;
  bindingStatus = next;
  const state = next.scanner_state || {};
  scannerState.status = state.status || scannerState.status;
  scannerState.target_type = state.target_type || scannerState.target_type;
  if (state.owner_mobile_session_id !== undefined)
    scannerState.owner_mobile_session_id = state.owner_mobile_session_id;
  const owner =
    next.owner_mobile_session_id ||
    next.bound_mobile ||
    next.mobile_session_id ||
    null;
  log("bridge.status", {
    status:
      owner !== prior
        ? owner
          ? "binding.bound"
          : "binding.released"
        : "binding.updated",
    source_event: event,
    owner_mobile_session_id: owner,
    binding_status: bindingStatus,
    scanner_state: scannerStateSnapshot(),
  });
}
function states() {
  return Array.from(readers.values()).map((reader) => ({
    reader_id: reader.reader_id,
    scanner_device_id: reader.activeDevice || reader.scanner_device_id || null,
    serial_port: reader.activePath || reader.serial_port || null,
    state: reader.state,
  }));
}
function send(type, payload) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return false;
  socket.send(JSON.stringify({ type, payload }));
  return true;
}
function register() {
  const primary = states()[0] || {};
  send("scanner.register", {
    host_id: cfg.hostId,
    display_name: cfg.displayName,
    scanner_device_id: primary.scanner_device_id || null,
    heartbeat_interval_ms: cfg.heartbeatMs,
    capabilities: {
      bridge: "session_hub_scanner_bridge",
      input_mode: cfg.inputMode,
      multi_reader: cfg.readersConfigured,
      capture_mode: "host_owned_scanner",
      claim_via: "mobile_claim_qr",
      handoff_via: "scanner_routed_backend_handoff",
    },
    scanner_state: scannerStateSnapshot(),
    metadata: {
      runtime: "node",
      pid: process.pid,
      scanner_device_id: primary.scanner_device_id || null,
      readers: states(),
    },
    ...(cfg.symbology ? { symbology: cfg.symbology } : {}),
    ...(cfg.sharedSecret ? { shared_secret: cfg.sharedSecret } : {}),
  });
}
function clearAck(scan) {
  if (scan && scan.timer) clearTimeout(scan.timer);
}
function retry(scan, reason, delay = 1000) {
  clearAck(scan);
  if (inFlight && inFlight.scan_id === scan.scan_id) inFlight = null;
  scan.notBefore = Date.now() + delay;
  if (!queue.some((item) => item.scan_id === scan.scan_id)) queue.unshift(scan);
  markState();
  log("bridge.status", {
    status: "scan.retry.scheduled",
    scan_id: scan.scan_id,
    reader_id: scan.reader_id,
    reason,
    delay_ms: delay,
  });
  setTimeout(flush, delay);
}
function fail(scan, reason) {
  clearAck(scan);
  if (inFlight && inFlight.scan_id === scan.scan_id) inFlight = null;
  markState();
  log("bridge.error", {
    status: "scanner.scan.failed",
    scan_id: scan.scan_id,
    reader_id: scan.reader_id,
    scanner_device_id: scan.scanner_device_id,
    serial_port: scan.serial_port,
    reason,
  });
  flush();
}
function flush() {
  if (!ready || inFlight) return;
  const index = queue.findIndex(
    (item) => !item.notBefore || item.notBefore <= Date.now(),
  );
  if (index < 0) return;
  const scan = queue.splice(index, 1)[0];
  const payload = {
    host_id: cfg.hostId,
    scan_id: scan.scan_id,
    reader_id: scan.reader_id,
    scanner_device_id: scan.scanner_device_id,
    value: scan.value,
    scanner_state: scan.scanner_state,
    metadata: {
      reader_id: scan.reader_id,
      scanner_device_id: scan.scanner_device_id,
      serial_port: scan.serial_port,
      source: scan.source,
      captured_at: scan.captured_at,
    },
    ...(cfg.symbology ? { symbology: cfg.symbology } : {}),
  };
  if (!send("scanner.scan", payload)) return retry(scan, "socket_not_ready");
  scan.attempts += 1;
  inFlight = scan;
  markState();
  log("bridge.scan", {
    status: "scan.outbound",
    ...payload,
    raw_value: scan.raw_value,
    attempt: scan.attempts,
  });
  scan.timer = setTimeout(() => retry(scan, "ack_timeout"), cfg.ackTimeoutMs);
}
function capture(reader, rawValue, source) {
  const value = normalize(rawValue);
  if (!value) return;
  if (queue.length + (inFlight ? 1 : 0) >= cfg.maxPending) {
    log("bridge.error", {
      status: "BRIDGE_QUEUE_LIMIT_EXCEEDED",
      reader_id: reader.reader_id,
      scanner_device_id:
        reader.activeDevice || reader.scanner_device_id || null,
      serial_port: reader.activePath || reader.serial_port || null,
      value,
    });
    return;
  }
  const scan = {
    scan_id: scanId(),
    reader_id: reader.reader_id,
    scanner_device_id: reader.activeDevice || reader.scanner_device_id || null,
    serial_port: reader.activePath || reader.serial_port || null,
    raw_value: String(rawValue),
    value,
    source,
    captured_at: new Date().toISOString(),
    scanner_state: scannerStateSnapshot(),
    attempts: 0,
  };
  queue.push(scan);
  lastCaptureMs = Date.now();
  markState();
  log("bridge.status", {
    status: "scan.captured",
    scan_id: scan.scan_id,
    reader_id: scan.reader_id,
    scanner_device_id: scan.scanner_device_id,
    serial_port: scan.serial_port,
    value,
  });
  flush();
}
function ack(payload) {
  const id =
    payload && (payload.scan_id || (payload.data && payload.data.scan_id));
  if (!id) {
    log("bridge.error", { status: "scanner.ack.unsupported_missing_scan_id" });
    return;
  }
  if (!inFlight || inFlight.scan_id !== id) {
    log("bridge.error", { status: "scanner.ack.unknown_scan_id", ack_id: id });
    return;
  }
  const scan = inFlight;
  const reason =
    payload.reason_code ||
    payload.code ||
    payload.error ||
    payload.message ||
    null;
  if (payload.ok !== false) {
    clearAck(scan);
    inFlight = null;
    markState();
    log("bridge.status", {
      status: "scanner.ack",
      ack_id: id,
      reader_id: scan.reader_id,
      ok: true,
    });
    flush();
    return;
  }
  if (
    [
      "MOBILE_CLIENT_NOT_CONNECTED",
      "PRESUPUESTADOR_OWNER_NOT_CONNECTED",
      "CONTROL_STOCK_CLIENT_NOT_CONNECTED",
    ].includes(String(reason))
  )
    retry(scan, reason);
  else fail(scan, reason || "ack_rejected");
}
async function choose(reader, ports) {
  const candidates = ports.map(candidate).filter((item) => item.path);
  const nonBluetooth = candidates.filter(
    (item) => !/BTHENUM|Bluetooth/i.test(item.device),
  );
  const usable = nonBluetooth.length ? nonBluetooth : candidates;
  if (reader.legacy && !reader.serial_port && !reader.scanner_device_id) {
    if (cfg.serialInteractive && process.stdin.isTTY && usable.length > 1) {
      const answer = await new Promise((resolve) => {
        const prompt = readline.createInterface({
          input: process.stdin,
          output: process.stdout,
        });
        prompt.question(
          "Seleccionar puerto serial (1-" + candidates.length + "): ",
          (value) => {
            prompt.close();
            resolve(Number(value));
          },
        );
      });
      return usable[answer - 1] || null;
    }
    return usable.find((item) => /^COM/i.test(item.path)) || usable[0] || null;
  }
  return (
    usable.find(
      (item) =>
        (!reader.serial_port || same(item.path, reader.serial_port)) &&
        (!reader.scanner_device_id ||
          same(item.device, reader.scanner_device_id)),
    ) || null
  );
}
function scheduleReader(reader, reason) {
  if (stopped || reader.retry) return;
  const delay = Math.min(
    30000,
    Math.max(1000, reader.serial_wait_ms) * Math.max(1, reader.attempts),
  );
  reader.retry = setTimeout(() => {
    reader.retry = null;
    startReader(reader);
  }, delay);
  log("bridge.status", {
    status: "serial.reader.wait",
    reader_id: reader.reader_id,
    reason,
    delay_ms: delay,
  });
}
async function startReader(reader) {
  if (stopped || reader.port || reader.connecting) return;
  reader.connecting = true;
  try {
    const mod = serialModule();
    const ports = await listPorts(mod);
    const selected = await choose(reader, ports);
    log("bridge.status", {
      status: "serial.reader.discovered",
      reader_id: reader.reader_id,
      requested_port: reader.serial_port || null,
      requested_device_id: reader.scanner_device_id || null,
      available: ports.map(candidate),
    });
    if (!selected)
      throw new Error(
        "configured reader was not found; refusing a different device",
      );
    const port = await openPort(mod, selected.path, reader.serial_baud_rate);
    reader.port = port;
    reader.activePath = selected.path;
    reader.activeDevice = selected.device;
    reader.buffer = "";
    reader.state = "open";
    reader.attempts = 0;
    markState();
    port.on("data", (chunk) => {
      reader.buffer += Buffer.isBuffer(chunk)
        ? chunk.toString("utf8")
        : String(chunk);
      const lines = reader.buffer.split(/\r\n|\n|\r/);
      reader.buffer = lines.pop();
      lines.forEach((line) => {
        if (normalize(line)) {
          log("bridge.serial", {
            status: "serial.parse",
            reader_id: reader.reader_id,
            scanner_device_id: reader.activeDevice,
            port: reader.activePath,
            line: normalize(line),
            raw_line: line,
          });
          capture(reader, line, "serial");
        }
      });
    });
    port.on("error", (error) =>
      log("bridge.error", {
        status: "serial.reader.error",
        reader_id: reader.reader_id,
        message: error.message,
      }),
    );
    port.on("close", () => {
      reader.port = null;
      reader.state = "disconnected";
      markState();
      log("bridge.status", {
        status: "serial.reader.closed",
        reader_id: reader.reader_id,
        port: reader.activePath,
      });
      scheduleReader(reader, "serial port closed");
    });
    log("bridge.status", {
      status: "serial.reader.open",
      reader_id: reader.reader_id,
      scanner_device_id: reader.activeDevice,
      port: reader.activePath,
    });
  } catch (error) {
    reader.state = "failed";
    reader.attempts += 1;
    markState();
    log("bridge.error", {
      status: "serial.reader.failed",
      reader_id: reader.reader_id,
      requested_port: reader.serial_port || null,
      requested_device_id: reader.scanner_device_id || null,
      message: error.message,
    });
    if (reader.legacy && cfg.serialFallback && !cfg.readersConfigured) {
      startStdin("serial fallback");
    } else {
      scheduleReader(reader, error.message);
    }
  } finally {
    reader.connecting = false;
  }
}
function reconnect() {
  if (stopped) return;
  const delay = Math.min(30000, 1000 * 2 ** reconnectAttempts++);
  log("bridge.status", { status: "reconnecting", delay_ms: delay });
  setTimeout(connect, delay);
}
function startStdin(reason) {
  if (stdinCapture) return;
  const reader = readers.values().next().value;
  stdinCapture = readline.createInterface({
    input: process.stdin,
    terminal: false,
  });
  // Keyboard/HID stdin can also be mid-scan when an OTA drain arrives.
  // Track the unfinished line without persisting its contents in the state file.
  process.stdin.on("data", (chunk) => {
    const text = stdinPartial + chunk.toString("utf8");
    stdinPartial = text.split(/[\r\n]/).pop();
    markState();
  });
  stdinCapture.on("line", (line) => {
    if (line === ":quit") stop();
    else if (line === ":heartbeat")
      send("scanner.heartbeat", {
        host_id: cfg.hostId,
        readers: states(),
        scanner_state: scannerStateSnapshot(),
        timestamp: new Date().toISOString(),
        reason: "manual",
      });
    else if (line === ":status")
      log("bridge.status", {
        status: "current",
        connected: Boolean(socket && socket.readyState === WebSocket.OPEN),
        binding_status: bindingStatus,
        scanner_state: scannerStateSnapshot(),
        readers: states(),
      });
    else if (line.startsWith(":scan ")) capture(reader, line.slice(6), "stdin");
    else if (line && !line.startsWith(":")) capture(reader, line, "stdin");
  });
  log("bridge.status", {
    status: "input.stdin.started",
    reason: reason || "configured stdin mode",
  });
}
function connect() {
  if (
    stopped ||
    (socket &&
      [WebSocket.OPEN, WebSocket.CONNECTING].includes(socket.readyState))
  )
    return;
  socket = new WebSocket(endpoint);
  socket.on("open", () => {
    ready = false;
    reconnectAttempts = 0;
    log("bridge.connected", { endpoint, host_id: cfg.hostId });
    register();
  });
  socket.on("message", (rawMessage) => {
    let message;
    try {
      message = JSON.parse(rawMessage.toString());
    } catch (_) {
      return;
    }
    const event = message.type || message.event || message.name;
    const payload =
      message.payload && typeof message.payload === "object"
        ? message.payload
        : message;
    if (event === "scanner.registered") {
      applyBinding(readBinding(payload), event);
      ready = true;
      registeredOnce = true;
      markState();
      log("bridge.status", {
        status: "scanner.registered",
        readers: states(),
        binding_status: bindingStatus,
        scanner_state: scannerStateSnapshot(),
      });
      flush();
    } else if (event === "binding.updated")
      applyBinding(readBinding(payload), event);
    else if (event === "scanner.ack") ack(payload);
    else log("bridge.message", { event, payload });
  });
  socket.on("close", () => {
    ready = false;
    markState();
    if (inFlight) retry(inFlight, "socket_disconnected", 0);
    reconnect();
  });
  socket.on("error", (error) =>
    log("bridge.error", { status: "ws.error", message: error.message }),
  );
}
function stop() {
  stopped = true;
  if (socket) socket.close();
  readers.forEach((reader) => {
    if (reader.retry) clearTimeout(reader.retry);
    if (reader.port) {
      try {
        reader.port.close();
      } catch (_) {}
    }
  });
}
if (cfg.requestedInputMode !== cfg.inputMode)
  log("bridge.status", {
    status: "input.mode.invalid",
    requested: cfg.requestedInputMode,
    using: cfg.inputMode,
  });
log("bridge.status", {
  status: "starting",
  host_id: cfg.hostId,
  input_mode: cfg.inputMode,
  readers: states(),
  endpoint,
  symbology: cfg.symbology || null,
});
connect();
setInterval(
  () =>
    send("scanner.heartbeat", {
      host_id: cfg.hostId,
      readers: states(),
      scanner_state: scannerStateSnapshot(),
      timestamp: new Date().toISOString(),
    }),
  cfg.heartbeatMs,
);
if (cfg.stateFile || cfg.drainFile)
  setInterval(() => {
    checkDrain();
    if (!exiting) writeState();
  }, 1000);
if (cfg.inputMode === "stdin") startStdin("configured stdin mode");
else readers.forEach((reader) => startReader(reader));
process.on("SIGINT", () => {
  stop();
  process.exit(0);
});
