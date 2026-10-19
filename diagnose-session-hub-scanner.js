"use strict";
// Read-only evaluator for the facts collected by diagnose-session-hub-scanner.ps1.
// It never touches the PC: it reads a facts JSON (already redacted by the
// collector), optionally the values the installer is about to write (planned),
// and decides PASS / BLOCK. The installer and the updater refuse to continue on
// BLOCK, so a June installation is never overwritten with an incomplete base.
//
//   node diagnose-session-hub-scanner.js --facts <facts.json>
//        [--planned <planned.json>] [--context report|install|ota]
//        [--acknowledge-drop key1,key2]
// exit 0 = PASS (or report), 2 = BLOCK, 1 = usage/parse error.
const fs = require("fs");

const FACTS_SCHEMA = "session-hub-scanner-diagnostic/v1";
// Must match $SecretNamePattern in diagnose-session-hub-scanner.ps1.
const SECRET_NAME_RE = /(secret|token|password|passwd|pwd|api[_-]?key|auth|credential|private)/i;
// Keys the new installer writes (Write-BridgeConfig) plus the optional keys it
// carries over (Merge-PreservedConfig). Anything else in a stored config would
// be dropped by a reinstall.
const NEW_INSTALLER_KEYS = [
  "version",
  "updated_at",
  "host_id",
  "display_name",
  "base_url",
  "serial_port",
  "reader_device_id",
  "readers_json",
  "shared_secret",
  "symbology",
  "serial_fallback",
  "serial_interactive",
  "install_root",
  "input_mode",
  "heartbeat_ms",
  "serial_baud_rate",
  "serial_wait_ms",
  "task_name",
  "tray_task_name",
  "updater_task_name",
  "update_manifest_url",
  "update_channel",
  "update_interval_minutes",
  "install_tray",
  "install_updater",
  "update_window",
  "update_quiet_seconds",
];
// Values a reinstall would overwrite with the planned (explicit or default)
// value. A stored value that differs blocks the install.
const COMPARED_KEYS = [
  "input_mode",
  "host_id",
  "display_name",
  "base_url",
  "serial_port",
  "reader_device_id",
  "symbology",
  "serial_fallback",
  "serial_interactive",
  "heartbeat_ms",
  "serial_baud_rate",
  "serial_wait_ms",
  "task_name",
  "tray_task_name",
  "updater_task_name",
  "update_manifest_url",
  "update_channel",
  "update_interval_minutes",
  "install_tray",
  "install_updater",
];
// Machine/User environment variables the bridge reads, mapped to config keys.
const ENV_TO_KEY = {
  SESSION_HUB_SCANNER_INPUT_MODE: "input_mode",
  SESSION_HUB_BASE_URL: "base_url",
  SESSION_HUB_SCANNER_HOST_ID: "host_id",
  SESSION_HUB_SCANNER_DISPLAY_NAME: "display_name",
  SESSION_HUB_SCANNER_SERIAL_PORT: "serial_port",
  SESSION_HUB_SCANNER_DEVICE_ID: "reader_device_id",
  SESSION_HUB_SCANNER_READER_ID: "reader_device_id",
  SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY: "symbology",
  SESSION_HUB_SCANNER_SERIAL_BAUD_RATE: "serial_baud_rate",
  SESSION_HUB_SCANNER_SERIAL_WAIT_MS: "serial_wait_ms",
  SESSION_HUB_SCANNER_HEARTBEAT_MS: "heartbeat_ms",
  SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN: "serial_fallback",
  SESSION_HUB_SCANNER_SERIAL_INTERACTIVE: "serial_interactive",
};
// Runner/installer arguments that end up in scheduled-task actions.
const TASK_ARG_TO_KEY = {
  hostid: "host_id",
  displayname: "display_name",
  baseurl: "base_url",
  serialport: "serial_port",
  readerdeviceid: "reader_device_id",
  heartbeatms: "heartbeat_ms",
  serialbaudrate: "serial_baud_rate",
  serialwaitms: "serial_wait_ms",
};
// Identification only (sha256 of bridge.js, raw and LF-normalized are both
// checked). Unknown hashes are reported, never guessed.
const KNOWN_BRIDGE_SOURCES = {
  "80eb700fa6d9625c63541b9cf8f0a925f03727e58b054c0e3699865877f7cdb0": "session-hub-scanner-bridge 1.2.0 reviewed OTA Source",
  "26f60f99a642049b117b2c1d305a506c0e2b2e2a3cb763f5373c1e25404c84ff":
    "session-hub-scanner-bridge 92e15d8 (main, 2026-04-03)",
  "56ba73f3fdbedce04c23a26c6f12a250b4a6b2788761719edb99a34df874cc83":
    "session-hub-scanner-bridge cfe1759 (feature/hybrid-routing)",
  "1574e8793152f18c7d8ffeec4ef933640ac892155423305ed276758c24e40485":
    "session-hub-scanner-bridge 27c0600 = b8c875df (dual reader, main)",
  "d4c8b0cc9766ba3a805bd5fc1b132671ee3296e47a4184cb651146d46b787364":
    "gestor_produccion tools/session-hub-scanner-bridge 8d876bc96 (2026-05-19)",
  "4f4338f38894796f84e229afb4ddbc35ef4ba553715295223ecf84c87fd59427":
    "gestor_produccion tools/session-hub-scanner-bridge 0ced20040 (2026-04-01)",
  "5373c6f175998a10902dc56b00ab38d8a21c0cbe1f0233f9bdbdf021847ae254":
    "gestor_produccion tools/session-hub-scanner-bridge 5ae1790a1 (2026-04-01)",
};
const OTA_ACTIVE_PHASES = ["backup", "activate", "starting", "health", "rollback_deferred"];

function normPath(value) {
  return String(value || "")
    .trim()
    .replace(/\//g, "\\")
    .replace(/\\+$/, "")
    .toLowerCase();
}
function normValue(value) {
  if (value === undefined || value === null) return "";
  const text = String(value).trim();
  const lower = text.toLowerCase();
  if (["true", "1", "yes", "on"].includes(lower)) return "true";
  if (["false", "0", "no", "off"].includes(lower)) return "false";
  return text;
}
// The collector rebuilds URLs without credentials/query values (a bare host
// gains a trailing "/"), so URL keys compare without trailing slashes.
function normFor(key, value) {
  const text = normValue(value);
  return /_url$/.test(key) ? text.replace(/\/+$/, "") : text;
}
function readerKey(reader) {
  return [
    String(reader.reader_id || ""),
    String(reader.serial_port || "").toUpperCase(),
    String(reader.scanner_device_id || ""),
    String(reader.serial_baud_rate || ""),
  ].join("|");
}
function sameReaders(a, b) {
  const left = (a || []).map(readerKey).sort();
  const right = (b || []).map(readerKey).sort();
  return JSON.stringify(left) === JSON.stringify(right);
}
function parseTaskArgs(text) {
  const out = {};
  const re = /(?:^|\s)-([A-Za-z]+)\s+(?:"([^"]*)"|'([^']*)'|(\S+))/g;
  let match;
  while ((match = re.exec(String(text || "")))) {
    const value = match[2] !== undefined ? match[2] : match[3] !== undefined ? match[3] : match[4];
    out[match[1].toLowerCase()] = value;
  }
  return out;
}

// Defense in depth: no secret-named entry may carry a value, and no free text
// may carry an unredacted secret flag. A violation blocks and the report must
// not be sent.
function findRedactionViolations(node, trail = "$", out = []) {
  if (Array.isArray(node)) {
    node.forEach((item, index) => findRedactionViolations(item, trail + "[" + index + "]", out));
    return out;
  }
  if (node && typeof node === "object") {
    const name = typeof node.name === "string" ? node.name : null;
    if (name && SECRET_NAME_RE.test(name) && Object.prototype.hasOwnProperty.call(node, "value"))
      out.push(trail + " (" + name + ")");
    for (const [key, value] of Object.entries(node)) {
      if (SECRET_NAME_RE.test(key) && key !== "secret_present" && typeof value === "string" && value && !/^<redacted/.test(value))
        out.push(trail + "." + key);
      findRedactionViolations(value, trail + "." + key, out);
    }
    return out;
  }
  if (typeof node === "string") {
    const flag = /(?:--?|\/)[\w-]*(secret|token|password|passwd|api[_-]?key)[\w-]*(?:\s+|=|:)("[^"]*"|'[^']*'|\S+)/i.exec(node);
    if (flag && !/^["']?<redacted/.test(flag[2])) out.push(trail + " (inline flag)");
    if (/[a-z][a-z0-9+.-]*:\/\/[^\/\s:@]+:[^\/\s@]+@/i.test(node)) out.push(trail + " (url credentials)");
  }
  return out;
}

function configEntries(root) {
  const map = {};
  for (const entry of (root.config && root.config.keys) || []) map[entry.name] = entry;
  return map;
}

function evaluate(facts, options = {}) {
  const context = options.context || "report";
  const acknowledged = new Set(options.acknowledgeDrop || []);
  const blockers = [];
  const warnings = [];
  const block = (code, detail) => blockers.push({ code, detail });
  const warn = (code, detail) => warnings.push({ code, detail });

  if (!facts || facts.schema !== FACTS_SCHEMA) {
    block("FACTS_SCHEMA_INVALID", "expected " + FACTS_SCHEMA);
    return { verdict: "BLOCK", context, blockers, warnings, identified: [] };
  }
  const violations = findRedactionViolations(facts);
  if (violations.length) block("REDACTION_VIOLATION", violations.slice(0, 10).join("; "));

  const target = normPath(facts.target_install_root);
  const roots = facts.roots || [];
  const targetRoot = roots.find((root) => normPath(root.path) === target) || null;
  const identified = [];
  for (const root of roots) {
    const bridge = (root.files || []).find((file) => String(file.name).toLowerCase() === "bridge.js");
    if (bridge) {
      const label =
        KNOWN_BRIDGE_SOURCES[bridge.sha256] || KNOWN_BRIDGE_SOURCES[bridge.sha256_lf] || "unknown bridge.js";
      identified.push({ path: root.path, bridge_sha256: bridge.sha256, source: label });
      if (label === "unknown bridge.js") block("UNKNOWN_BRIDGE_SOURCE", root.path + " requires manual Source review");
    }
    if (root.exists && !bridge && ((root.config && root.config.present) || (root.files || []).length))
      block("UNKNOWN_BRIDGE_SOURCE", root.path + " missing verifiable bridge.js");
    if (root.exists && (bridge || (root.config && root.config.present) || (root.files || []).length) && normPath(root.path) !== target)
      block("OTHER_INSTALLATION_FOUND", root.path + " (sources: " + (root.sources || []).join(",") + ")");
  }
  for (const task of facts.tasks || []) {
    if (!task.root_hint) block("TASK_ROOT_UNKNOWN", task.name);
    if (task.root_hint && normPath(task.root_hint) !== target)
      block("FOREIGN_TASK", task.name + " -> " + task.root_hint);
  }
  for (const proc of facts.processes || []) {
    if (proc.root_hint && normPath(proc.root_hint) !== target)
      block("FOREIGN_BRIDGE_PROCESS", "pid " + proc.pid + " -> " + proc.root_hint);
    else if (!proc.root_hint) block("BRIDGE_PROCESS_ROOT_UNKNOWN", "pid " + proc.pid);
  }

  const stored = targetRoot ? configEntries(targetRoot) : {};
  const config = targetRoot && targetRoot.config;
  if (config && config.present && !config.parse_ok) block("CONFIG_UNREADABLE", targetRoot.path);
  if (targetRoot && targetRoot.ota && OTA_ACTIVE_PHASES.includes(targetRoot.ota.journal_phase)) {
    if (context === "install") block("OTA_IN_PROGRESS", targetRoot.ota.journal_phase);
    else warn("OTA_IN_PROGRESS", targetRoot.ota.journal_phase);
  }

  // Ports configured but not present (informational: a reader may be unplugged).
  const presentPorts = new Set((facts.serial_ports || []).map((port) => String(port.device_id || "").toUpperCase()));
  const storedReaders = (config && config.readers) || [];
  const configuredPorts = storedReaders.map((reader) => reader.serial_port).filter(Boolean);
  if (stored.serial_port && stored.serial_port.value) configuredPorts.push(stored.serial_port.value);
  for (const port of configuredPorts)
    if (presentPorts.size && !presentPorts.has(String(port).toUpperCase())) warn("READER_PORT_NOT_PRESENT", port);

  const secretOutside = [];
  for (const env of facts.env || []) if (env.kind === "secret" && env.present) secretOutside.push("env " + env.scope + ":" + env.name);
  for (const task of facts.tasks || []) if (task.secret_present) secretOutside.push("task " + task.name);
  for (const proc of facts.processes || []) if (proc.secret_present) secretOutside.push("process " + proc.pid);
  for (const launcher of facts.startup_launchers || []) if (launcher.secret_present) secretOutside.push("startup " + launcher.path);
  const storedSecret = Boolean(stored.shared_secret && stored.shared_secret.present);

  if (context !== "ota") {
    // A reinstall only keeps what the new installer writes or carries over.
    for (const name of Object.keys(stored))
      if (!NEW_INSTALLER_KEYS.includes(name) && !acknowledged.has(name))
        block("CONFIG_KEY_NOT_PRESERVED", name);
    if (config && config.readers_present && !config.readers_parse_ok) block("READERS_UNREADABLE", "readers_json");

    const planned = options.planned || null;
    if (planned) {
      if (normPath(planned.install_root) !== target)
        block("PLANNED_ROOT_MISMATCH", planned.install_root + " vs " + facts.target_install_root);
      for (const key of COMPARED_KEYS) {
        const entry = stored[key];
        if (!entry || entry.kind !== "value") continue;
        const before = normFor(key, entry.value);
        if (before === "") continue;
        const after = normFor(key, planned[key]);
        if (before !== after) block("VALUE_WOULD_CHANGE", key + ": '" + before + "' -> '" + after + "'");
      }
      if (storedReaders.length) {
        if (!planned.readers) block("READERS_WOULD_BE_LOST", storedReaders.length + " reader(s)");
        else if (!sameReaders(storedReaders, planned.readers)) block("READERS_WOULD_CHANGE", "readers_json");
      }
      if (storedSecret && !planned.shared_secret_present) block("SECRET_WOULD_BE_LOST", "shared_secret");
      const plannedSecretSource = storedSecret || planned.shared_secret_present;
      if (secretOutside.length && !plannedSecretSource)
        block("SECRET_OUTSIDE_CONFIG", secretOutside.join("; "));
      for (const env of facts.env || []) {
        const key = ENV_TO_KEY[env.name];
        if (!key || env.kind !== "value") continue;
        if (normFor(key, env.value) !== normFor(key, planned[key]))
          block("ENV_SETTING_WOULD_CHANGE", env.scope + ":" + env.name + " '" + env.value + "' vs planned '" + normFor(key, planned[key]) + "'");
      }
      for (const task of facts.tasks || []) {
        const args = parseTaskArgs(task.action_arguments_redacted);
        for (const [arg, key] of Object.entries(TASK_ARG_TO_KEY)) {
          if (args[arg] === undefined || args[arg] === "") continue;
          if (normFor(key, args[arg]) !== normFor(key, planned[key]))
            block("TASK_SETTING_WOULD_CHANGE", task.name + " -" + arg + " '" + args[arg] + "' vs planned '" + normFor(key, planned[key]) + "'");
        }
      }
    } else {
      // Report mode: what would need explicit care in the manual step.
      if (secretOutside.length && !storedSecret) warn("SECRET_OUTSIDE_CONFIG", secretOutside.join("; "));
      for (const env of facts.env || []) if (env.present) warn("ENV_SETTING_PRESENT", env.scope + ":" + env.name);
      if (!targetRoot || !targetRoot.exists) warn("TARGET_NOT_INSTALLED", facts.target_install_root);
    }
  }

  const verdict = context === "report" ? (blockers.length ? "REPORT_WITH_BLOCKERS" : "REPORT_CLEAN") : blockers.length ? "BLOCK" : "PASS";
  return { verdict, context, blockers, warnings, identified };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) throw new Error("ARGUMENT_VALUE_REQUIRED:" + token);
    out[token.slice(2)] = next;
    i += 1;
  }
  return out;
}
function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8").replace(/^﻿/, ""));
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.facts) throw new Error("ARGUMENT_REQUIRED:--facts");
  const context = args.context || "report";
  if (!["report", "install", "ota"].includes(context)) throw new Error("CONTEXT_INVALID");
  const result = evaluate(readJson(args.facts), {
    context,
    planned: args.planned ? readJson(args.planned) : null,
    acknowledgeDrop: args["acknowledge-drop"] ? args["acknowledge-drop"].split(",").map((item) => item.trim()).filter(Boolean) : [],
  });
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
  process.exit(result.verdict === "BLOCK" ? 2 : 0);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write("[diagnose] " + error.message + "\n");
    process.exit(1);
  }
}

module.exports = {
  FACTS_SCHEMA,
  SECRET_NAME_RE,
  NEW_INSTALLER_KEYS,
  COMPARED_KEYS,
  KNOWN_BRIDGE_SOURCES,
  evaluate,
  findRedactionViolations,
  parseTaskArgs,
};
