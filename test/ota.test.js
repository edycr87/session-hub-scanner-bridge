const test = require("node:test");
const assert = require("node:assert/strict");
const { fork } = require("node:child_process");
const crypto = require("node:crypto");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const { WebSocketServer } = require("ws");
const lib = require("../tools/release-statement");

const root = path.resolve(__dirname, "..");
const bridge = path.join(root, "bridge.js");
const fake = path.join(__dirname, "fixtures", "fake-serialport.js");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function eventually(predicate, message, tries = 160) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return;
    await sleep(25);
  }
  assert.fail(message);
}
function readState(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return null;
  }
}

async function startBridge(options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-ota-"));
  const stateFile = path.join(dir, "bridge-state.json");
  const drainFile = path.join(dir, "update-drain.request");
  if (options.preDrain) fs.writeFileSync(drainFile, JSON.stringify(options.preDrain));
  const messages = [];
  const sockets = [];
  const server = new WebSocketServer({ port: 0 });
  await new Promise((resolve) => server.once("listening", resolve));
  server.on("connection", (socket) => {
    sockets.push(socket);
    socket.on("message", (raw) => {
      const message = JSON.parse(raw);
      messages.push({ socket, message });
      if (message.type === "scanner.register" && !options.deferRegister)
        socket.send(JSON.stringify({ type: "scanner.registered", payload: {} }));
    });
  });
  const readers = [
    { reader_id: "left", serial_port: "COM6", scanner_device_id: "LEFT" },
    { reader_id: "right", serial_port: "COM7", scanner_device_id: "RIGHT" },
  ];
  const child = fork(
    bridge,
    [
      "--base-url",
      "http://127.0.0.1:" + server.address().port,
      "--host-id",
      "ota-host",
      "--input-mode",
      options.stdin ? "stdin" : "serial",
      "--readers",
      JSON.stringify(readers),
      "--ack-timeout-ms",
      "10000",
      "--state-file",
      stateFile,
      "--drain-file",
      drainFile,
      "--drain-quiet-ms",
      String(options.quietMs || 200),
    ],
    {
      cwd: root,
      silent: true,
      env: {
        ...process.env,
        SESSION_HUB_SERIALPORT_MODULE: fake,
        FAKE_SERIAL_PORTS: JSON.stringify([
          { path: "COM6", serialNumber: "LEFT" },
          { path: "COM7", serialNumber: "RIGHT" },
        ]),
      },
    },
  );
  let exitCode = null;
  child.on("exit", (code) => {
    exitCode = code === null ? -1 : code;
  });
  child.stdout.resume();
  child.stderr.resume();
  await eventually(() => {
    const state = readState(stateFile);
    return (
      state &&
      state.ws_ready === !options.deferRegister &&
      (options.stdin || state.readers.every((reader) => reader.state === "open")) &&
      messages.some((entry) => entry.message.type === "scanner.register")
    );
  }, "bridge did not publish a ready state");
  return {
    child,
    dir,
    stateFile,
    drainFile,
    messages,
    exited: () => exitCode,
    emit(port, data) {
      child.send({ op: "data", port, data });
    },
    requestDrain(nonce) {
      fs.writeFileSync(
        drainFile,
        JSON.stringify({ nonce, requested_at: new Date().toISOString() }),
      );
    },
    scans() {
      return messages.filter((entry) => entry.message.type === "scanner.scan");
    },
    registerNow() {
      sockets.forEach((socket) =>
        socket.send(JSON.stringify({ type: "scanner.registered", payload: {} })),
      );
    },
    ackAll() {
      for (const entry of messages.filter((item) => item.message.type === "scanner.scan"))
        entry.socket.send(
          JSON.stringify({
            type: "scanner.ack",
            payload: { scan_id: entry.message.payload.scan_id, ok: true },
          }),
        );
    },
    async close() {
      if (exitCode === null) child.kill("SIGINT");
      await sleep(30);
      await new Promise((resolve) => server.close(resolve));
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

test("state file reports version, pid, registration and both readers", async () => {
  const run = await startBridge();
  try {
    const state = readState(run.stateFile);
    assert.equal(state.schema, "session-hub-scanner-bridge-state/v1");
    assert.equal(state.pid, run.child.pid);
    assert.equal(state.version, require("../package.json").version);
    assert.equal(state.pending_total, 0);
    assert.equal(state.in_flight, false);
    assert.deepEqual(
      state.readers.map((reader) => reader.reader_id).sort(),
      ["left", "right"],
    );
  } finally {
    await run.close();
  }
});

test("drain waits for the pending ACK, then exits by itself", async () => {
  const run = await startBridge();
  try {
    run.emit("COM6", "7791234567890\r\n");
    await eventually(() => run.scans().length === 1, "scan was not sent");
    await eventually(
      () => (readState(run.stateFile) || {}).in_flight === true,
      "state did not show the in-flight scan",
    );
    run.requestDrain("n-ack");
    await sleep(1600);
    assert.equal(run.exited(), null, "bridge exited while an ACK was pending");
    const pending = run.scans()[0];
    pending.socket.send(
      JSON.stringify({
        type: "scanner.ack",
        payload: { scan_id: pending.message.payload.scan_id, ok: true },
      }),
    );
    await eventually(() => run.exited() === 0, "bridge did not drain after ACK", 240);
    const state = readState(run.stateFile);
    assert.equal(state.drained, true);
    assert.equal(state.drain_nonce, "n-ack");
    assert.equal(state.pending_total, 0);
  } finally {
    await run.close();
  }
});

test("a scan arriving during the drain is kept and delays the exit", async () => {
  const run = await startBridge({ quietMs: 1500 });
  try {
    run.requestDrain("n-late");
    await sleep(300);
    run.emit("COM7", "LATE-SCAN\r\n");
    await eventually(() => run.scans().length === 1, "late scan was not sent");
    await sleep(1300);
    assert.equal(run.exited(), null, "bridge exited with a captured scan unacknowledged");
    const pending = run.scans()[0];
    assert.equal(pending.message.payload.reader_id, "right");
    pending.socket.send(
      JSON.stringify({
        type: "scanner.ack",
        payload: { scan_id: pending.message.payload.scan_id, ok: true },
      }),
    );
    await eventually(() => run.exited() === 0, "bridge did not drain after quiet window", 240);
  } finally {
    await run.close();
  }
});

test("removing the drain request cancels it and the bridge keeps capturing", async () => {
  const run = await startBridge();
  try {
    run.emit("COM6", "HOLD\r\n");
    await eventually(() => run.scans().length === 1, "scan was not sent");
    run.requestDrain("n-cancel");
    await eventually(
      () => ((readState(run.stateFile) || {}).drain || {}).requested === true,
      "drain request not observed",
    );
    fs.rmSync(run.drainFile);
    await eventually(
      () => ((readState(run.stateFile) || {}).drain || {}).requested === false,
      "drain cancel not observed",
    );
    const pending = run.scans()[0];
    pending.socket.send(
      JSON.stringify({
        type: "scanner.ack",
        payload: { scan_id: pending.message.payload.scan_id, ok: true },
      }),
    );
    await sleep(1500);
    assert.equal(run.exited(), null, "bridge exited after the drain was cancelled");
    run.emit("COM7", "AFTER-CANCEL\r\n");
    await eventually(() => run.scans().length === 2, "bridge stopped capturing");
  } finally {
    await run.close();
  }
});

test("a drain request older than the process is ignored", async () => {
  const run = await startBridge({
    preDrain: { nonce: "stale", requested_at: "2000-01-01T00:00:00.000Z" },
  });
  try {
    await sleep(2200);
    assert.equal(run.exited(), null, "stale drain request stopped a fresh bridge");
    assert.equal((readState(run.stateFile).drain || {}).requested, false);
  } finally {
    await run.close();
  }
});

function makeZip(dir, bytes) {
  const file = path.join(dir, "session-hub-scanner-bridge.zip");
  fs.writeFileSync(file, bytes);
  return file;
}

test("signed manifest entry verifies and every signed field is tamper-evident", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-sign-"));
  try {
    const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
      modulusLength: 3072,
      publicKeyEncoding: { type: "spki", format: "pem" },
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });
    const zip = makeZip(dir, crypto.randomBytes(4096));
    const { entry } = lib.buildSignedEntry({
      zipPath: zip,
      channel: "stable",
      version: "1.1.0",
      minInstalledVersion: "1.1.0",
      privateKeyPem: privateKey,
      keyId: "test-key",
      packageUrl: "https://example.invalid/pkg.zip",
    });
    assert.equal(entry.size_bytes, 4096);
    assert.match(entry.sha256, /^[0-9a-f]{64}$/);
    const statement = lib.buildStatement({ ...entry, channel: "stable" });
    assert.ok(lib.verifyStatement(statement, entry.signature.value, publicKey));
    for (const [field, value] of [
      ["version", "1.1.1"],
      ["sha256", "0".repeat(64)],
      ["size_bytes", 4097],
      ["min_installed_version", "1.0.0"],
      ["channel", "beta"],
    ]) {
      const tampered = lib.buildStatement({ ...entry, channel: "stable", [field]: value });
      assert.equal(
        lib.verifyStatement(tampered, entry.signature.value, publicKey),
        false,
        "tampered " + field + " still verified",
      );
    }
    const other = crypto.generateKeyPairSync("rsa", {
      modulusLength: 3072,
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    assert.equal(lib.verifyStatement(statement, entry.signature.value, other.publicKey), false);
    const pin = lib.publicKeyToPin(publicKey, "test-key");
    assert.equal(Buffer.from(pin.modulus_b64, "base64").length, 384);
    assert.equal(pin.exponent_b64, "AQAB");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("statement rules: strict versions, no min above version, weak keys refused", () => {
  const base = {
    channel: "stable",
    version: "1.2.0",
    sha256: "a".repeat(64),
    size_bytes: 10,
    min_installed_version: "1.1.0",
  };
  assert.doesNotThrow(() => lib.buildStatement(base));
  assert.throws(() => lib.buildStatement({ ...base, version: "1.2.0-beta.1" }), /VERSION_INVALID/);
  assert.throws(() => lib.buildStatement({ ...base, min_installed_version: "1.3.0" }), /ABOVE_VERSION/);
  assert.throws(() => lib.buildStatement({ ...base, sha256: "" }), /SHA256_INVALID/);
  assert.throws(() => lib.buildStatement({ ...base, size_bytes: 0 }), /SIZE_INVALID/);
  const weak = crypto.generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
  });
  assert.throws(() => lib.publicKeyToPin(weak.publicKey, "weak"), /KEY_TOO_SMALL/);
});

test("PowerShell updater statement and policy stay in sync with the signer", () => {
  const ps = fs.readFileSync(path.join(root, "update-session-hub-scanner.ps1"), "utf8");
  assert.ok(ps.includes("$ReleaseStatementHeader = '" + lib.HEADER + "'"));
  assert.ok(ps.includes("$ReleaseSignatureAlg = '" + lib.SIGNATURE_ALG + "'"));
  const block = ps.slice(ps.indexOf("function Get-ReleaseStatement"));
  const fields = Array.from(
    block.slice(0, block.indexOf("return")).matchAll(/\('([a-z_0-9]+)=' \+/g),
  ).map((match) => match[1]);
  assert.deepEqual(fields, lib.FIELD_ORDER);
  // Only the reviewed public DEV laboratory key is pinned.
  const pins = ps.slice(ps.indexOf("$PinnedReleaseKeys = @("), ps.indexOf("$MaxPackageBytes"));
  const modulus = pins.match(/modulus_b64 = '([^']+)'/)[1];
  const exponent = pins.match(/exponent_b64 = '([^']+)'/)[1];
  const key = crypto.createPublicKey({ key: { kty: "RSA", n: Buffer.from(modulus, "base64").toString("base64url"), e: Buffer.from(exponent, "base64").toString("base64url") }, format: "jwk" });
  assert.equal(crypto.createHash("sha256").update(key.export({ format: "der", type: "spki" })).digest("hex"), "b07345401335305798956089b97fe1249b501e4917cfa51dce7cf863498c7ce6");
  assert.ok(pins.includes("dev-lab-20261019"));
  assert.equal(ps.includes("PRIVATE KEY-----"), false);
  assert.ok(ps.includes("UPDATE_SIGNING_KEY_NOT_PINNED"));
  assert.ok(ps.includes("'check' {\n    Invoke-WithUpdateLock { Invoke-UpdateCheck -Apply $false }"));
  assert.equal(/Copy-Item[^\n]*-Destination \$resolvedInstallRoot/.test(ps), false, "in-place copy remains");
  assert.equal(/Set-Content[^\n]*resolvedConfigPath/.test(ps), false, "updater writes the config");
  const build = fs.readFileSync(path.join(root, "build-session-hub-scanner-package.ps1"), "utf8");
  const buildProtected = Array.from(
    build.match(/\$protectedNames = @\(([^)]*)\)/)[1].matchAll(/'([^']+)'/g),
  ).map((match) => match[1]);
  const updaterProtected = Array.from(
    ps.match(/\$ProtectedNames = @\(([^)]*)\)/)[1].matchAll(/'([^']+)'/g),
  ).map((match) => match[1]);
  assert.deepEqual([...buildProtected].sort(), [...updaterProtected].sort());
});

test("installer preserves stored readers, secret and manifest URL on reinstall", () => {
  const installer = fs.readFileSync(path.join(root, "install-session-hub-scanner.ps1"), "utf8");
  const mergeAt = installer.indexOf("Merge-PreservedConfig -Cfg $config");
  const writeAt = installer.indexOf("Write-BridgeConfig -Cfg $config");
  assert.ok(mergeAt > 0 && writeAt > mergeAt, "merge must run before the config is written");
  for (const key of ["readers_json", "shared_secret", "symbology", "reader_device_id", "update_manifest_url"])
    assert.ok(installer.includes("'" + key + "'"), key + " is not preserved");
  const runner = fs.readFileSync(path.join(root, "run-session-hub-bridge.ps1"), "utf8");
  assert.ok(runner.includes("SESSION_HUB_SCANNER_STATE_FILE"));
  assert.ok(runner.includes("SESSION_HUB_SCANNER_DRAIN_FILE"));
  assert.ok(runner.includes("Test-OtaActivationInProgress"));
});

// Emulates the updater's deferral loop (Wait-BridgeDrainWithBackoff): request a
// drain window, give up, remove the request, back off, try again.
async function drainWindow(run, nonce, ms) {
  run.requestDrain(nonce);
  await sleep(ms);
  const exitedDuring = run.exited();
  if (exitedDuring === null) fs.rmSync(run.drainFile, { force: true });
  return exitedDuring;
}

test("install deferral: pending ACK survives repeated drain windows; nothing is lost", async () => {
  const run = await startBridge();
  try {
    run.emit("COM6", "INSTALL-PENDING\r\n");
    await eventually(() => run.scans().length === 1, "scan was not sent");
    const firstId = run.scans()[0].message.payload.scan_id;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      assert.equal(await drainWindow(run, "install-" + attempt, 1200), null, "bridge exited with a pending ACK (attempt " + attempt + ")");
      await sleep(200);
    }
    run.emit("COM7", "DURING-DEFERRAL\r\n");
    await eventually(
      () => ((readState(run.stateFile) || {}).drain || {}).requested === false,
      "drain request left behind between windows",
    );
    await eventually(
      () => (readState(run.stateFile) || {}).pending_total === 2,
      "scan captured during the deferral was not queued",
    );
    // The backend finally answers: every captured scan is ACKed by its own ID.
    run.ackAll();
    await eventually(() => run.scans().length === 2, "queued scan not sent");
    run.ackAll();
    await eventually(() => (readState(run.stateFile) || {}).pending_total === 0, "queue did not empty");
    const ids = new Set(run.scans().map((entry) => entry.message.payload.scan_id));
    assert.ok(ids.has(firstId), "original scan_id was replaced");
    assert.equal(await drainWindow(run, "install-final", 2500), 0, "idle bridge did not drain");
  } finally {
    await run.close();
  }
});

test("rollback deferral: degraded new version (not registered) keeps capturing both readers and never exits", async () => {
  const run = await startBridge({ deferRegister: true });
  try {
    run.emit("COM6", "DEGRADED-LEFT\r\n");
    run.emit("COM7", "DEGRADED-RIGHT\r\n");
    await eventually(() => (readState(run.stateFile) || {}).pending_total === 2, "degraded bridge did not keep both scans");
    for (let attempt = 1; attempt <= 2; attempt += 1)
      assert.equal(await drainWindow(run, "rollback-" + attempt, 1200), null, "degraded bridge exited holding scans");
    assert.equal(run.scans().length, 0, "nothing can be sent before registration");
    // Backend comes back: queued scans flow one by one, then the rollback can drain.
    run.registerNow();
    await eventually(() => run.scans().length === 1, "queued scan not sent after registration");
    run.ackAll();
    await eventually(() => run.scans().length === 2, "second queued scan not sent");
    run.ackAll();
    await eventually(() => (readState(run.stateFile) || {}).pending_total === 0, "queue did not empty");
    assert.deepEqual(
      run.scans().map((entry) => entry.message.payload.reader_id).sort(),
      ["left", "right"],
    );
    assert.equal(await drainWindow(run, "rollback-final", 2500), 0, "bridge did not drain once idle");
  } finally {
    await run.close();
  }
});

test("recovery after a power cut: stale request ignored, fresh pending scan defers the rollback drain", async () => {
  const run = await startBridge({
    preDrain: { nonce: "before-power-cut", requested_at: "2000-01-01T00:00:00.000Z" },
  });
  try {
    run.emit("COM7", "AFTER-REBOOT\r\n");
    await eventually(() => run.scans().length === 1, "scan after reboot not sent");
    assert.equal(await drainWindow(run, "recover-1", 1500), null, "recovery drain cut a pending ACK");
    run.ackAll();
    await eventually(() => (readState(run.stateFile) || {}).pending_total === 0, "queue did not empty");
    assert.equal(await drainWindow(run, "recover-2", 2500), 0, "recovery drain did not complete once idle");
  } finally {
    await run.close();
  }
});

test("updater policy: deferral never stops the bridge; rollback waits for the queue", () => {
  const ps = fs.readFileSync(path.join(root, "update-session-hub-scanner.ps1"), "utf8");
  assert.equal(/RunnerMode 'stop-task'/.test(ps), false, "updater can stop the bridge");
  assert.equal(/Stop-Process/.test(ps), false, "updater can kill a process");
  assert.equal(/ROLLBACK_FORCED/.test(ps), false, "forced rollback path remains");
  const body = (name) => {
    const start = ps.indexOf("function " + name + " {");
    assert.ok(start >= 0, name + " missing");
    return ps.slice(start, ps.indexOf("\nfunction ", start + 10));
  };
  const rollback = body("Invoke-Rollback");
  const drainAt = rollback.indexOf("Wait-BridgeDrainWithBackoff");
  const deferAt = rollback.indexOf("'rollback_deferred'");
  const restoreAt = rollback.indexOf("Restore-FromJournal");
  assert.ok(drainAt > 0 && deferAt > drainAt && restoreAt > deferAt, "rollback restores before waiting for the queue");
  assert.ok(rollback.includes("Set-BridgeTaskEnabled -Enabled $true\n    Register-Deferral"), "deferred rollback must leave the running version restartable");
  const deferral = body("Register-Deferral");
  assert.equal(/Restore-FromJournal|stop-task|Start-BridgeIfStopped/.test(deferral), false, "the deferral cap forces something");
  assert.ok(deferral.includes("UPDATE_DEFER_LIMIT_ALERT"));
  const resume = body("Resume-PendingUpdate");
  assert.ok(resume.includes("'rollback_deferred'"), "deferred rollback is not retried on resume");
  assert.ok(body("Invoke-WithUpdateLock").includes("if (Resume-PendingUpdate)"), "a new install can start over a pending rollback");
  assert.ok(body("Restore-FromJournal").includes("restore_mode"), "restore mode not pinned for deferred rollbacks");
  const apply = body("Apply-UpdateFromManifest");
  assert.ok(apply.includes("Write-InstallDeferral"), "install deferral not recorded");
  assert.equal(/RunnerMode 'start-task'/.test(apply), false, "apply may start (and kill) over a running bridge");
  const tray = fs.readFileSync(path.join(root, "tray-session-hub-bridge.ps1"), "utf8");
  assert.ok(tray.includes("update-status.json") && tray.includes("rollback_deferred"), "tray does not show deferrals");
});

// Shared with gestor_produccion backend/src/test/publish-session-hub-scanner-release.test.js:
// the publisher, this signer and the PowerShell updater must produce the same bytes.
const GOLDEN_STATEMENT =
  "session-hub-scanner-bridge-release/v1\nchannel=stable\nversion=1.1.0\nsha256=" +
  "a".repeat(64) +
  "\nsize_bytes=4096\nmin_installed_version=1.1.0\n";

test("signed manifest contract: golden bytes, closed schema and signed_channels match the publisher", () => {
  assert.equal(
    lib.buildStatement({ channel: "stable", version: "1.1.0", sha256: "a".repeat(64), size_bytes: 4096, min_installed_version: "1.1.0" }),
    GOLDEN_STATEMENT,
  );
  const ps = fs.readFileSync(path.join(root, "update-session-hub-scanner.ps1"), "utf8");
  const list = (name) =>
    Array.from(ps.match(new RegExp("\\$" + name + " = @\\(([^)]*)\\)"))[1].matchAll(/'([^']+)'/g)).map((m) => m[1]);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-schema-"));
  try {
    const { privateKey } = crypto.generateKeyPairSync("rsa", {
      modulusLength: 3072,
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    const zip = path.join(dir, "p.zip");
    fs.writeFileSync(zip, crypto.randomBytes(64));
    const { entry } = lib.buildSignedEntry({ zipPath: zip, channel: "stable", version: "1.1.0", minInstalledVersion: "1.1.0", privateKeyPem: privateKey, keyId: "k" });
    assert.deepEqual(Object.keys(entry).sort(), [...list("SignedEntryKeys")].sort());
    assert.deepEqual(Object.keys(entry.signature).sort(), [...list("SignatureKeys")].sort());
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  assert.ok(ps.includes("$entry = $manifest.signed_channels.$Channel"), "updater must read signed_channels");
  assert.equal(/\$manifest\.channels\b/.test(ps), false, "updater must not read legacy channels");
  assert.ok(ps.includes("-cnotmatch '^[0-9a-f]{64}$'"), "sha must be lowercase-only like the publisher");
});

// On Windows execute the actual updater functions under BOTH engines. Only
// function ASTs are loaded: no updater top-level paths, tasks or update run.
test("Windows RSA verifies the actual updater statement and rejects tampering in PS5.1 and PS7", { skip: process.platform !== "win32" }, () => {
  const { spawnSync } = require("node:child_process");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-windows-rsa-"));
  try {
    const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
      modulusLength: 3072,
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    const fields = { channel: "lab", version: "1.2.0", sha256: "a".repeat(64), size_bytes: 4096, min_installed_version: "1.2.0" };
    const statement = lib.buildStatement(fields);
    const fixture = {
      pin: lib.publicKeyToPin(publicKey, "disposable-ci-only"), entry: fields, statement,
      signature: { alg: lib.SIGNATURE_ALG, key_id: "disposable-ci-only", value: lib.signStatement(statement, privateKey) },
    };
    // Disposable private key stays in memory and is never written or uploaded.
    const fixtureFile = path.join(dir, "public-fixture.json");
    fs.writeFileSync(fixtureFile, JSON.stringify(fixture));
    const scriptFile = path.join(dir, "verify.ps1");
    fs.writeFileSync(scriptFile, `param([string]$Source, [string]$Fixture)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'UPDATER_PARSE_FAILED' }
foreach ($name in @('Get-ReleaseStatement', 'Test-ReleaseSignature')) {
  $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  if (-not $fn) { throw "FUNCTION_MISSING $name" }
  . ([scriptblock]::Create($fn.Extent.Text))
}
$f = Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json
$ReleaseStatementHeader = 'session-hub-scanner-bridge-release/v1'
$ReleaseSignatureAlg = 'RSA-SHA256-PKCS1'
$PinnedReleaseKeys = @($f.pin)
$statement = Get-ReleaseStatement -ChannelName $f.entry.channel -Entry $f.entry
if ($statement -cne $f.statement) { throw 'STATEMENT_BYTES_MISMATCH' }
if (-not (Test-ReleaseSignature -Statement $statement -Signature $f.signature)) { throw 'VALID_SIGNATURE_REJECTED' }
if (Test-ReleaseSignature -Statement ($statement + 'tampered') -Signature $f.signature) { throw 'TAMPER_ACCEPTED' }
$f.signature.key_id = 'unknown-key'
if (Test-ReleaseSignature -Statement $statement -Signature $f.signature) { throw 'UNKNOWN_KEY_ACCEPTED' }
Write-Output ('WINDOWS_RSA_PASS ps=' + $PSVersionTable.PSVersion.ToString())
`);
    for (const engine of ["powershell.exe", "pwsh.exe"]) {
      const run = spawnSync(engine, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptFile, "-Source", path.join(root, "update-session-hub-scanner.ps1"), "-Fixture", fixtureFile], { encoding: "utf8", timeout: 60000 });
      assert.equal(run.error, undefined, engine + ": " + run.error);
      assert.equal(run.status, 0, engine + ": " + run.stdout + run.stderr);
      assert.match(run.stdout, /WINDOWS_RSA_PASS/);
      console.log(run.stdout.trim());
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});


test("keyboard/stdin partial input defers OTA drain until its scan is ACKed", async () => {
  const run = await startBridge({ stdin: true });
  try {
    run.child.stdin.write("KEYBOARD-PARTIAL");
    await eventually(() => (readState(run.stateFile) || {}).partial_input === true, "stdin partial input not tracked");
    run.requestDrain("keyboard-test");
    await sleep(1600);
    assert.equal(run.exited(), null, "drain cut a partial keyboard scan");
    run.child.stdin.write("-COMPLETE\n");
    await eventually(() => run.scans().length === 1, "completed keyboard scan not sent");
    assert.equal(run.exited(), null, "drain cut an unACKed keyboard scan");
    run.ackAll();
    await eventually(() => run.exited() === 0, "keyboard bridge did not drain after ACK");
  } finally {
    await run.close();
  }
});
