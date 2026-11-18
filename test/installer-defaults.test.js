const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

const root = path.resolve(__dirname, "..");
const read = (name) => fs.readFileSync(path.join(root, name), "utf8").replace(/^\uFEFF/, "");
const installer = read("install-session-hub-scanner.ps1");
const launcher = read("installer-launcher.js");
const runner = read("run-session-hub-bridge.ps1");
const tray = read("tray-session-hub-bridge.ps1");
const bridgeText = read("bridge.js");
const readme = read("README.md");
const fn = (text, name) => {
  const start = text.indexOf("function " + name);
  assert.ok(start >= 0, "missing function " + name);
  const next = text.indexOf("\nfunction ", start + 10);
  return text.slice(start, next < 0 ? undefined : next);
};

// These tests read the PowerShell text: pwsh is not available on the Linux
// runner, so what they prove is what the scripts SAY. Parsing and behavior on
// Windows are covered by the Windows job (parse + the win32-only test below) and
// by the manual run on the PC.

test("installer, launcher, runner, tray, bridge and README contain no COM6, sucursal-1-caja-1, Caja 1 or DEV address default", () => {
  const forbidden = [/sucursal-1-caja/, /Scanner Caja/, /'COM6'|"COM6"|COM6/, /devapp\.dimensioncomercial/, /dimensioncomercial\.com\.ar/];
  for (const [name, text] of Object.entries({ installer, launcher, runner, tray, bridge: bridgeText, readme }))
    for (const pattern of forbidden) assert.equal(pattern.test(text), false, name + " still has " + pattern);
  for (const decl of [/\[string\]\$BaseUrl = ''/, /\[string\]\$SerialPort = ''/, /\[string\]\$DisplayName = ''/])
    assert.match(installer, decl);
  for (const decl of [/\[string\]\$HostId = ''/, /\[string\]\$BaseUrl = ''/, /\[string\]\$SerialPort = ''/, /\[string\]\$DisplayName = ''/])
    assert.match(runner, decl);
  assert.match(tray, /\[string\]\$HostId = ''/);
});

test("install without parameters derives the station from the hostname, writes no serial_port, and fails clearly without a server address", () => {
  assert.match(fn(installer, "Get-StationName"), /\[System\.Net\.Dns\]::GetHostName\(\)/);
  const resolve = fn(installer, "Resolve-StationIdentity");
  assert.match(resolve, /ConvertTo-StationId -Name \$stationName/);
  assert.match(resolve, /HostIdSource = 'hostname'/);
  assert.match(resolve, /throw "No se pudo derivar el nombre del puesto/);
  const write = fn(installer, "Write-BridgeConfig");
  assert.match(write, /serial_port = \$Cfg\.SerialPort/);
  assert.match(write, /host_id_source = \$Cfg\.HostIdSource/);
  // nothing fills SerialPort with a COM when it is not declared
  assert.equal(/SerialPort[^\n]*'COM\d/i.test(installer), false);
  const assertServer = fn(installer, "Assert-ServerAddress");
  assert.match(assertServer, /throw 'Falta -BaseUrl/);
  assert.match(assertServer, /No hay direccion por defecto/);
  // the address is checked, and the identity resolved, before the preflight or anything is stopped
  const resolveAt = installer.indexOf("Resolve-StationIdentity -Cfg $config");
  const serverAt = installer.indexOf("Assert-ServerAddress -Cfg $config");
  const preflightAt = installer.indexOf("Invoke-InstallPreflight -Cfg $config");
  const stopAt = installer.indexOf("Invoke-Runner -Mode 'stop-tray-task'");
  assert.ok(resolveAt > 0 && serverAt > resolveAt && preflightAt > serverAt && stopAt > preflightAt);
  // the launcher cannot assume one either (this one is executed)
  const result = spawnSync(process.execPath, [path.join(root, "installer-launcher.js")], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Falta --base-url/);
});

test("the .exe launcher reuses the explicitly saved server address in a reinstall, never a default, and errors clearly with none", () => {
  const dir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "launcher-"));
  try {
    // no address given, none saved: clear error
    const none = spawnSync(process.execPath, [path.join(root, "installer-launcher.js"), "--install-root", dir], { cwd: root, encoding: "utf8" });
    assert.equal(none.status, 1);
    assert.match(none.stderr, /Falta --base-url/);
    // a saved address (and nothing else is read) lets it proceed to the installer: there is no
    // PowerShell here, so the launch itself fails, but not with the missing-address error
    fs.writeFileSync(path.join(dir, "scanner-bridge-config.json"), JSON.stringify({ base_url: "https://servidor.example.test", shared_secret: "no-leer" }));
    const saved = spawnSync(process.execPath, [path.join(root, "installer-launcher.js"), "--install-root", dir], { cwd: root, encoding: "utf8" });
    assert.doesNotMatch(saved.stderr, /Falta --base-url/);
    assert.equal(saved.stdout.includes("no-leer") || saved.stderr.includes("no-leer"), false);
    // an invalid saved value is not an address
    fs.writeFileSync(path.join(dir, "scanner-bridge-config.json"), JSON.stringify({ base_url: "no-es-url" }));
    const bad = spawnSync(process.execPath, [path.join(root, "installer-launcher.js"), "--install-root", dir], { cwd: root, encoding: "utf8" });
    assert.match(bad.stderr, /Falta --base-url/);
  } finally {
    fs.unlinkSync(path.join(dir, "scanner-bridge-config.json"));
    fs.rmdirSync(dir);
  }
});

test("no file of the package teaches a shared default (build scripts included)", () => {
  // wait-and-run-serial-bridge.ps1 is an orphan development script (no package, installer or script
  // references it) that still carries the old defaults; it is outside this lane's write set and is
  // reported to the integrator instead of being edited here.
  const orphans = ["wait-and-run-serial-bridge.ps1"];
  const files = fs.readdirSync(root).filter((name) => (/\.(ps1|js|md)$/.test(name) || name === "package.json") && !orphans.includes(name));
  assert.ok(files.includes("build-session-hub-scanner-installer-exe.ps1"));
  for (const name of files)
    for (const pattern of [/sucursal-1-caja/, /Scanner Caja/, /--serial-port COM\d/, /devapp\./, /dimensioncomercial/])
      assert.equal(pattern.test(read(name)), false, name + " still has " + pattern);
});

test("reinstall takes the hostname for host_id and display_name; a stored host_id is never reused", () => {
  const merge = fn(installer, "Merge-PreservedConfig");
  const map = merge.slice(merge.indexOf("$map = [ordered]@{"), merge.indexOf("}", merge.indexOf("$map = [ordered]@{")));
  assert.equal(/host_id/.test(map), false, "Merge-PreservedConfig would inherit the old host_id");
  assert.equal(/display_name/.test(map), false, "Merge-PreservedConfig would inherit the old display name");
  for (const key of ["readers_json", "shared_secret", "symbology", "reader_device_id", "reader_usb_id", "base_url", "update_manifest_url"])
    assert.ok(map.includes("'" + key + "'"), key + " is not preserved");
  assert.ok(installer.indexOf("Merge-PreservedConfig -Cfg $config") < installer.indexOf("Resolve-StationIdentity -Cfg $config"));
  const resolve = fn(installer, "Resolve-StationIdentity");
  assert.match(resolve, /\$Cfg\.DisplayName = if \(\$stationName\) \{ \$stationName \}/);
  // a COM written by an older installer (no host_id_source) is never carried over
  assert.match(merge, /PSObject\.Properties\['host_id_source'\]/);
});

test("KeepHostId and HostId are the only explicit ways to keep a name; display_name stays the hostname", () => {
  const resolve = fn(installer, "Resolve-StationIdentity");
  assert.match(resolve, /\$Cfg\.KeepHostId\.Trim\(\)/);
  assert.match(resolve, /HostIdSource = 'explicit'/);
  assert.match(installer, /\[string\]\$KeepHostId = ''/);
  assert.match(launcher, /"KeepHostId"/);
  assert.match(launcher, /"keep-host-id"/);
  // explicit name is baked into the tasks only when explicit
  assert.match(installer, /HostId = if \(\$config\.HostIdSource -eq 'explicit'\) \{ \$config\.HostId \} else \{ '' \}/);
});

test("reinstall without a usable hostname and without KeepHostId fails closed", () => {
  const resolve = fn(installer, "Resolve-StationIdentity");
  assert.match(resolve, /IsNullOrWhiteSpace\(\$derived\)\) \{\s*throw/);
  assert.match(resolve, /-KeepHostId/);
  assert.equal(/HostId = .sucursal|HostId = "/.test(resolve), false);
});

test("runner does not bake HostId or SerialPort into the task arguments unless declared", () => {
  const task = fn(runner, "New-TaskActionArgumentString");
  const initial = task.slice(task.indexOf("$parts = @("), task.indexOf("  )\n"));
  assert.equal(/-HostId|-SerialPort|-DisplayName|-BaseUrl/.test(initial), false, "the base arguments carry identity");
  assert.match(task, /if \(-not \[string\]::IsNullOrWhiteSpace\(\$HostIdArg\)\) \{ \$parts \+= @\('-HostId'/);
  assert.match(task, /if \(-not \[string\]::IsNullOrWhiteSpace\(\$SerialPortArg\)\) \{ \$parts \+= @\('-SerialPort'/);
  const trayTask = fn(runner, "New-TrayTaskActionArgumentString");
  assert.equal(/'-HostId',\s*\('"'/.test(trayTask.slice(trayTask.indexOf("$parts = @("), trayTask.indexOf("  )\n"))), false);
  // the agent never receives --serial-port unless one is declared
  const launch = fn(runner, "Resolve-BridgeLaunchCommand");
  assert.equal(/'--serial-port', \$SerialPort,/.test(launch), false);
  assert.equal((launch.match(/if \(\$SerialPort\) \{/g) || []).length, 2);
  // the effective name is the hostname on every start; pre-1.3.0 baked values are ignored
  const identity = fn(runner, "Resolve-RuntimeIdentity");
  assert.match(identity, /ConvertTo-StationId -Name \$stationName/);
  assert.match(identity, /host_id_source/);
  assert.match(identity, /anterior a 1\.3\.0/);
  // a machine-level COM from an older install must not pin the reader
  assert.match(runner, /Remove-Item -Path Env:SESSION_HUB_SCANNER_SERIAL_PORT/);
  // processes of this install root are found whatever name they were started with
  assert.match(fn(runner, "Find-RunningBridgeProcesses"), /\$inThisRoot = \$normalized\.Contains\(\$root\.ToLowerInvariant\(\)\)/);
  assert.match(runner, /if \(\[string\]::IsNullOrWhiteSpace\(\$BaseUrl\)\)[\s\S]*?throw 'Falta la direccion del servidor/);
});

test("the four implementations of the station-name normalization are the same algorithm, and it gives the documented names", () => {
  const steps = (text) => {
    const body = text.slice(text.indexOf("$decomposed"), text.indexOf("return $id.TrimEnd"));
    return {
      marks: /Replace\(\$decomposed, '([^']+)'/.exec(body)[1],
      other: /Replace\(\$id, '(\[\^a-z0-9-\]\+)', '-'\)/.exec(body)[1],
      collapse: /Replace\(\$id, '(-\+)', '-'\)/.exec(body)[1],
      max: /Length -gt (\d+)/.exec(body)[1],
    };
  };
  const a = steps(fn(installer, "ConvertTo-StationId"));
  assert.deepEqual(steps(fn(runner, "ConvertTo-StationId")), a);
  assert.deepEqual(steps(fn(tray, "ConvertTo-StationId")), a);
  assert.equal(a.max, "40");
  assert.match(bridgeText, /replace\(\/\[\\u0300-\\u036f\]\/g, ""\)/);
  assert.match(bridgeText, /replace\(\/\[\^a-z0-9-\]\+\/g, "-"\)/);
  const viaPowerShellSteps = (name) =>
    String(name)
      .normalize("NFD")
      .replace(new RegExp(a.marks, "g"), "")
      .toLowerCase()
      .replace(new RegExp(a.other, "g"), "-")
      .replace(new RegExp(a.collapse, "g"), "-")
      .replace(/^-+/, "")
      .slice(0, Number(a.max))
      .replace(/-+$/, "");
  const table = [
    ["DESKTOP-ÑANDÚ 01", "desktop-nandu-01"],
    ["Caja  Norte__2 ", "caja-norte-2"],
    ["PC.Deposito/Sur", "pc-deposito-sur"],
    ["A".repeat(60), "a".repeat(40)],
    ["--Puesto--", "puesto"],
    ["***", ""],
  ];
  for (const [input, expected] of table) assert.equal(viaPowerShellSteps(input), expected, input);
});

test("config access: the secret file is SYSTEM and Administrators only, ordinary users can only write the ui folder, and failing to restrict stops the install", () => {
  const access = fn(installer, "Set-ConfigAccess");
  assert.match(access, /icacls\.exe \$ConfigPath \/inheritance:r \/grant:r '\*S-1-5-18:\(F\)' '\*S-1-5-32-544:\(F\)'/);
  assert.equal(/S-1-5-32-545/.test(access.slice(0, access.indexOf("$uiPath"))), false, "Users are granted on the config file");
  assert.match(access, /icacls\.exe \$uiPath \/grant '\*S-1-5-32-545:\(OI\)\(CI\)\(M\)'/);
  assert.match(access, /if \(\$LASTEXITCODE -ne 0\) \{\s*throw "No se pudo restringir/);
  assert.match(fn(installer, "Write-BridgeConfig"), /Set-ConfigAccess -ConfigPath \$configPath -InstallPath \$InstallPath/);
});

test("the installer declares the intentional migration to the preflight and protects the reader identity from the copy", () => {
  assert.match(fn(installer, "Invoke-InstallPreflight"), /host_id_migration = \$true/);
  assert.match(installer, /\$protectedInstallNames = @\([^)]*'reader-identity\.json'[^)]*'installation-id\.json'[^)]*'ui'/);
  assert.match(fn(runner, "Set-BridgeEnv"), /SESSION_HUB_SCANNER_IDENTITY_FILE = Join-Path \$root 'reader-identity\.json'/);
});

test("the tray never writes the configuration; it leaves a request, shows the state and the selector, and a failed write is not a dead end", () => {
  assert.equal(/scanner-bridge-config/.test(tray), false, "the tray touches the config file");
  assert.equal(/No se pudo guardar la configuraci/.test(tray), false);
  assert.match(tray, /reader-choice\.request\.json/);
  assert.match(tray, /Start-Process[^\n]*-Verb RunAs/);
  assert.match(tray, /-Mode choose-reader -ReaderUsbId/);
  assert.match(tray, /Elegir lector\.\.\./);
  assert.match(tray, /Olvidar lector recordado/);
  for (const text of ["CONFLICTO de nombre", "hay mas de un lector: elegir", "lector: $label$port"]) assert.ok(tray.includes(text), text);
  assert.match(tray, /Show-ReaderSelector/);
  assert.match(tray, /Update-ReaderAlerts/);
  assert.match(tray, /\$summary\.State -eq 'ambiguous'/);
  // the one write target is the ui folder next to bridge-state.json
  assert.match(tray, /\$uiPath = Join-Path \$root 'ui'/);
  assert.ok(/'choose-reader'/.test(runner));
  assert.match(runner, /Send-ReaderChoice/);
});

test("README documents -KeepHostId, -ReaderUsbId and the files that are kept", () => {
  for (const text of ["-KeepHostId", "-ReaderUsbId", "reader-identity.json", "installation-id.json", "SCANNER_HOST_ID_IN_USE", "ambiguous", "host_conflict"])
    assert.ok(readme.includes(text), text + " is not in the README");
});

test("Windows only: the PowerShell normalization gives the same names as the agent", { skip: process.platform !== "win32" }, () => {
  const body = fn(installer, "ConvertTo-StationId");
  const names = ["DESKTOP-ÑANDÚ 01", "Caja  Norte__2 ", "PC.Deposito/Sur", "A".repeat(60), "--Puesto--", "***"];
  const script = body + "\n" + names.map((name) => "'" + name.replace(/'/g, "''") + "' | ForEach-Object { ConvertTo-StationId -Name $_ }").join("\n");
  const result = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  const lines = result.stdout.split(/\r?\n/);
  const expected = ["desktop-nandu-01", "caja-norte-2", "pc-deposito-sur", "a".repeat(40), "puesto", ""];
  expected.forEach((name, index) => assert.equal(lines[index] || "", name, names[index]));
});
