const WebSocket = require("ws");
const readline = require("readline");
const crypto = require("crypto");
const path = require("path");
const fs = require("fs");
const os = require("os");

function log(label, payload) {
  console.log(
    JSON.stringify({ label, ts: new Date().toISOString(), ...(payload || {}) }),
  );
}
// Flags given with no value (`--host-id` followed by another flag, or at the
// end) become "true" in `out`; `bareFlags` remembers them so that a name can
// never silently be the text "true".
const bareFlags = new Set();
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
    } else {
      out[key] = "true";
      bareFlags.add(key);
    }
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

// ---------------------------------------------------------------------------
// Station identity and reader identity helpers.
// The station name is the hostname; the reader is a device (VID:PID and, when
// the device reports it, a serial number), never a COM number.
// ---------------------------------------------------------------------------
const HOST_ID_MAX = 40;
function normalizeHostId(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .slice(0, HOST_ID_MAX)
    .replace(/-+$/, "");
}
// SESSION_HUB_SCANNER_HOSTNAME exists for tests only.
function rawHostname() {
  const name = first(
    process.env.SESSION_HUB_SCANNER_HOSTNAME,
    os.hostname(),
    process.env.COMPUTERNAME,
  );
  return name === undefined ? "" : String(name).trim();
}
function hex4(value) {
  const text = String(value === undefined || value === null ? "" : value)
    .trim()
    .toLowerCase()
    .replace(/^0x/, "");
  return /^[0-9a-f]{1,4}$/.test(text) ? text.padStart(4, "0") : null;
}
function isBluetoothPort(port) {
  return /BTHENUM|Bluetooth/i.test(
    [port.pnpId, port.manufacturer, port.friendlyName, port.path, port.locationId]
      .filter(Boolean)
      .join(" "),
  );
}
// A real USB serial port: it reports vendor and product and is not Bluetooth.
function usbPortInfo(port) {
  if (!port || typeof port !== "object") return null;
  const portPath = getPath(port);
  const vendor = hex4(port.vendorId);
  const product = hex4(port.productId);
  if (!portPath || !vendor || !product || isBluetoothPort(port)) return null;
  return {
    port: portPath,
    vendor_id: vendor,
    product_id: product,
    serial_number: String(port.serialNumber || "").trim() || null,
    description:
      String(port.manufacturer || port.friendlyName || "")
        .trim()
        .slice(0, 60) || null,
  };
}
function sameDevice(identity, info) {
  return Boolean(
    identity &&
      info &&
      identity.vendor_id === info.vendor_id &&
      identity.product_id === info.product_id &&
      (!identity.serial_number ||
        same(identity.serial_number, info.serial_number)),
  );
}
function usbDeviceLabel(info) {
  return (
    info.vendor_id +
    ":" +
    info.product_id +
    (info.serial_number ? "/" + info.serial_number : "")
  );
}
function parseUsbId(value) {
  const match = /^\s*([0-9a-fx]{1,6}):([0-9a-fx]{1,6})(?:\/(.+?))?\s*$/i.exec(
    String(value || ""),
  );
  if (!match) return null;
  const vendor = hex4(match[1]);
  const product = hex4(match[2]);
  if (!vendor || !product) return null;
  return {
    vendor_id: vendor,
    product_id: product,
    serial_number: match[3] ? match[3].trim() : null,
  };
}
function writeJsonAtomic(file, value) {
  const tmp = file + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}
function readIdentityFile(file) {
  if (!file) return null;
  try {
    const parsed = JSON.parse(
      fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""),
    );
    const vendor = hex4(parsed.vendor_id);
    const product = hex4(parsed.product_id);
    if (!vendor || !product) return null;
    return {
      vendor_id: vendor,
      product_id: product,
      serial_number: parsed.serial_number
        ? String(parsed.serial_number)
        : null,
      description: parsed.description ? String(parsed.description) : null,
      source: parsed.source === "user" ? "user" : "auto",
    };
  } catch (error) {
    if (!error || error.code !== "ENOENT")
      log("bridge.error", {
        status: "reader.identity.unreadable",
        message: error && error.message,
      });
    return null;
  }
}
// Generated once per PC and kept; a technical id, not a credential. It is never
// written to the log.
function loadInstallationId(file) {
  const valid = (value) =>
    typeof value === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(value);
  if (file) {
    try {
      const parsed = JSON.parse(
        fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""),
      );
      if (valid(parsed.installation_id)) return parsed.installation_id;
    } catch (_) {}
  }
  const id = crypto.randomUUID
    ? crypto.randomUUID()
    : crypto.randomBytes(16).toString("hex");
  if (!file) {
    log("bridge.status", { status: "installation.id.ephemeral" });
    return id;
  }
  try {
    writeJsonAtomic(file, {
      schema: "session-hub-scanner-installation/v1",
      installation_id: id,
      created_at: new Date().toISOString(),
    });
  } catch (error) {
    log("bridge.error", {
      status: "installation.id.save_failed",
      message: error.message,
    });
  }
  return id;
}

const raw = argsOf(process.argv.slice(2));
const legacy = {
  reader_id: first(
    raw["reader-id"],
    process.env.SESSION_HUB_SCANNER_READER_ID,
    process.env.SESSION_HUB_SCANNER_DEVICE_ID,
    "reader-1",
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
for (const key of ["host-id", "display-name", "base-url"])
  if (bareFlags.has(key))
    throw new Error("--" + key + " needs a value (it was given empty)");
const requestedInputMode = String(
  first(raw["input-mode"], process.env.SESSION_HUB_SCANNER_INPUT_MODE, "stdin"),
).toLowerCase();
const cfg = {
  baseUrl: first(raw["base-url"], process.env.SESSION_HUB_BASE_URL),
  // No shared default: the station is its hostname unless declared.
  hostId:
    first(raw["host-id"], process.env.SESSION_HUB_SCANNER_HOST_ID) ||
    normalizeHostId(rawHostname()),
  displayName: first(
    raw["display-name"],
    process.env.SESSION_HUB_SCANNER_DISPLAY_NAME,
    rawHostname(),
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
  autoPollMs: Math.max(
    100,
    posInt(
      first(raw["auto-poll-ms"], process.env.SESSION_HUB_SCANNER_AUTO_POLL_MS),
      3000,
    ),
  ),
  readerUsbId: first(
    raw["reader-usb-id"],
    process.env.SESSION_HUB_SCANNER_READER_USB_ID,
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
if (!cfg.baseUrl)
  throw new Error(
    "base-url is required: there is no default server address (use --base-url)",
  );
if (!cfg.hostId)
  throw new Error(
    "host-id could not be derived from the hostname; pass --host-id",
  );
if (!cfg.displayName) cfg.displayName = cfg.hostId;
const usbPin = cfg.readerUsbId ? parseUsbId(cfg.readerUsbId) : null;
if (cfg.readerUsbId && !usbPin)
  throw new Error("reader-usb-id must look like vvvv:pppp or vvvv:pppp/serial");
const siblingOfState = (name) =>
  cfg.stateFile ? path.join(path.dirname(cfg.stateFile), name) : null;
cfg.identityFile =
  first(raw["identity-file"], process.env.SESSION_HUB_SCANNER_IDENTITY_FILE) ||
  siblingOfState("reader-identity.json");
cfg.installationFile =
  first(
    raw["installation-file"],
    process.env.SESSION_HUB_SCANNER_INSTALLATION_FILE,
  ) || siblingOfState("installation-id.json");
cfg.uiDir =
  first(raw["ui-dir"], process.env.SESSION_HUB_SCANNER_UI_DIR) ||
  siblingOfState("ui");
cfg.installationId = loadInstallationId(cfg.installationFile);
const endpoint = wsUrl(cfg.baseUrl);
// Automatic mode: nothing pins the reader (no COM, no device id, no readers
// list). The agent then finds the USB reader by device identity.
const readers = new Map(
  readerConfig.map((item) => {
    const auto =
      item.legacy && !item.serial_port && !item.scanner_device_id;
    return [
      item.reader_id,
      {
        ...item,
        mode: auto ? "auto" : "pinned",
        buffer: "",
        port: null,
        activePath: null,
        activeDevice: null,
        activeUsb: null,
        retry: null,
        autoTimer: null,
        attempts: 0,
        state: auto ? "waiting" : "pending",
        connecting: false,
        identity: auto ? readIdentityFile(cfg.identityFile) : null,
        pin: auto && usbPin ? { ...usbPin, source: "user" } : null,
        candidates: [],
        pendingChoice: null,
        lastFailure: null,
        candidatesSignature: "",
      },
    ];
  }),
);
let hostState = "ok"; // ok | host_conflict | superseded
let lastChoice = null;
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
    display_name: cfg.displayName,
    host_state: hostState,
    reader_choice: lastChoice,
    started_at: new Date(startedAtMs).toISOString(),
    updated_at: new Date().toISOString(),
    ws_ready: ready,
    registered_once: registeredOnce,
    queue_length: queue.length,
    in_flight: Boolean(inFlight),
    pending_total: pendingTotal(),
    partial_input: partialInput(),
    last_capture_at: lastCaptureMs ? new Date(lastCaptureMs).toISOString() : null,
    readers: states(true),
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
function states(withCandidates) {
  return Array.from(readers.values()).map((reader) => {
    const out = {
      reader_id: reader.reader_id,
      scanner_device_id:
        reader.activeDevice || reader.scanner_device_id || null,
      serial_port: reader.activePath || reader.serial_port || null,
      state: reader.state,
    };
    if (reader.mode !== "auto") return out;
    const device = reader.activeUsb || reader.pin || reader.identity || null;
    out.mode = "auto";
    out.vendor_id = device ? device.vendor_id : null;
    out.product_id = device ? device.product_id : null;
    out.serial_number = device ? device.serial_number || null : null;
    if (withCandidates || reader.state === "ambiguous")
      out.candidates = reader.candidates.map((info) => ({ ...info }));
    return out;
  });
}
// The heartbeat replaces `capabilities` on the server when it is non-empty, so
// both register and heartbeat send the complete object, readers included.
function capabilitiesSnapshot() {
  return {
    bridge: "session_hub_scanner_bridge",
    bridge_version: bridgeVersion,
    input_mode: cfg.inputMode,
    multi_reader: cfg.readersConfigured,
    capture_mode: "host_owned_scanner",
    claim_via: "mobile_claim_qr",
    handoff_via: "scanner_routed_backend_handoff",
    readers: states(),
  };
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
    installation_id: cfg.installationId,
    scanner_device_id: primary.scanner_device_id || null,
    heartbeat_interval_ms: cfg.heartbeatMs,
    capabilities: capabilitiesSnapshot(),
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
  if (index < 0) {
    // A timer can fire a millisecond before `notBefore`; without this the
    // retry would sit in the queue until the next unrelated flush.
    const waiting = queue.map((item) => item.notBefore || 0).filter(Boolean);
    if (waiting.length)
      setTimeout(flush, Math.max(5, Math.min(...waiting) - Date.now() + 5));
    return;
  }
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
    // The server acknowledges every heartbeat with a scan-less ack: not an error.
    const kind = String((payload && (payload.kind || payload.ack_kind)) || "");
    if (kind === "heartbeat") return;
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
// Wires an opened port to its reader: parsing, errors and close handling.
function attachPort(reader, port, portPath, device, usbInfo) {
  reader.port = port;
  reader.activePath = portPath;
  reader.activeDevice = device;
  reader.activeUsb = usbInfo || null;
  reader.buffer = "";
  reader.state = "open";
  reader.attempts = 0;
  reader.lastFailure = null;
  markState();
  port.on("data", (chunk) => {
    if (reader.port !== port) return;
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
    // A port we closed on purpose, or replaced, must not touch the new one.
    if (reader.port !== port) return;
    const closedPath = reader.activePath;
    reader.port = null;
    reader.state = "disconnected";
    if (reader.mode === "auto") {
      reader.activePath = null;
      reader.activeDevice = null;
      reader.activeUsb = null;
    }
    markState();
    log("bridge.status", {
      status: "serial.reader.closed",
      reader_id: reader.reader_id,
      port: closedPath,
    });
    if (reader.mode !== "auto") scheduleReader(reader, "serial port closed");
  });
  log("bridge.status", {
    status: "serial.reader.open",
    reader_id: reader.reader_id,
    scanner_device_id: reader.activeDevice,
    port: reader.activePath,
    mode: reader.mode,
  });
}
function closeReaderPort(reader, reason) {
  const port = reader.port;
  reader.port = null;
  if (reader.mode === "auto") {
    reader.activePath = null;
    reader.activeDevice = null;
    reader.activeUsb = null;
  }
  reader.buffer = "";
  reader.state = "disconnected";
  markState();
  log("bridge.status", {
    status: "serial.reader.closed",
    reader_id: reader.reader_id,
    reason,
  });
  if (port) {
    try {
      port.close(() => {});
    } catch (_) {}
  }
}
async function startReader(reader) {
  if (stopped || reader.port || reader.connecting) return;
  if (reader.mode === "auto") return startAuto(reader);
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
    attachPort(reader, port, selected.path, selected.device, null);
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

// ---------------------------------------------------------------------------
// Automatic reader detection (no COM number anywhere).
//  - candidate = real USB serial port (VID/PID present), never Bluetooth;
//  - a remembered/chosen identity opens only the matching port; if it is not
//    there the reader waits (it never takes another device);
//  - with no identity: one candidate is opened and remembered, more than one is
//    "ambiguous" and nothing is opened until the user chooses.
// ---------------------------------------------------------------------------
function decideAuto(reader, usbList) {
  const wanted = reader.pin || reader.identity;
  if (wanted) {
    const matches = usbList.filter((info) => sameDevice(wanted, info));
    if (matches.length === 1) return { state: "open", target: matches[0] };
    if (matches.length > 1) return { state: "ambiguous" };
    return { state: "waiting" };
  }
  if (usbList.length === 1)
    return { state: "open", target: usbList[0], learn: true };
  if (usbList.length > 1) return { state: "ambiguous" };
  return { state: "waiting" };
}
function setAutoState(reader, state) {
  if (reader.state === state) return;
  reader.state = state;
  markState();
  log("bridge.status", {
    status: "serial.reader." + state,
    reader_id: reader.reader_id,
    candidates: state === "ambiguous" ? reader.candidates.length : undefined,
  });
}
function rememberIdentity(reader, info, source) {
  reader.identity = {
    vendor_id: info.vendor_id,
    product_id: info.product_id,
    serial_number: info.serial_number || null,
    description: info.description || null,
    source,
  };
  if (!cfg.identityFile) {
    log("bridge.status", { status: "reader.identity.not_persisted" });
    return;
  }
  try {
    fs.mkdirSync(path.dirname(cfg.identityFile), { recursive: true });
    writeJsonAtomic(cfg.identityFile, {
      schema: "session-hub-scanner-reader-identity/v1",
      reader_id: reader.reader_id,
      ...reader.identity,
      saved_at: new Date().toISOString(),
    });
    log("bridge.status", {
      status: "reader.identity.saved",
      reader_id: reader.reader_id,
      source,
    });
  } catch (error) {
    log("bridge.error", {
      status: "reader.identity.save_failed",
      reader_id: reader.reader_id,
      message: error.message,
    });
  }
}
function forgetIdentity(reader) {
  reader.identity = null;
  if (cfg.identityFile) {
    try {
      fs.unlinkSync(cfg.identityFile);
    } catch (error) {
      if (!error || error.code !== "ENOENT")
        log("bridge.error", {
          status: "reader.identity.forget_failed",
          message: error.message,
        });
    }
  }
}
function recordChoice(request, result, code) {
  lastChoice = {
    nonce: request.nonce,
    action: request.action,
    result,
    code: code || null,
    at: new Date().toISOString(),
  };
  log("bridge.status", {
    status: "reader.choice." + result,
    action: request.action,
    code: code || undefined,
  });
  markState();
}
// The icon (ordinary user) never writes the configuration: it drops a small
// request in the ui folder and the agent, which owns the files, validates it
// against the candidates it sees right now.
function pollChoiceRequest() {
  if (!cfg.uiDir || stopped) return false;
  const file = path.join(cfg.uiDir, "reader-choice.request.json");
  let text;
  try {
    const stat = fs.statSync(file);
    if (stat.size > 4096) {
      fs.unlinkSync(file);
      recordChoice({ nonce: null, action: null }, "rejected", "CHOICE_REQUEST_INVALID");
      return false;
    }
    text = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
  } catch (_) {
    return false;
  }
  try {
    fs.unlinkSync(file);
  } catch (error) {
    log("bridge.error", {
      status: "reader.choice.unlink_failed",
      message: error.message,
    });
    return false;
  }
  let request;
  try {
    request = JSON.parse(text);
  } catch (_) {
    recordChoice({ nonce: null, action: null }, "rejected", "CHOICE_REQUEST_INVALID");
    return false;
  }
  const action = request && request.action;
  const nonce = request && request.nonce ? String(request.nonce).slice(0, 64) : null;
  if (
    !request ||
    request.schema !== "session-hub-scanner-reader-choice/v1" ||
    !["select", "forget"].includes(action)
  ) {
    recordChoice({ nonce, action: null }, "rejected", "CHOICE_REQUEST_INVALID");
    return false;
  }
  const reader = Array.from(readers.values()).find((item) => item.mode === "auto");
  if (!reader) {
    recordChoice({ nonce, action }, "rejected", "CHOICE_NOT_APPLICABLE");
    return false;
  }
  reader.pendingChoice = { nonce, action, device: request.device || null };
  return true;
}
function applyPendingChoice(reader) {
  const request = reader.pendingChoice;
  reader.pendingChoice = null;
  if (!request) return;
  if (request.action === "forget") {
    forgetIdentity(reader);
    recordChoice(request, "applied");
    return;
  }
  const device = request.device && typeof request.device === "object" ? request.device : {};
  const wanted = {
    vendor_id: hex4(device.vendor_id),
    product_id: hex4(device.product_id),
    serial_number: device.serial_number ? String(device.serial_number).slice(0, 64) : null,
  };
  if (!wanted.vendor_id || !wanted.product_id) {
    recordChoice(request, "rejected", "CHOICE_REQUEST_INVALID");
    return;
  }
  const matches = reader.candidates.filter((info) => sameDevice(wanted, info));
  if (!matches.length) {
    recordChoice(request, "rejected", "CHOICE_NOT_A_CANDIDATE");
    return;
  }
  // The same VID:PID with no serial number twice cannot be told apart later.
  if (matches.length > 1) {
    recordChoice(request, "rejected", "CHOICE_NOT_IDENTIFIABLE");
    return;
  }
  rememberIdentity(reader, matches[0], "user");
  recordChoice(request, "applied");
}
function sameCandidates(reader) {
  const signature = JSON.stringify(reader.candidates);
  if (signature === reader.candidatesSignature) return;
  reader.candidatesSignature = signature;
  log("bridge.status", {
    status: "serial.reader.candidates",
    reader_id: reader.reader_id,
    candidates: reader.candidates,
  });
  markState();
}
async function autoTick(reader) {
  if (stopped || hostState !== "ok" || reader.connecting) return;
  reader.connecting = true;
  try {
    pollChoiceRequest();
    let mod;
    let ports;
    try {
      mod = serialModule();
      ports = await listPorts(mod);
    } catch (error) {
      if (reader.lastFailure !== error.message) {
        reader.lastFailure = error.message;
        log("bridge.error", {
          status: "serial.reader.list_failed",
          reader_id: reader.reader_id,
          message: error.message,
        });
      }
      return;
    }
    if (stopped || hostState !== "ok") return;
    reader.candidates = ports.map(usbPortInfo).filter(Boolean);
    sameCandidates(reader);
    applyPendingChoice(reader);
    const wanted = reader.pin || reader.identity;
    if (reader.port) {
      const present = ports.some((port) => same(getPath(port), reader.activePath));
      if (!present) closeReaderPort(reader, "port_vanished");
      else if (wanted && reader.activeUsb && !sameDevice(wanted, reader.activeUsb))
        closeReaderPort(reader, "another_reader_chosen");
      else return;
    }
    const decision = decideAuto(reader, reader.candidates);
    if (decision.state !== "open") {
      setAutoState(reader, decision.state);
      return;
    }
    const info = decision.target;
    try {
      const port = await openPort(mod, info.port, reader.serial_baud_rate);
      if (stopped || hostState !== "ok") {
        try {
          port.close(() => {});
        } catch (_) {}
        return;
      }
      attachPort(reader, port, info.port, usbDeviceLabel(info), info);
      if (decision.learn) rememberIdentity(reader, info, "auto");
    } catch (error) {
      reader.state = "failed";
      markState();
      if (reader.lastFailure !== error.message) {
        reader.lastFailure = error.message;
        log("bridge.error", {
          status: "serial.reader.failed",
          reader_id: reader.reader_id,
          requested_port: info.port,
          message: error.message,
        });
      }
    }
  } finally {
    reader.connecting = false;
  }
}
function startAuto(reader) {
  if (reader.autoTimer) return;
  reader.autoTimer = setInterval(() => autoTick(reader), cfg.autoPollMs);
  autoTick(reader);
}
function stopReaders() {
  readers.forEach((reader) => {
    if (reader.retry) clearTimeout(reader.retry);
    reader.retry = null;
    if (reader.autoTimer) clearInterval(reader.autoTimer);
    reader.autoTimer = null;
    if (reader.port) {
      const port = reader.port;
      reader.port = null;
      reader.activePath = null;
      reader.activeDevice = null;
      reader.activeUsb = null;
      reader.state = "disconnected";
      try {
        port.close(() => {});
      } catch (_) {}
    }
  });
}
// Terminal host states: the agent reports them and does not retry in a loop.
function enterHostState(next, status, extra) {
  if (hostState === next) return;
  hostState = next;
  ready = false;
  stopReaders();
  markState();
  log("bridge.error", { status, host_id: cfg.hostId, ...(extra || {}) });
  if (socket) {
    try {
      socket.close();
    } catch (_) {}
  }
}
function reconnect() {
  if (stopped || hostState !== "ok") return;
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
        capabilities: capabilitiesSnapshot(),
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
    hostState !== "ok" ||
    (socket &&
      [WebSocket.OPEN, WebSocket.CONNECTING].includes(socket.readyState))
  )
    return;
  const ws = new WebSocket(endpoint);
  socket = ws;
  ws.on("open", () => {
    if (ws !== socket) return;
    ready = false;
    reconnectAttempts = 0;
    log("bridge.connected", { endpoint, host_id: cfg.hostId });
    register();
  });
  ws.on("message", (rawMessage) => {
    // Events of a socket that was already replaced are not ours any more.
    if (ws !== socket) return;
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
    if (event === "scanner.registered" && payload.ok === false) {
      const code = String(payload.error_code || payload.code || "");
      if (code === "SCANNER_HOST_ID_IN_USE")
        enterHostState("host_conflict", "host.conflict", {
          error_code: code,
          message: payload.message || null,
        });
      else
        log("bridge.error", {
          status: "scanner.register.rejected",
          error_code: code || null,
        });
    } else if (event === "scanner.superseded") {
      enterHostState("superseded", "host.superseded");
    } else if (event === "scanner.registered") {
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
  ws.on("close", () => {
    if (ws !== socket) return;
    ready = false;
    markState();
    if (inFlight) retry(inFlight, "socket_disconnected", 0);
    reconnect();
  });
  ws.on("error", (error) =>
    log("bridge.error", { status: "ws.error", message: error.message }),
  );
}
function stop() {
  stopped = true;
  if (socket) socket.close();
  stopReaders();
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
      capabilities: capabilitiesSnapshot(),
      scanner_state: scannerStateSnapshot(),
      timestamp: new Date().toISOString(),
    }),
  cfg.heartbeatMs,
);
if (cfg.stateFile || cfg.drainFile || cfg.uiDir)
  setInterval(() => {
    if (pollChoiceRequest()) {
      const autoReader = Array.from(readers.values()).find((item) => item.mode === "auto");
      if (autoReader) autoTick(autoReader);
    }
    checkDrain();
    if (!exiting && cfg.stateFile) writeState();
  }, 1000);
if (cfg.inputMode === "stdin") startStdin("configured stdin mode");
else readers.forEach((reader) => startReader(reader));
process.on("SIGINT", () => {
  stop();
  process.exit(0);
});
