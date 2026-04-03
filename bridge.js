const WebSocket = require('ws');
const readline = require('readline');
const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg.startsWith('--')) {
      const noPrefix = arg.slice(2);
      const eqIndex = noPrefix.indexOf('=');
      if (eqIndex >= 0) {
        const key = noPrefix.slice(0, eqIndex);
        const value = noPrefix.slice(eqIndex + 1);
        result[key] = value;
      } else {
        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith('--')) {
          result[noPrefix] = next;
          i += 1;
        } else {
          result[noPrefix] = 'true';
        }
      }
    }
  }

  return result;
}

function firstDefined(...values) {
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i];
    if (value !== undefined && value !== null && `${value}`.length > 0) {
      return value;
    }
  }
  return undefined;
}

function toNumber(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback;
}

function toBoolean(value, fallback) {
  if (value === undefined || value === null) {
    return fallback;
  }
  const normalized = `${value}`.trim().toLowerCase();
  if (normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on') {
    return true;
  }
  if (normalized === '0' || normalized === 'false' || normalized === 'no' || normalized === 'off') {
    return false;
  }
  return fallback;
}

function readJsonObject(filePath) {
  if (!filePath) {
    return {};
  }

  try {
    if (!fs.existsSync(filePath)) {
      return {};
    }
    const raw = fs.readFileSync(filePath, 'utf8');
    if (!raw || !`${raw}`.trim()) {
      return {};
    }
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (err) {
    pretty('bridge.error', {
      status: 'config.read_failed',
      config_path: filePath,
      error: err && err.message ? err.message : String(err),
    });
    return {};
  }
}

function writeJsonObject(filePath, payload) {
  if (!filePath) {
    return false;
  }

  try {
    fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
    return true;
  } catch (err) {
    pretty('bridge.error', {
      status: 'config.write_failed',
      config_path: filePath,
      error: err && err.message ? err.message : String(err),
    });
    return false;
  }
}

function normalizeRoutingMode(value, fallback = 'backend') {
  const normalized = `${value || ''}`.trim().toLowerCase();
  if (normalized === 'backend' || normalized === 'local_keyboard' || normalized === 'hybrid') {
    return normalized;
  }
  return fallback;
}

function resolveDefaultConfigPath() {
  const candidate = path.join(process.cwd(), 'scanner-bridge-config.json');
  return fs.existsSync(candidate) ? candidate : undefined;
}

function getBridgeVersion() {
  try {
    const packagePath = path.join(__dirname, 'package.json');
    if (!fs.existsSync(packagePath)) {
      return '0.0.0';
    }
    const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    return pkg && pkg.version ? `${pkg.version}` : '0.0.0';
  } catch (err) {
    return '0.0.0';
  }
}

function escapeSendKeysText(value) {
  const map = {
    '+': '{+}',
    '^': '{^}',
    '%': '{%}',
    '~': '{~}',
    '(': '{(}',
    ')': '{)}',
    '[': '{[}',
    ']': '{]}',
    '{': '{{}',
    '}': '{}}',
  };

  return `${value}`.split('').map((ch) => map[ch] || ch).join('');
}

function toEncodedPowerShell(script) {
  return Buffer.from(`${script}`, 'utf16le').toString('base64');
}

function resolveExternalModule(moduleName) {
  const candidates = [];
  const candidateRelativeToCwd = path.join(process.cwd(), 'node_modules', moduleName);
  const candidateRelativeToExec = path.join(path.dirname(process.execPath), 'node_modules', moduleName);
  const candidateRelativeToScript = path.join(__dirname, 'node_modules', moduleName);

  candidates.push(candidateRelativeToCwd, candidateRelativeToExec, candidateRelativeToScript);

  for (let i = 0; i < candidates.length; i += 1) {
    const candidate = candidates[i];
    try {
      if (candidate && fs.existsSync(candidate)) {
        const mod = require(candidate);
        if (mod) {
          return mod;
        }
      }
    } catch (err) {
      // try next candidate
    }
  }

  return null;
}

function normalizeScanValue(value) {
  return `${value}`.replace(/\r/g, '').trim();
}

function toWebSocketUrl(baseUrl) {
  const url = new URL(baseUrl);
  if (!/^https?:$/.test(url.protocol)) {
    throw new Error('base-url must start with http:// or https://');
  }

  const wsProtocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${wsProtocol}//${url.host}/session-hub/scanner`;
}

function pretty(label, payload) {
  const line = Object.assign({
    label,
    ts: new Date().toISOString(),
  }, payload || {});
  console.log(JSON.stringify(line, null, 2));
}

function extractEventName(payload) {
  return payload.type || payload.event || payload.name || 'unknown';
}

function getArgsOrEnv(argv) {
  const args = parseArgs(argv);
  const configPath = firstDefined(
    args['config-path'],
    process.env.SESSION_HUB_SCANNER_CONFIG_PATH,
    resolveDefaultConfigPath(),
  );
  const config = readJsonObject(configPath);

  const baseUrl = firstDefined(
    args['base-url'],
    process.env.SESSION_HUB_BASE_URL,
    config.base_url,
  );

  const hostId = firstDefined(
    args['host-id'],
    process.env.SESSION_HUB_SCANNER_HOST_ID,
    config.host_id,
  );

  const displayName = firstDefined(
    args['display-name'],
    process.env.SESSION_HUB_SCANNER_DISPLAY_NAME,
    config.display_name,
    'Session Hub Scanner Bridge',
  );

  const heartbeatMs = toNumber(
    firstDefined(
      args['heartbeat-ms'],
      process.env.SESSION_HUB_SCANNER_HEARTBEAT_MS,
      config.heartbeat_ms,
    ),
    10000,
  );

  const symbology = firstDefined(
    args['symbology'],
    process.env.SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY,
  );

  const sharedSecret = firstDefined(
    args['shared-secret'],
    process.env.SESSION_HUB_SCANNER_SHARED_SECRET,
    process.env.SESSION_HUB_SCANNER_BRIDGE_SHARED_SECRET,
  );

  const inputMode = firstDefined(
    args['input-mode'],
    process.env.SESSION_HUB_SCANNER_INPUT_MODE,
    config.input_mode,
    'stdin',
  );

  const serialPort = firstDefined(
    args['serial-port'],
    process.env.SESSION_HUB_SCANNER_SERIAL_PORT,
    config.serial_port,
  );

  const serialBaudRate = toNumber(
    firstDefined(
      args['serial-baud-rate'],
      args['serial-baud'],
      process.env.SESSION_HUB_SCANNER_SERIAL_BAUD_RATE,
      config.serial_baud_rate,
    ),
    9600,
  );

  const serialWaitMs = toNumber(
    firstDefined(
      args['serial-wait-ms'],
      process.env.SESSION_HUB_SCANNER_SERIAL_WAIT_MS,
      config.serial_wait_ms,
    ),
    0,
  );

  const serialFallbackToStdin = toBoolean(
    firstDefined(
      args['serial-fallback'],
      process.env.SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN,
      config.serial_fallback_to_stdin,
    ),
    false,
  );

  const serialInteractive = toBoolean(
    firstDefined(
      args['serial-interactive'],
      process.env.SESSION_HUB_SCANNER_SERIAL_INTERACTIVE,
      config.serial_interactive,
    ),
    false,
  );

  const scannerDeviceId = firstDefined(
    args['scanner-device-id'],
    args['reader-id'],
    process.env.SESSION_HUB_SCANNER_DEVICE_ID,
    process.env.SESSION_HUB_SCANNER_READER_ID,
    process.env.SESSION_HUB_SCANNER_READER,
    config.reader_device_id,
    config.scanner_device_id,
  );

  const routingMode = normalizeRoutingMode(firstDefined(
    args['routing-mode'],
    process.env.SESSION_HUB_SCANNER_ROUTING_MODE,
    config.routing_mode,
  ));

  const localKeyboardAppendEnter = toBoolean(firstDefined(
    args['local-keyboard-append-enter'],
    process.env.SESSION_HUB_SCANNER_LOCAL_KEYBOARD_APPEND_ENTER,
    config.local_keyboard_append_enter,
  ), true);

  const localKeyboardDryRun = toBoolean(firstDefined(
    args['local-keyboard-dry-run'],
    process.env.SESSION_HUB_SCANNER_LOCAL_KEYBOARD_DRY_RUN,
  ), false);

  const normalizedInputMode = ['stdin', 'serial'].includes(
    `${inputMode}`.trim().toLowerCase(),
  ) ? `${inputMode}`.trim().toLowerCase() : 'stdin';

  return {
    baseUrl,
    hostId,
    displayName,
    heartbeatMs,
    symbology: symbology || undefined,
    sharedSecret,
    inputMode: normalizedInputMode,
    serialPort: serialPort ? `${serialPort}`.trim() : undefined,
    serialBaudRate,
    serialWaitMs,
    serialFallbackToStdin,
    serialInteractive,
    scannerDeviceId: scannerDeviceId ? `${scannerDeviceId}`.trim() : undefined,
    requestedInputMode: `${inputMode}`.trim(),
    configPath,
    routingMode,
    localKeyboardAppendEnter,
    localKeyboardDryRun,
    bridgeVersion: getBridgeVersion(),
  };
}

const args = getArgsOrEnv(process.argv.slice(2));

if (!args.baseUrl) {
  pretty('bridge.error', {
    message: 'SESSION_HUB_BASE_URL or --base-url is required',
  });
  process.exit(1);
}

if (!args.hostId) {
  pretty('bridge.error', {
    message: 'SESSION_HUB_SCANNER_HOST_ID or --host-id is required',
  });
  process.exit(1);
}

const endpoint = toWebSocketUrl(args.baseUrl);

let ws = null;
let reconnectAttempts = 0;
let manualClose = false;
let heartbeatTimer = null;
let reconnectTimer = null;
let serialPort = null;
let serialBuffer = '';
let serialInputActive = false;
let serialRetryTimer = null;
let serialPortAttempts = 0;
let rl = null;
let serialConnecting = false;
let currentSerialPortPath = null;
let serialDataHandler = null;
let serialErrorHandler = null;
let serialCloseHandler = null;

let bindingStatus = null;
const pendingScans = [];
const maxPendingScans = 30;
let scanSequence = 0;
const scannerState = {
  status: 'ready',
  owner_mobile_session_id: null,
  target_type: 'mobile',
};
const runtimeState = {
  routing_mode: args.routingMode,
  last_claim_result: null,
  last_scan_result: null,
};
let activeScannerDeviceId = args.scannerDeviceId || null;

function buildRuntimeMetadata() {
  return {
    runtime: 'node',
    pid: process.pid,
    scanner_device_id: activeScannerDeviceId || null,
    bridge_version: args.bridgeVersion,
    base_url: args.baseUrl,
    ws_url: endpoint,
    routing_mode: runtimeState.routing_mode,
    reader_id: activeScannerDeviceId || null,
    config_path: args.configPath || null,
    last_claim_result: runtimeState.last_claim_result,
    last_scan_result: runtimeState.last_scan_result,
  };
}

function buildScannerState() {
  return {
    status: scannerState.status,
    owner_mobile_session_id: scannerState.owner_mobile_session_id,
    target_type: scannerState.target_type,
    routing_mode: runtimeState.routing_mode,
    last_claim_result: runtimeState.last_claim_result,
    last_scan_result: runtimeState.last_scan_result,
  };
}

function setLastClaimResult(status, details) {
  runtimeState.last_claim_result = Object.assign({
    status,
    ts: new Date().toISOString(),
  }, details || {});
}

function setLastScanResult(status, details) {
  runtimeState.last_scan_result = Object.assign({
    status,
    ts: new Date().toISOString(),
  }, details || {});
}

function inferScanType(value) {
  const normalized = normalizeScanValue(value);
  if (!normalized) {
    return 'unknown';
  }
  if (/^shb:\/\//i.test(normalized)) {
    return 'admin';
  }
  if (/^gspair:/i.test(normalized)) {
    return 'claim';
  }
  if (/^gshandoff:/i.test(normalized)) {
    return 'handoff';
  }
  return 'product';
}

function parseAdminCommand(value) {
  const normalized = normalizeScanValue(value);
  if (!/^shb:\/\//i.test(normalized)) {
    return null;
  }

  const command = normalized.replace(/^shb:\/\//i, '').trim().toLowerCase();
  if (!command) {
    return { action: 'invalid', raw: normalized };
  }

  if (command === 'status') {
    return { action: 'status', raw: normalized };
  }

  if (command === 'restart') {
    return { action: 'restart', raw: normalized };
  }

  if (command.startsWith('mode/')) {
    const nextMode = normalizeRoutingMode(command.slice(5), null);
    if (!nextMode) {
      return { action: 'invalid', raw: normalized };
    }
    return {
      action: 'set_mode',
      mode: nextMode,
      raw: normalized,
    };
  }

  return { action: 'invalid', raw: normalized };
}

function persistRuntimeMode(nextMode) {
  if (!args.configPath) {
    return false;
  }

  const nextConfig = Object.assign({}, readJsonObject(args.configPath), {
    routing_mode: nextMode,
    local_keyboard_append_enter: args.localKeyboardAppendEnter,
    updated_at: new Date().toISOString(),
  });

  return writeJsonObject(args.configPath, nextConfig);
}

function applyRuntimeMode(nextMode, source) {
  if (nextMode === 'local_keyboard' && scannerState.owner_mobile_session_id) {
    const payload = {
      status: 'routing.mode.blocked',
      requested_mode: nextMode,
      current_mode: runtimeState.routing_mode,
      owner_mobile_session_id: scannerState.owner_mobile_session_id,
      reason: 'binding activo; no se permite pasar a local_keyboard',
      source: source || 'unknown',
    };
    pretty('bridge.error', payload);
    setLastScanResult('routing_mode_blocked', payload);
    return false;
  }

  const previousMode = runtimeState.routing_mode;
  runtimeState.routing_mode = nextMode;
  const persisted = persistRuntimeMode(nextMode);
  const payload = {
    status: 'routing.mode.changed',
    previous_mode: previousMode,
    routing_mode: nextMode,
    persisted,
    source: source || 'unknown',
  };
  p