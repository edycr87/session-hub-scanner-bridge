const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");

// Behavior of migrate-legacy-session-hub-scanner.ps1 against FAKE folders in a
// temp ProgramData. It needs Windows PowerShell and an Administrator token, so it
// only runs in the Windows job (the Linux tests read the script text instead:
// installer-defaults.test.js). Scheduled tasks and live processes are not
// exercised here (they need a real PC: see PRUEBA_EN_WINDOWS in the PR).

const root = path.resolve(__dirname, "..");
const migrator = path.join(root, "migrate-legacy-session-hub-scanner.ps1");
const SECRET = "fixture-secret-not-for-the-receipt";

function snapshot(dir) {
  const out = {};
  const walk = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else out[path.relative(dir, full)] = fs.readFileSync(full).toString("base64");
    }
  };
  walk(dir);
  return out;
}
function today() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

test("Windows only: plan changes nothing; archive renames with a date and keeps every byte; rollback restores them", { skip: process.platform !== "win32" }, (t) => {
  // The collector masks C:\Users\<name> in every path, and the migrator refuses a
  // masked root (ROOT_PATH_MASKED): the fixtures must live outside C:\Users.
  const base = process.env.RUNNER_TEMP || os.tmpdir();
  if (/[\\/]Users[\\/]/i.test(base)) return t.skip("temp folder is under C:\\Users (paths are masked by the collector)");
  const dir = fs.mkdtempSync(path.join(base, "scanner-migrate-"));
  try {
    const programData = path.join(dir, "ProgramData");
    const startup = path.join(dir, "startup");
    fs.mkdirSync(programData);
    fs.mkdirSync(startup);
    const names = ["SessionHubScannerBridge", "SessionHubScannerBridge_Caja2", "SessionHubScannerBridge_Caja3"];
    const hostIds = ["caja-ejemplo-1", "caja-ejemplo-2", "ecrespo-pc"];
    names.forEach((name, index) => {
      const folder = path.join(programData, name);
      fs.mkdirSync(folder);
      fs.writeFileSync(path.join(folder, "bridge.js"), "// unversioned Source " + index + "\n");
      fs.writeFileSync(path.join(folder, "installed-version.txt"), "1.1.0");
      fs.writeFileSync(
        path.join(folder, "scanner-bridge-config.json"),
        JSON.stringify({ version: "1.1.0", host_id: hostIds[index], base_url: "https://servidor.example", shared_secret: SECRET, routing_mode: "backend", local_keyboard_append_enter: true }),
      );
    });
    const target = path.join(programData, names[0]);
    const launcher = path.join(startup, "SessionHubScannerBridgeTray.vbs");
    fs.writeFileSync(launcher, `shell.Run "powershell.exe -File ""${target}\\tray-session-hub-bridge.ps1"" -Root ""${target}""", 0, False\n`);
    // a name that is already taken must get a suffix, never be overwritten
    const taken = path.join(programData, `${names[2]}.respaldo-${today()}`);
    fs.mkdirSync(taken);

    const before = Object.fromEntries(names.map((name) => [name, snapshot(path.join(programData, name))]));
    const launcherBefore = fs.readFileSync(launcher);
    const env = { ...process.env, ProgramData: programData };
    const common = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", migrator, "-InstallRoot", target, "-StationId", "ecrespo-pc", "-StartupDirs", startup, "-BackupParent", programData];
    const run = (...extra) => spawnSync("powershell.exe", [...common, ...extra], { encoding: "utf8", env, input: "" });
    const unchanged = () => {
      for (const name of names) assert.deepEqual(snapshot(path.join(programData, name)), before[name], name);
      assert.deepEqual(fs.readFileSync(launcher), launcherBefore);
      assert.equal(fs.readdirSync(programData).some((entry) => entry.includes("migracion-")), false, "no migration folder yet");
    };

    const plan = run("-PlanOnly");
    if (plan.status === 3) return t.skip("the runner is not Administrator");
    assert.equal(plan.status, 0, plan.stdout + plan.stderr);
    assert.match(plan.stdout, /ATENCION: el nombre de puesto 'caja-ejemplo-1'/);
    unchanged();

    const noConsent = run();
    assert.equal(noConsent.status, 4, noConsent.stdout + noConsent.stderr);
    unchanged();

    const refused = run("-ArchiveLegacy", "-KeepHostId", "caja-ejemplo-1");
    assert.equal(refused.status, 5, refused.stdout + refused.stderr);
    assert.match(refused.stdout, /no se reutiliza/);
    unchanged();

    const archived = run("-ArchiveLegacy");
    assert.equal(archived.status, 0, archived.stdout + archived.stderr);
    assert.match(archived.stdout, /https:\/\/servidor\.example/, "the old (non secret) server address is proposed");
    const entries = fs.readdirSync(programData);
    assert.equal(entries.includes(names[0]), false);
    assert.equal(fs.existsSync(launcher), false, "the old launcher is moved away");
    assert.deepEqual(fs.readdirSync(taken), [], "the pre-existing folder is not touched");
    assert.ok(entries.includes(`${names[2]}.respaldo-${today()}-2`), "a taken name gets -2: " + entries.join(","));
    names.slice(0, 2).forEach((name) => assert.ok(entries.includes(`${name}.respaldo-${today()}`), name));
    // nothing deleted: every byte is in the renamed folder
    names.forEach((name, index) => {
      const archivedName = entries.find((entry) => entry.startsWith(name + ".respaldo-") && entry !== path.basename(taken));
      assert.deepEqual(snapshot(path.join(programData, archivedName)), before[name], name + " bytes");
      assert.ok(index >= 0);
    });

    const migrationName = entries.find((entry) => entry.startsWith("SessionHubScannerBridge.migracion-"));
    assert.ok(migrationName, "migration folder exists");
    const receiptPath = path.join(programData, migrationName, "recibo.json");
    const receiptText = fs.readFileSync(receiptPath, "utf8");
    assert.equal(receiptText.includes(SECRET), false, "the receipt carries no secret");
    const receipt = JSON.parse(receiptText.replace(/^﻿/, ""));
    assert.equal(receipt.schema, "session-hub-scanner-legacy-archive/v1");
    assert.equal(receipt.admin, true);
    assert.equal(receipt.roots.length, 3);
    assert.deepEqual(receipt.roots.filter((r) => r.other_station).map((r) => r.host_id).sort(), ["caja-ejemplo-1", "caja-ejemplo-2"]);
    assert.ok(receipt.roots.every((r) => r.archived_to));
    assert.equal(receipt.startup.length, 1);
    assert.ok(receipt.steps.every((step) => step.status === "done"), JSON.stringify(receipt.steps));
    assert.equal(fs.readFileSync(receipt.startup[0].to).equals(launcherBefore), true);

    const back = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", migrator, "-Rollback", receiptPath], { encoding: "utf8", env, input: "" });
    assert.equal(back.status, 0, back.stdout + back.stderr);
    for (const name of names) assert.deepEqual(snapshot(path.join(programData, name)), before[name], name + " restored");
    assert.deepEqual(fs.readFileSync(launcher), launcherBefore, "launcher back in its place");
    const again = JSON.parse(fs.readFileSync(receiptPath, "utf8").replace(/^﻿/, ""));
    assert.equal(again.rollbacks.length, 1);
    assert.equal(again.rollbacks[0].failed, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
