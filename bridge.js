const WebSocket = require('ws');
const readline = require('readline');
const path = require('path');
const fs = require('fs');

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

  const baseUrl = firstDefined(
    args['base-url'],
    process.env.SESSION_HUB_BASE_URL,
  );

  const hostId = firstDefined(
    args['host-id'],
    process.env.SESSION_HUB_SCANNER_HOST_ID,
  );

  const displayName = firstDefined(
    args['display-name'],
    process.env.SESSION_HUB_SCANNER_DISPLAY_NAME,
    'Session Hub Scanner Bridge',
  );

  const heartbeatMs = toNumber(
    firstDefined(args['heartbeat-ms'], process.env.SESSION_HUB_SCANNER_HEARTBEAT_MS),
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
    'stdin',
  );

  const serialPort = firstDefined(
    args['serial-port'],
    process.env.SESSION_HUB_SCANNER_SERIAL_PORT,
  );

  const serialBaudRate = toNumber(
    firstDefined(
      args['serial-baud-rate'],
      args['serial-baud'],
      process.env.SESSION_HUB_SCANNER_SERIAL_BAUD_RATE,
    ),
    9600,
  );

  const serialWaitMs = toNumber(
    firstDefined(
      args['serial-wait-ms'],
      process.env.SESSION_HUB_SCANNER_SERIAL_WAIT_MS,
    ),
    0,
  );

  const serialFallbackToStdin = toBoolean(
    firstDefined(
      args['serial-fallback'],
      process.env.SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN,
    ),
    false,
  );

  const serialInteractive = toBoolean(
    firstDefined(
      args['serial-interactive'],
      process.env.SESSION_HUB_SCANNER_SERIAL_INTERACTIVE,
    ),
    false,
  );

  const scannerDeviceId = firstDefined(
    args['scanner-device-id'],
    args['reader-id'],
    process.env.SESSION_HUB_SCANNER_DEVICE_ID,
    process.env.SESSION_HUB_SCANNER_READER_ID,
    process.env.SESSION_HUB_SCANNER_READER,
  );

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
let activeScannerDeviceId = args.scannerDeviceId || null;

function inferScanType() {
  return scannerState.owner_mobile_session_id ? 'product' : 'claim';
}

function trackPendingScan(details) {
  const item = {
    id: `${Date.now()}-${++scanSequence}`,
    ts: new Date().toISOString(),
    type: details.type,
    source: details.source,
    value: details.value,
    raw_value: details.rawValue,
    value_length: details.value.length,
    owner_mobile_session_id: scannerState.owner_mobile_session_id,
    target_type: scannerState.target_type,
  };

  pendingScans.push(item);
  if (pendingScans.length > maxPendingScans) {
    pendingScans.shift();
  }

  pretty('bridge.scan', {
    status: 'scan.outbound',
    scan_id: item.id,
    port: details.port || null,
    source: details.source,
    type: details.type,
    value: details.value,
    raw_value: details.rawValue,
    value_length: details.value.length,
    owner_mobile_session_id: item.owner_mobile_session_id,
  });

  return item;
}

function consumePendingScanForAck(payload) {
  if (pendingScans.length === 0) {
    return null;
  }

  const byValue = payload && payload.value ? pendingScans.find((scan) => scan.value === `${payload.value}`) : null;
  if (byValue) {
    const index = pendingScans.indexOf(byValue);
    return pendingScans.splice(index, 1)[0];
  }

  return pendingScans.shift();
}

function readBindingStatus(payload) {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  return payload.binding_status
    || payload.binding
    || payload.bindingStatus
    || (payload.data && (payload.data.binding_status || payload.data.binding))
    || null;
}

function normalizeBinding(binding) {
  if (!binding || typeof binding !== 'object') {
    return null;
  }
  const owner_mobile_session_id = binding.owner_mobile_session_id || binding.bound_mobile || binding.mobile_session_id || null;
  return Object.assign({}, binding, { owner_mobile_session_id });
}

function applyBindingUpdate(nextBinding, sourceEvent) {
  const previous = normalizeBinding(bindingStatus);
  const next = normalizeBinding(nextBinding);
  bindingStatus = next || bindingStatus;

  if (!bindingStatus || typeof bindingStatus !== 'object') {
    return;
  }

  const previousOwner = previous && previous.owner_mobile_session_id;
  const nextOwner = bindingStatus.owner_mobile_session_id;

  if (bindingStatus.scanner_state) {
    scannerState.status = bindingStatus.scanner_state.status || scannerState.status;
    scannerState.target_type = bindingStatus.scanner_state.target_type || scannerState.target_type;
    if (bindingStatus.scanner_state.owner_mobile_session_id !== undefined) {
      scannerState.owner_mobile_session_id = bindingStatus.scanner_state.owner_mobile_session_id;
    }
  }

  if (previousOwner !== nextOwner) {
    pretty('bridge.status', {
      status: nextOwner ? 'binding.bound' : 'binding.released',
      source_event: sourceEvent,
      previous_owner_mobile_session_id: previousOwner || null,
      owner_mobile_session_id: nextOwner || null,
      binding_status: bindingStatus,
    });
    return;
  }

  pretty('bridge.status', {
    status: 'binding.updated',
    source_event: sourceEvent,
    binding_status: bindingStatus,
  });
}

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

function startHeartbeat() {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => {
    sendHeartbeat(false);
  }, args.heartbeatMs);
}

function buildRegisterMessage() {
  const scannerMetadata = {
    runtime: 'node',
    pid: process.pid,
    scanner_device_id: activeScannerDeviceId || null,
  };

  return {
    host_id: args.hostId,
    display_name: args.displayName,
    scanner_device_id: activeScannerDeviceId || null,
    heartbeat_interval_ms: args.heartbeatMs,
  capabilities: {
      bridge: 'session_hub_scanner_bridge',
      input_mode: args.inputMode,
      capture_mode: 'host_owned_scanner',
      claim_via: 'mobile_claim_qr',
      handoff_via: 'scanner_routed_backend_handoff',
    },
    scanner_state: {
      status: scannerState.status,
      owner_mobile_session_id: scannerState.owner_mobile_session_id,
      target_type: scannerState.target_type,
    },
    metadata: {
      ...scannerMetadata,
    },
    ...(args.symbology ? { symbology: args.symbology } : {}),
    ...(args.sharedSecret ? { shared_secret: args.sharedSecret } : {}),
  };
}

function safeSend(type, payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    return false;
  }

  const message = { type, payload };
  ws.send(JSON.stringify(message));
  return true;
}

function sendRegister() {
  const ok = safeSend('scanner.register', buildRegisterMessage());
  if (!ok) {
    pretty('bridge.not_ready', {
      reason: 'scanner.register blocked: socket not open',
    });
  }
}

function sendHeartbeat(manual) {
  const message = {
    host_id: args.hostId,
    heartbeat_interval_ms: args.heartbeatMs,
    scanner_state: {
      status: scannerState.status,
      owner_mobile_session_id: scannerState.owner_mobile_session_id,
      target_type: scannerState.target_type,
    },
    timestamp: new Date().toISOString(),
    reason: manual ? 'manual' : 'periodic',
  };

  const ok = safeSend('scanner.heartbeat', message);
  if (!ok && manual) {
    pretty('bridge.not_ready', {
      reason: 'scanner.heartbeat blocked: socket not open',
    });
  }
}

function sendScan(rawValueInput, source = 'unknown', forcedType = null, port = null) {
  const rawValue = `${rawValueInput}`;
  const value = normalizeScanValue(rawValue);
  const type = forcedType || inferScanType();
  const ok = safeSend('scanner.scan', {
    host_id: args.hostId,
    scanner_device_id: activeScannerDeviceId || null,
    value,
    scanner_state: {
      status: scannerState.status,
      owner_mobile_session_id: scannerState.owner_mobile_session_id,
      target_type: scannerState.target_type,
    },
    ...(args.symbology ? { symbology: args.symbology } : {}),
  });

  if (!ok) {
    pretty('bridge.not_ready', {
      reason: 'scanner.scan blocked: socket not open',
      value,
      source,
    });
    return false;
  }
  trackPendingScan({
    type,
    source,
    value,
    rawValue,
    port,
  });
  return ok;
}

function resolveSerialPortPath(ports, requestedPort) {
  const normalizedRequested = requestedPort ? `${requestedPort}`.trim().toUpperCase() : '';
  if (normalizedRequested) {
    const matched = (ports || []).find((entry) => {
      const portPath = getSerialPortPath(entry);
      return portPath && `${portPath}`.trim().toUpperCase() === normalizedRequested;
    });
    if (matched) {
      return getSerialPortPath(matched);
    }
    pretty('bridge.status', {
      status: 'serial.port.requested_not_found',
      requested: requestedPort,
    });
    return null;
  }

  const candidates = (ports || []).map((entry) => getSerialPortPath(entry)).filter(Boolean);
  if (candidates.length === 0) {
    return null;
  }

  return candidates.find((entry) => /^COM/i.test(entry))
    || candidates[0];
}

function getSerialPortPath(port) {
  if (!port) {
    return null;
  }
  if (typeof port === 'string') {
    return port;
  }
  return port.path || port.comName || port.com_name || port.portName || port.name || port.pathName || null;
}

function getSerialPortConstructor(serialModule) {
  if (typeof serialModule === 'function') {
    return serialModule;
  }
  return serialModule && (serialModule.SerialPort || serialModule.default || null);
}

function createSerialPortInstance(SerialPortCtor, serialPath, serialBaudRate) {
  const options = {
    baudRate: serialBaudRate,
    autoOpen: false,
  };

  try {
    return new SerialPortCtor(serialPath, options);
  } catch (err) {
    return new SerialPortCtor({
      path: serialPath,
      baudRate: serialBaudRate,
      autoOpen: false,
    });
  }
}

function buildSerialPortCandidates(ports) {
  return (ports || []).map((entry) => {
    const path = getSerialPortPath(entry);
    const isBluetooth = typeof entry === 'string'
      ? false
      : /BTHENUM/i.test(`${entry.pnpId || ''}`) || /Bluetooth/i.test(`${entry.manufacturer || ''}`);
    const serialNumber = typeof entry === 'string' ? null : `${entry.serialNumber || ''}`.trim();
    const pnpId = typeof entry === 'string' ? null : `${entry.pnpId || ''}`.trim();
    const usbId = typeof entry === 'string'
      ? null
      : `${entry.vendorId || ''}:${entry.productId || ''}`.replace(/^:|:$/g, '').trim();
    return {
      path,
      is_bluetooth: isBluetooth,
      serial_number: serialNumber || null,
      pnp_id: pnpId || null,
      usb_id: usbId || null,
      device_id: deriveCandidateDeviceId(path, usbId, serialNumber, pnpId),
      description: typeof entry === 'string'
        ? null
        : `${entry.manufacturer || ''} ${entry.friendlyName || ''} ${entry.serialNumber || ''} ${entry.pnpId || ''}`.trim() || null,
    };
  }).filter((item) => item.path);
}

function deriveCandidateDeviceId(path, usbId, serialNumber, pnpId) {
  if (serialNumber) {
    return serialNumber;
  }
  if (pnpId) {
    return pnpId;
  }
  if (usbId) {
    return usbId;
  }
  if (path) {
    return `${path}`.toLowerCase();
  }
  return null;
}

function isSameDeviceId(candidate, requestedDeviceId) {
  if (!requestedDeviceId) {
    return false;
  }
  const normalizedCandidate = `${candidate}`.trim().toLowerCase();
  const normalizedRequested = `${requestedDeviceId}`.trim().toLowerCase();
  if (!normalizedCandidate || !normalizedRequested) {
    return false;
  }
  return normalizedCandidate === normalizedRequested
    || normalizedCandidate.includes(normalizedRequested)
    || normalizedRequested.includes(normalizedCandidate);
}

function formatSerialPortCandidate(item) {
  const desc = item.description ? ` (${item.description})` : '';
  return `${item.path}${desc}`;
}

function parseSerialPortSelection(answer, maxIndex) {
  const n = Number(answer);
  if (!Number.isFinite(n) || !Number.isInteger(n)) {
    return -1;
  }
  if (n < 1 || n > maxIndex) {
    return -1;
  }
  return n - 1;
}

function askSerialPortSelection(candidates) {
  if (!process.stdin.isTTY || !candidates.length) {
    return Promise.resolve(null);
  }

  const normalized = candidates.map((item) => formatSerialPortCandidate(item));
  const prompt = `Seleccionar puerto serial:\n${normalized
    .map((item, idx) => `  ${idx + 1}) ${item}`)
    .join('\n')}\nIngrese un número (1-${candidates.length}): `;

  return new Promise((resolve) => {
    const promptInput = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    promptInput.question(prompt, (rawAnswer) => {
      const idx = parseSerialPortSelection(`${rawAnswer}`.trim(), candidates.length);
      promptInput.close();
      if (idx < 0) {
        resolve(null);
        return;
      }
      resolve(candidates[idx].path);
    });
  });
}

function listSerialPorts(serialModule) {
  return new Promise((resolve) => {
    const serialPortCtor = getSerialPortConstructor(serialModule);
    const listFn = (serialModule && typeof serialModule.list === 'function')
      ? serialModule.list
      : (serialPortCtor && typeof serialPortCtor.list === 'function')
        ? serialPortCtor.list.bind(serialPortCtor)
        : null;

    if (!listFn) {
      resolve([]);
      return;
    }

    try {
      const maybePromise = listFn();
      if (maybePromise && typeof maybePromise.then === 'function') {
        maybePromise.then((ports) => {
          resolve(Array.isArray(ports) ? ports : []);
        }).catch(() => {
          resolve([]);
        });
        return;
      }
      if (Array.isArray(maybePromise)) {
        resolve(maybePromise);
        return;
      }
    } catch (err) {
      // intentional fallback below
    }

    try {
      listFn((err, ports) => {
        resolve(Array.isArray(ports) ? ports : []);
      });
    } catch (err) {
      resolve([]);
    }
  });
}

function openSerialPort(serialPath, baudRate) {
  let SerialPortCtor = null;
  try {
    // eslint-disable-next-line global-require
    const serialModule = resolveExternalModule('serialport') || require('serialport');
    SerialPortCtor = getSerialPortConstructor(serialModule);
  } catch (err) {
    throw new Error('serialport dependency is missing. install it and retry');
  }

  if (!SerialPortCtor) {
    throw new Error('serialport module does not expose SerialPort constructor');
  }

  const port = createSerialPortInstance(SerialPortCtor, serialPath, baudRate);
  if (!port || typeof port.open !== 'function') {
    throw new Error(`serialport invalid instance for ${serialPath}`);
  }

  return new Promise((resolve, reject) => {
    let finished = false;

    const handleDone = (err) => {
      if (finished) {
        return;
      }
      finished = true;
      if (err) {
        reject(err);
        return;
      }
      resolve(port);
    };

    port.once('open', () => {
      handleDone();
    });

    port.once('error', (err) => {
      handleDone(err);
    });

    try {
      const openResult = port.open((err) => {
        if (err) {
          handleDone(err);
        } else {
          handleDone();
        }
      });
      if (openResult && typeof openResult.then === 'function') {
        openResult.then(() => {
          handleDone();
        }).catch((err) => {
          handleDone(err);
        });
      }
    } catch (err) {
      handleDone(err);
    }
  });
}

function selectSerialPortPath(ports) {
  const candidates = buildSerialPortCandidates(ports);
  const nonBluetoothCandidates = candidates.filter((candidate) => !candidate.is_bluetooth);
  const hasRealUsb = nonBluetoothCandidates.length > 0;
  const sourceCandidates = hasRealUsb ? nonBluetoothCandidates : candidates;
  const requested = args.serialPort ? `${args.serialPort}`.trim() : null;
  const requestedDeviceId = args.scannerDeviceId ? `${args.scannerDeviceId}`.trim() : null;

  pretty('bridge.status', {
    status: 'serial.port.discovered',
    requested_port: args.serialPort || null,
    requested_device_id: requestedDeviceId || null,
    ports: sourceCandidates.map((candidate) => ({
      path: candidate.path,
      device_id: candidate.device_id,
      serial_number: candidate.serial_number,
      pnp_id: candidate.pnp_id,
      usb_id: candidate.usb_id,
      description: candidate.description,
      is_bluetooth: candidate.is_bluetooth,
    })),
    filtered_bluetooth: candidates.length > sourceCandidates.length,
  });

  if (requestedDeviceId) {
    const byDeviceId = sourceCandidates.find((candidate) => isSameDeviceId(candidate.device_id, requestedDeviceId));
    if (byDeviceId) {
      pretty('bridge.status', {
        status: 'serial.port.matched_by_device_id',
        device_id: requestedDeviceId,
        port: byDeviceId.path,
      });
      activeScannerDeviceId = byDeviceId.device_id || requestedDeviceId;
      return Promise.resolve(byDeviceId.path);
    }

    pretty('bridge.error', {
      status: 'serial.device_id.request_not_found',
      requested_device_id: requestedDeviceId,
      available: sourceCandidates.map((item) => item.device_id),
    });
  }

  let selected = resolveSerialPortPath(hasRealUsb ? nonBluetoothCandidates.map((candidate) => candidate.path) : candidates.map((candidate) => candidate.path), requested);
  if (!selected && requested) {
    selected = requested;
    activeScannerDeviceId = requested;
    pretty('bridge.status', {
      status: 'serial.port.requested_fallback',
      requested,
    });
  }
  if (!selected && args.serialInteractive && process.stdin.isTTY) {
    if (!hasRealUsb) {
      pretty('bridge.error', {
        status: 'serial.no_usb_ports',
        message: 'No se detectaron puertos serial USB. Revisá modo USB-Serial del lector / cable.',
      });
    }

    return askSerialPortSelection(sourceCandidates).then((selection) => {
      if (selection) {
        return selection;
      }
      return null;
    });
  }

  if (!selected && sourceCandidates.length === 1) {
    activeScannerDeviceId = sourceCandidates[0].device_id || activeScannerDeviceId;
    return Promise.resolve(sourceCandidates[0].path);
  }

  if (!selected && sourceCandidates.length > 0 && !args.scannerDeviceId) {
    activeScannerDeviceId = sourceCandidates[0].device_id || activeScannerDeviceId;
  }

  return Promise.resolve(selected);
}

function attachSerialCapture(port, serialPath) {
  serialDataHandler = (chunk) => {
    const rawChunk = `${chunk}`.toString('utf8');
    if (!rawChunk) {
      return;
    }

    serialBuffer += rawChunk;
    const lines = serialBuffer.split(/\r\n|\n|\r/);
    serialBuffer = lines.pop();

  for (let i = 0; i < lines.length; i += 1) {
    const rawLine = `${lines[i]}`;
    const value = normalizeScanValue(rawLine);
    if (!value) {
        continue;
      }

      pretty('bridge.serial', {
        status: 'serial.parse',
        scanner_device_id: activeScannerDeviceId || null,
        port: serialPath,
        line: value,
        raw_line: rawLine,
        raw_length: rawLine.length,
        normalized_length: value.length,
      });
      pretty('bridge.status', {
        status: 'serial.scan',
        scanner_device_id: activeScannerDeviceId || null,
        source: 'serial',
        port: serialPath,
        value,
        normalized_length: value.length,
        inferred_type: inferScanType(),
      });
      sendScan(value, 'serial', inferScanType(), serialPath);
    }
  };

  serialErrorHandler = (err) => {
    pretty('bridge.error', {
      status: 'serial.error',
      port: serialPath,
      message: err && err.message ? err.message : String(err),
    });
  };

  serialCloseHandler = () => {
    pretty('bridge.status', {
      status: 'serial.port.closed',
      port: serialPath,
    });
    if (!manualClose && args.inputMode === 'serial' && !args.serialFallbackToStdin) {
      serialPort = null;
      serialInputActive = false;
      scheduleSerialRetry('serial port closed');
    }
  };

  port.on('data', serialDataHandler);
  port.on('error', serialErrorHandler);
  port.on('close', serialCloseHandler);
}

function stopSerialCapture() {
  if (!serialPort) {
    return;
  }

  if (serialDataHandler) {
    serialPort.removeListener('data', serialDataHandler);
    serialDataHandler = null;
  }
  if (serialErrorHandler) {
    serialPort.removeListener('error', serialErrorHandler);
    serialErrorHandler = null;
  }
  if (serialCloseHandler) {
    serialPort.removeListener('close', serialCloseHandler);
    serialCloseHandler = null;
  }

  if (typeof serialPort.close === 'function') {
    try {
      serialPort.close(() => {});
    } catch (err) {
      // ignore cleanup errors
    }
  }

  serialPort = null;
  serialInputActive = false;
  clearSerialRetryTimer();
}

function clearSerialRetryTimer() {
  if (serialRetryTimer) {
    clearTimeout(serialRetryTimer);
    serialRetryTimer = null;
  }
}

function handleSerialFailure(err) {
  serialConnecting = false;
  serialInputActive = false;
  serialPort = null;
  pretty('bridge.error', {
    status: 'serial.port.failed',
    message: err && err.message ? err.message : String(err),
  });
  if (args.serialFallbackToStdin) {
    pretty('bridge.status', {
      status: 'serial.fallback',
      fallback_to: 'stdin',
    });
    startStdinCapture('serial fallback');
    return;
  }

  scheduleSerialRetry(err && err.message ? err.message : 'serial port unavailable');
}

function scheduleSerialRetry(reason) {
  if (manualClose || args.inputMode !== 'serial') {
    return;
  }

  const delay = Math.min(30000, Math.max(1000, args.serialWaitMs || 1000) * Math.min(10, (serialPortAttempts || 1)));
  serialPortAttempts += 1;

  pretty('bridge.status', {
    status: 'serial.port.wait',
    reason,
    attempt: serialPortAttempts,
    delay_ms: delay,
  });

  clearSerialRetryTimer();
  serialRetryTimer = setTimeout(() => {
    startSerialCapture().catch((err) => {
      handleSerialFailure(err);
    });
  }, delay);
}

function startStdinCapture(reason) {
  if (rl) {
    return;
  }

  rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false,
  });

  rl.on('line', handleInput);

  pretty('bridge.status', {
    status: 'input.stdin.started',
    mode: 'stdin',
    reason: reason || 'default',
  });
}

function startSerialCapture() {
  if (serialInputActive) {
    return Promise.resolve();
  }
  if (serialConnecting) {
    return Promise.resolve();
  }
  serialConnecting = true;
  clearSerialRetryTimer();
  serialPortAttempts = 0;

  let serialModule = null;
  try {
    // eslint-disable-next-line global-require
    serialModule = resolveExternalModule('serialport') || require('serialport');
  } catch (err) {
    throw new Error('serialport dependency is missing. install it and retry');
  }

  return listSerialPorts(serialModule).then((ports) => {
    return selectSerialPortPath(ports).then((serialPath) => {
      if (!serialPath) {
        throw new Error('no COM ports available for serial mode');
      }

      return openSerialPort(serialPath, args.serialBaudRate).then((port) => {
        serialPortAttempts = 0;
        serialInputActive = true;
        serialConnecting = false;
        serialPort = port;
        currentSerialPortPath = serialPath;
        attachSerialCapture(port, serialPath);
        pretty('bridge.status', {
        status: 'serial.port.open',
          port: serialPath,
          input_mode: args.inputMode,
          baud_rate: args.serialBaudRate,
          scanner_device_id: activeScannerDeviceId || null,
        });
      });
    });
  }).catch((err) => {
    serialConnecting = false;
    return Promise.reject(err);
  });
}

function stopStdinCapture() {
  if (!rl) {
    return;
  }

  rl.close();
  rl = null;
}

function stopInputs() {
  clearSerialRetryTimer();
  stopSerialCapture();
  stopStdinCapture();
}

function startInputCapture() {
  if (args.inputMode === 'serial') {
    startSerialCapture()
      .then(() => {
        pretty('bridge.status', {
          status: 'serial.input.active',
          port: currentSerialPortPath || 'unknown',
        });
      })
      .catch((err) => {
        handleSerialFailure(err);
      });
    return;
  }

  startStdinCapture('configured stdin mode');
}

function connect() {
  if (manualClose) {
    return;
  }

  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) {
    return;
  }

  ws = new WebSocket(endpoint);

  ws.on('open', () => {
    reconnectAttempts = 0;
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    pretty('bridge.connected', {
      endpoint,
      host_id: args.hostId,
      heartbeat_interval_ms: args.heartbeatMs,
    });

    sendRegister();
    startHeartbeat();
  });

  ws.on('message', (raw) => {
    let parsed = null;
    try {
      parsed = JSON.parse(raw.toString());
    } catch (err) {
      pretty('bridge.message', {
        raw: raw.toString(),
      });
      return;
    }

    const event = extractEventName(parsed);
    const payload = parsed && typeof parsed === 'object' && parsed.payload && typeof parsed.payload === 'object'
      ? parsed.payload
      : parsed;

    pretty('bridge.message', {
      event,
      payload,
    });

    if (event === 'scanner.registered') {
      applyBindingUpdate(readBindingStatus(payload), event);
      pretty('bridge.status', {
        status: 'scanner.registered',
        binding_status: bindingStatus || null,
      });
      return;
    }

    if (event === 'binding.updated') {
      applyBindingUpdate(readBindingStatus(payload), event);
      return;
    }

    if (event === 'scanner.ack') {
      const ackScan = consumePendingScanForAck(payload);
      const ackKind = payload && (payload.kind || payload.scan_kind || payload.scan_type) || null;
      const ackOk = payload && payload.ok !== undefined ? payload.ok : null;
      pretty('bridge.status', {
        status: 'scanner.ack',
        ack_id: payload.scan_id || (payload.data && payload.data.scan_id) || null,
        kind: ackKind,
        ok: ackOk,
        message: payload.message || null,
        associated_scan: ackScan ? {
          scan_id: ackScan.id,
          type: ackScan.type,
          source: ackScan.source,
          value: ackScan.value,
          value_length: ackScan.value_length,
          owner_mobile_session_id: ackScan.owner_mobile_session_id,
        } : null,
      });

      if (ackKind && `${ackKind}`.toLowerCase() !== 'heartbeat' && ackOk === false) {
        pretty('bridge.error', {
          status: 'scanner.ack.failed',
          kind: ackKind,
          reason: payload.error || payload.message || null,
          payload,
        });
      }

      if (ackKind && `${ackKind}`.toLowerCase() !== 'heartbeat' && ackScan && ackScan.type === 'claim' && !bindingStatus) {
        pretty('bridge.error', {
          status: 'claim.scan.not_bound',
          reason: 'claim scan enviado pero no hay binding todavía',
          payload,
        });
      }

      return;
    }

    if (event === 'session_hub.error') {
      pretty('bridge.error', {
        status: 'session_hub.error',
        error: payload.message || payload.error || payload,
        code: payload.code || null,
      });
      return;
    }

    if (event === 'scan.not_found' || event === 'scan.invalid') {
      pretty('bridge.error', {
        status: event,
        payload,
      });
    }
  });

  ws.on('close', (code, reason) => {
    ws = null;
    stopHeartbeat();

    pretty('bridge.disconnected', {
      code,
      reason: reason && reason.toString(),
    });

    if (!manualClose) {
      scheduleReconnect();
    }
  });

  ws.on('error', (err) => {
    pretty('bridge.error', {
      status: 'ws.error',
      message: err && err.message ? err.message : String(err),
    });
  });
}

function scheduleReconnect() {
  if (manualClose) {
    return;
  }

  const baseDelay = 1000;
  const maxDelay = 30000;
  const delay = Math.min(maxDelay, baseDelay * (2 ** reconnectAttempts));
  reconnectAttempts += 1;

  pretty('bridge.status', {
    status: 'reconnecting',
    attempt: reconnectAttempts,
    delay_ms: delay,
  });

  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
  }

  reconnectTimer = setTimeout(() => {
    connect();
  }, delay);
}

function handleInput(lineRaw) {
  const line = `${lineRaw}`.replace(/\r?\n$/, '');

  if (line.length === 0) {
    return;
  }

  if (line === ':heartbeat') {
    sendHeartbeat(true);
    return;
  }

  if (line === ':status') {
    pretty('bridge.status', {
      status: 'current',
      binding_status: bindingStatus,
      scanner_state: scannerState,
      connected: ws ? ws.readyState === WebSocket.OPEN : false,
    });
    return;
  }

  if (line === ':quit') {
    manualClose = true;
    pretty('bridge.disconnected', {
      reason: 'manual quit command',
    });
    stopInputs();
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (ws) {
      ws.close();
    }
    process.exit(0);
  }

  if (line.startsWith(':scan ')) {
    const value = line.slice(6);
    sendScan(value);
    return;
  }

  if (line.startsWith(':')) {
    pretty('bridge.error', {
      message: 'unknown command',
      line,
    });
    return;
  }

  sendScan(line, 'stdin');
}

if (args.requestedInputMode !== args.inputMode) {
  pretty('bridge.status', {
    status: 'input.mode.invalid',
    requested: args.requestedInputMode,
    using: args.inputMode,
  });
}

process.on('unhandledRejection', (reason) => {
  pretty('bridge.error', {
    status: 'unhandled_rejection',
    error: reason && reason.message ? reason.message : `${reason}`,
  });
});

process.on('uncaughtException', (err) => {
  pretty('bridge.error', {
    status: 'uncaught_exception',
    error: err && err.message ? err.message : `${err}`,
  });
});

process.on('SIGINT', () => {
  manualClose = true;
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
  }
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
  }
  stopInputs();
  if (ws) {
    ws.close();
  }
  process.exit(0);
});

pretty('bridge.status', {
  status: 'starting',
  input_mode: args.inputMode,
  serial_port: args.serialPort || null,
  endpoint,
  script: __filename,
  cwd: process.cwd(),
  host_id: args.hostId,
  display_name: args.displayName,
  heartbeat_interval_ms: args.heartbeatMs,
  symbology: args.symbology || null,
});

startInputCapture();
connect();
