const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const diag = require("../diagnose-session-hub-scanner");

const root = path.resolve(__dirname, "..");
const TARGET = "C:\\ProgramData\\SessionHubScannerBridge";
const LEGACY = "C:\\gestor_produccion\\backend\\tools\\session-hub-scanner-bridge";
const value = (name, v) => ({ name, kind: "value", present: v !== "", value: String(v) });

function plannedDefaults(overrides = {}) {
  return {
    input_mode: "serial",
    install_root: TARGET,
    host_id: "sucursal-1-caja-1",
    display_name: "Scanner Caja 1",
    base_url: "https://devapp.dimensioncomercial.com.ar",
    serial_port: "COM6",
    reader_device_id: "",
    symbology: "",
    serial_fallback: "false",
    serial_interactive: "false",
    heartbeat_ms: 10000,
    serial_baud_rate: 9600,
    serial_wait_ms: 2000,
    task_name: "SessionHubScannerBridge",
    tray_task_name: "SessionHubScannerBridgeTray",
    updater_task_name: "SessionHubScannerBridgeUpdater",
    update_manifest_url: "",
    update_channel: "stable",
    update_interval_minutes: 240,
    install_tray: true,
    install_updater: true,
    readers: null,
    shared_secret_present: false,
    ...overrides,
  };
}
function targetRoot(keys, extra = {}) {
  return {
    path: TARGET,
    sources: ["target"],
    exists: true,
    files: [{ name: "bridge.js", sha256: "1574e8793152f18c7d8ffeec4ef933640ac892155423305ed276758c24e40485" }],
    config: { present: true, parse_ok: true, keys, readers_present: false, readers_parse_ok: true, readers: [], ...extra },
    ota: { journal_present: false },
  };
}
function facts(overrides = {}) {
  return {
    schema: diag.FACTS_SCHEMA,
    target_install_root: TARGET,
    roots: [],
    tasks: [],
    processes: [],
    startup_launchers: [],
    env: [],
    serial_ports: [{ device_id: "COM6" }, { device_id: "COM7" }],
    ...overrides,
  };
}
const codes = (result) => result.blockers.map((item) => item.code).sort();

test("installed config identical to the planned values passes", () => {
  const keys = [
    value("host_id", "sucursal-1-caja-1"),
    value("serial_port", "COM6"),
    value("base_url", "https://devapp.dimensioncomercial.com.ar/"),
    value("install_tray", "True"),
    value("heartbeat_ms", "10000"),
  ];
  const result = diag.evaluate(facts({ roots: [targetRoot(keys)] }), { context: "install", planned: plannedDefaults() });
  assert.equal(result.verdict, "PASS", JSON.stringify(result.blockers));
  assert.equal(result.identified[0].source.includes("27c0600"), true);
});

test("a June install elsewhere, with its own task, process and a secret on the command line, blocks", () => {
  const legacyRoot = {
    path: LEGACY,
    sources: ["legacy-default", "task:SessionHubScannerBridge"],
    exists: true,
    files: [{ name: "bridge.js", sha256: "x", sha256_lf: "26f60f99a642049b117b2c1d305a506c0e2b2e2a3cb763f5373c1e25404c84ff" }],
    config: { present: false, parse_ok: false, keys: [] },
  };
  const result = diag.evaluate(
    facts({
      roots: [legacyRoot, { path: TARGET, sources: ["target"], exists: false }],
      tasks: [{ name: "SessionHubScannerBridge", root_hint: LEGACY, action_arguments_redacted: '-Mode run -Root "' + LEGACY + '" -SerialPort "COM7"', secret_present: false }],
      processes: [{ pid: 4242, root_hint: LEGACY, command_line_redacted: "node.exe " + LEGACY + "\\bridge.js --shared-secret <redacted>", secret_present: true }],
    }),
    { context: "install", planned: plannedDefaults() },
  );
  assert.equal(result.verdict, "BLOCK");
  for (const code of ["OTHER_INSTALLATION_FOUND", "FOREIGN_TASK", "FOREIGN_BRIDGE_PROCESS", "SECRET_OUTSIDE_CONFIG", "TASK_SETTING_WOULD_CHANGE"])
    assert.ok(codes(result).includes(code), code + " missing: " + codes(result));
  assert.ok(result.identified[0].source.includes("92e15d8"), "LF-normalized hash not identified");
});

test("installer defaults that would overwrite stored values block (COM, URL, display name)", () => {
  const keys = [value("serial_port", "COM7"), value("display_name", "Caja Norte"), value("base_url", "https://app.dimensioncomercial.com.ar")];
  const result = diag.evaluate(facts({ roots: [targetRoot(keys)] }), { context: "install", planned: plannedDefaults() });
  assert.equal(result.verdict, "BLOCK");
  assert.equal(result.blockers.filter((item) => item.code === "VALUE_WOULD_CHANGE").length, 3);
  const passing = diag.evaluate(facts({ roots: [targetRoot(keys)] }), {
    context: "install",
    planned: plannedDefaults({ serial_port: "COM7", display_name: "Caja Norte", base_url: "https://app.dimensioncomercial.com.ar/" }),
  });
  assert.equal(passing.verdict, "PASS", JSON.stringify(passing.blockers));
});

test("readers_json: lost or changed readers block, identical readers pass", () => {
  const readers = [
    { reader_id: "left", serial_port: "COM6", scanner_device_id: "L", serial_baud_rate: "9600" },
    { reader_id: "right", serial_port: "COM7", scanner_device_id: "R", serial_baud_rate: "9600" },
  ];
  const f = facts({ roots: [targetRoot([], { readers_present: true, readers })] });
  assert.ok(codes(diag.evaluate(f, { context: "install", planned: plannedDefaults() })).includes("READERS_WOULD_BE_LOST"));
  assert.ok(codes(diag.evaluate(f, { context: "install", planned: plannedDefaults({ readers: [readers[0]] }) })).includes("READERS_WOULD_CHANGE"));
  assert.equal(diag.evaluate(f, { context: "install", planned: plannedDefaults({ readers: [...readers].reverse() }) }).verdict, "PASS");
  const broken = facts({ roots: [targetRoot([], { readers_present: true, readers_parse_ok: false })] });
  assert.ok(codes(diag.evaluate(broken, { context: "install", planned: plannedDefaults() })).includes("READERS_UNREADABLE"));
});

test("secret: stored secret not carried over blocks; unknown keys block unless acknowledged", () => {
  const keys = [{ name: "shared_secret", kind: "secret", present: true }, { name: "custom_flag", kind: "redacted", present: true }];
  const f = facts({ roots: [targetRoot(keys)] });
  const result = diag.evaluate(f, { context: "install", planned: plannedDefaults() });
  assert.deepEqual(codes(result), ["CONFIG_KEY_NOT_PRESERVED", "SECRET_WOULD_BE_LOST"]);
  const ok = diag.evaluate(f, { context: "install", planned: plannedDefaults({ shared_secret_present: true }), acknowledgeDrop: ["custom_flag"] });
  assert.equal(ok.verdict, "PASS");
});

test("environment settings outside the config block when they differ from the plan", () => {
  const f = facts({
    roots: [targetRoot([])],
    env: [
      { scope: "Machine", name: "SESSION_HUB_SCANNER_SERIAL_PORT", kind: "value", present: true, value: "COM9" },
      { scope: "Machine", name: "SESSION_HUB_SCANNER_SHARED_SECRET", kind: "secret", present: true },
    ],
  });
  assert.deepEqual(codes(diag.evaluate(f, { context: "install", planned: plannedDefaults() })), ["ENV_SETTING_WOULD_CHANGE", "SECRET_OUTSIDE_CONFIG"]);
});

test("redaction guard: any secret value or inline secret flag in the facts blocks", () => {
  const leaks = [
    facts({ roots: [targetRoot([{ name: "shared_secret", kind: "value", present: true, value: "abc" }])] }),
    facts({ processes: [{ pid: 1, root_hint: TARGET, command_line_redacted: "node bridge.js --shared-secret abc123" }] }),
    facts({ tasks: [{ name: "t", root_hint: TARGET, action_arguments_redacted: "-BaseUrl https://user:pw@host/x" }] }),
    facts({ env: [{ scope: "User", name: "SESSION_HUB_API_TOKEN", kind: "value", present: true, value: "t" }] }),
  ];
  for (const leak of leaks) assert.ok(codes(diag.evaluate(leak, { context: "report" })).includes("REDACTION_VIOLATION"));
  const clean = facts({ processes: [{ pid: 1, root_hint: TARGET, command_line_redacted: "node bridge.js --shared-secret <redacted>", secret_present: true }] });
  assert.equal(codes(diag.evaluate(clean, { context: "report" })).includes("REDACTION_VIOLATION"), false);
});

test("ota context ignores planned values but still blocks other installations; OTA in progress blocks installs", () => {
  const f = facts({
    roots: [targetRoot([value("serial_port", "COM7")]), { path: LEGACY, sources: ["legacy-default"], exists: true, files: [{ name: "bridge.js", sha256: "z" }] }],
  });
  assert.deepEqual(codes(diag.evaluate(f, { context: "ota" })), ["OTHER_INSTALLATION_FOUND", "UNKNOWN_BRIDGE_SOURCE"]);
  const busy = facts({ roots: [{ ...targetRoot([]), ota: { journal_present: true, journal_phase: "rollback_deferred" } }] });
  assert.ok(codes(diag.evaluate(busy, { context: "install", planned: plannedDefaults() })).includes("OTA_IN_PROGRESS"));
  assert.equal(diag.evaluate(busy, { context: "ota" }).verdict, "PASS");
});

test("CLI: report exits 0, install BLOCK exits 2, bad schema blocks", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-diag-"));
  try {
    const factsFile = path.join(dir, "facts.json");
    const plannedFile = path.join(dir, "planned.json");
    fs.writeFileSync(factsFile, "\uFEFF" + JSON.stringify(facts({ roots: [targetRoot([value("serial_port", "COM7")])] })));
    fs.writeFileSync(plannedFile, JSON.stringify(plannedDefaults()));
    const cli = path.join(root, "diagnose-session-hub-scanner.js");
    const report = spawnSync(process.execPath, [cli, "--facts", factsFile], { encoding: "utf8" });
    assert.equal(report.status, 0, report.stderr);
    assert.equal(JSON.parse(report.stdout).verdict, "REPORT_CLEAN");
    const install = spawnSync(process.execPath, [cli, "--facts", factsFile, "--planned", plannedFile, "--context", "install"], { encoding: "utf8" });
    assert.equal(install.status, 2, install.stdout);
    fs.writeFileSync(factsFile, JSON.stringify({ schema: "other" }));
    const bad = spawnSync(process.execPath, [cli, "--facts", factsFile, "--context", "ota"], { encoding: "utf8" });
    assert.equal(bad.status, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("parity: collector, evaluator, installer, updater and builds agree", () => {
  const read = (name) => fs.readFileSync(path.join(root, name), "utf8").replace(/^\uFEFF/, "");
  const ps = read("diagnose-session-hub-scanner.ps1");
  const installer = read("install-session-hub-scanner.ps1");
  const updater = read("update-session-hub-scanner.ps1");
  const list = (text, name) =>
    Array.from(text.match(new RegExp("\\$" + name + " = @\\(([^)]*)\\)"))[1].matchAll(/'([^']+)'/g)).map((m) => m[1]);

  assert.equal(ps.match(/\$SecretNamePattern = '([^']+)'/)[1], diag.SECRET_NAME_RE.source);
  const allow = list(ps, "ValueAllowKeys");
  for (const key of allow) assert.equal(diag.SECRET_NAME_RE.test(key), false, key + " is secret-named but allowlisted");
  for (const key of diag.COMPARED_KEYS) assert.ok(allow.includes(key), key + " is compared but never emitted");
  for (const key of allow) assert.ok(diag.NEW_INSTALLER_KEYS.includes(key), key + " unknown to the evaluator");

  const writeBlock = installer.slice(installer.indexOf("function Write-BridgeConfig"));
  const written = Array.from(writeBlock.slice(0, writeBlock.indexOf("ConvertTo-Json")).matchAll(/^\s{4}([a-z_]+) = /gm)).map((m) => m[1]);
  const optional = Array.from(installer.match(/foreach \(\$optional in @\(([^)]*)\)\)/)[1].matchAll(/'([^']+)'/g)).map((m) => m[1]);
  assert.deepEqual([...new Set([...written, ...optional])].sort(), [...diag.NEW_INSTALLER_KEYS].sort());

  // Secret-kind entries never carry a value in the collector.
  const keyFacts = ps.slice(ps.indexOf("function Get-KeyFacts"), ps.indexOf("function Get-ReaderFacts"));
  assert.match(keyFacts, /kind = 'secret'; present = \$present \}/);
  assert.match(ps, /kind = 'secret'; present = \(\$value\.Trim\(\) -ne ''\) \}/);
  assert.equal(/Stop-Process|Set-Content|Remove-Item -LiteralPath \$(?!factsFile)|Register-ScheduledTask|Stop-ScheduledTask|Disable-ScheduledTask/.test(ps), false, "diagnostic is not read-only");

  assert.ok(installer.indexOf("Invoke-InstallPreflight -Cfg $config") > 0);
  assert.ok(installer.indexOf("Invoke-InstallPreflight -Cfg $config") < installer.indexOf("Invoke-Runner -Mode 'stop-tray-task'"), "preflight must run before anything is stopped");
  const apply = updater.slice(updater.indexOf("function Apply-UpdateFromManifest"));
  assert.ok(apply.indexOf("diagnose-session-hub-scanner.ps1") > 0 && apply.indexOf("diagnose-session-hub-scanner.ps1") < apply.indexOf("Get-IdleVerdict"), "OTA diagnostic must run before drain/activation");
  for (const name of ["diagnose-session-hub-scanner.ps1", "diagnose-session-hub-scanner.js"]) {
    assert.ok(list(updater, "RequiredPackageFiles").includes(name));
    assert.ok(read("build-session-hub-scanner-package.ps1").includes("'" + name + "'"));
    assert.ok(read("build-session-hub-scanner-installer-exe.ps1").includes("'" + name + "'"));
  }
});

test("unknown installed 1.1.0 Source blocks install and OTA without changing facts", () => {
  const installed = targetRoot([value("version", "1.1.0")]);
  installed.files[0].sha256 = "594ccd9b55cfb8dbb82f06c1d109d74fcd0b12415fb26da536ba0da786058445";
  const f = facts({ roots: [installed] });
  const before = JSON.stringify(f);
  for (const context of ["install", "ota"]) {
    const result = diag.evaluate(f, { context, planned: plannedDefaults(), acknowledgeDrop: ["UNKNOWN_BRIDGE_SOURCE"] });
    assert.equal(result.verdict, "BLOCK");
    assert.ok(codes(result).includes("UNKNOWN_BRIDGE_SOURCE"));
  }
  assert.equal(JSON.stringify(f), before);
});

test("dormant Caja2 and Caja3 preserve independent config/state and block consolidation", () => {
  const roots = [targetRoot([]), ...["Caja2", "Caja3"].map((suffix) => ({
    ...targetRoot([value("host_id", suffix)]), path: TARGET + "_" + suffix,
    sources: ["known-instance-root"],
  }))];
  // A partial installation with only config also requires manual review.
  roots[2].files = [];
  const f = facts({ roots, tasks: [], processes: [] });
  const before = JSON.stringify(f);
  for (const context of ["install", "ota"]) {
    const result = diag.evaluate(f, { context, planned: plannedDefaults() });
    assert.equal(result.verdict, "BLOCK");
    assert.equal(result.blockers.filter((b) => b.code === "OTHER_INSTALLATION_FOUND").length, 2);
  }
  assert.equal(JSON.stringify(f), before);
  const collector = fs.readFileSync(path.join(root, "diagnose-session-hub-scanner.ps1"), "utf8");
  for (const suffix of ["", "_Caja2", "_Caja3"]) assert.ok(collector.includes("'SessionHubScannerBridge" + suffix + "'"));
});

test("current reviewed bridge hash is recognized; missing COM does not diagnose hardware failure", () => {
  const installed = targetRoot([value("input_mode", "keyboard"), value("serial_port", "COM6")]);
  installed.files[0].sha256 = require("node:crypto").createHash("sha256").update(fs.readFileSync(path.join(root, "bridge.js"))).digest("hex");
  const result = diag.evaluate(facts({ roots: [installed], serial_ports: [] }), { context: "ota" });
  assert.equal(result.verdict, "PASS");
  assert.ok(result.identified[0].source.includes("1.2.0"));
});

test("unattributable scanner tasks block before any task overwrite", () => {
  const f = facts({ roots: [targetRoot([])], tasks: [{ name: "SessionHubScannerBridge", root_hint: "" }] });
  assert.ok(codes(diag.evaluate(f, { context: "ota" })).includes("TASK_ROOT_UNKNOWN"));
  const updater = fs.readFileSync(path.join(root, "update-session-hub-scanner.ps1"), "utf8");
  assert.ok(updater.indexOf("if ($Mode -ne 'status-task')") < updater.indexOf("switch ($Mode)"));
});

 test("reinstall cannot silently turn keyboard input into serial", () => {
  const f = facts({ roots: [targetRoot([value("input_mode", "stdin")])] });
  assert.ok(codes(diag.evaluate(f, { context: "install", planned: plannedDefaults() })).includes("VALUE_WOULD_CHANGE"));
  assert.equal(diag.evaluate(f, { context: "ota" }).verdict, "PASS");
});

test("Windows collector blocks unknown Source in three dormant roots and preserves all fixture bytes", { skip: process.platform !== "win32" }, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scanner-unknown-installed-"));
  const fixtureFiles = [];
  try {
    for (const suffix of ["", "_Caja2", "_Caja3"]) {
      const install = path.join(dir, "SessionHubScannerBridge" + suffix);
      fs.mkdirSync(install);
      for (const [name, value] of Object.entries({
        "bridge.js": "// unversioned Source must never be installed over\n",
        "scanner-bridge-config.json": JSON.stringify({ host_id: "fixture" + suffix, input_mode: "stdin", shared_secret: "fixture-secret-not-for-report", version: "1.1.0" }),
        "bridge-state.json": JSON.stringify({ pending_total: 2, instance: suffix }),
        "installed-version.txt": "1.1.0",
      })) {
        const file = path.join(install, name);
        fs.writeFileSync(file, value);
        fixtureFiles.push([file, fs.readFileSync(file)]);
      }
    }
    for (const engine of ["powershell.exe", "pwsh.exe"]) {
      for (const context of ["install", "ota"]) {
        const report = path.join(dir, engine + "-" + context + ".json");
        const run = spawnSync(engine, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path.join(root, "diagnose-session-hub-scanner.ps1"), "-Context", context, "-TargetInstallRoot", path.join(dir, "SessionHubScannerBridge"), "-OutputPath", report], { encoding: "utf8", timeout: 60000, env: { ...process.env, ProgramData: dir } });
        assert.equal(run.status, 2, run.stdout + run.stderr);
        const text = fs.readFileSync(report, "utf8").replace(/^\uFEFF/, "");
        assert.equal(text.includes("fixture-secret-not-for-report"), false);
        const data = JSON.parse(text);
        assert.equal(data.evaluation.verdict, "BLOCK");
        assert.equal(data.evaluation.blockers.filter((b) => b.code === "UNKNOWN_BRIDGE_SOURCE").length, 3);
        assert.equal(data.evaluation.blockers.filter((b) => b.code === "OTHER_INSTALLATION_FOUND").length, 2);
        for (const [file, before] of fixtureFiles) assert.deepEqual(fs.readFileSync(file), before);
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
