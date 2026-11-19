const { spawnSync } = require("child_process");
const path = require("path");
const process = global.process;
const fs = require("fs");

const launcherDir = path.dirname(process.execPath);

function resolveInstallerScript() {
  const candidatePaths = [
    launcherDir,
    path.join(launcherDir, "payload"),
    process.cwd(),
    path.join(process.cwd(), "payload"),
  ];

  for (let i = 0; i < candidatePaths.length; i += 1) {
    const candidate = path.join(
      candidatePaths[i],
      "install-session-hub-scanner.ps1",
    );
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return null;
}

function toBoolean(value, fallback = null) {
  if (value === undefined || value === null) {
    return fallback;
  }
  const normalized = `${value}`.trim().toLowerCase();
  if (
    normalized === "1" ||
    normalized === "true" ||
    normalized === "yes" ||
    normalized === "on"
  ) {
    return true;
  }
  if (
    normalized === "0" ||
    normalized === "false" ||
    normalized === "no" ||
    normalized === "off"
  ) {
    return false;
  }
  return fallback;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      out[key] = next;
      i += 1;
    } else {
      out[key] = "true";
    }
  }
  return out;
}

function addPowerShellArg(output, key, value) {
  if (value === undefined || value === null || `${value}`.trim() === "") {
    return;
  }
  output.push(`-${key}`);
  output.push(String(value));
}

function addPowerShellBoolArg(output, key, value) {
  if (value === undefined) {
    return;
  }
  output.push(`-${key}`);
  output.push(value ? "1" : "0");
}

// Reads only the saved server address of a previous installation. Nothing else
// from the (private) configuration is read, kept or passed along.
function storedBaseUrl(installRoot) {
  try {
    const text = fs
      .readFileSync(path.join(installRoot, "scanner-bridge-config.json"), "utf8")
      .replace(/^\uFEFF/, "");
    const value = JSON.parse(text).base_url;
    return typeof value === "string" && /^https?:\/\/\S+/.test(value.trim())
      ? value.trim()
      : "";
  } catch (_) {
    return "";
  }
}

function main() {
  const installerScript = resolveInstallerScript();
  if (!installerScript) {
    console.error(
      "No se encuentra el instalador: install-session-hub-scanner.ps1",
    );
    console.error(`Ruta base: ${launcherDir}`);
    process.exit(1);
  }

  const args = parseArgs(process.argv.slice(2));
  const pwsh = process.platform === "win32" ? "powershell.exe" : "powershell";
  const installArgs = [
    "-NoProfile",
    "-NoLogo",
    "-ExecutionPolicy",
    "Bypass",
    "-WindowStyle",
    "Hidden",
    "-File",
    installerScript,
  ];

  // No shared defaults. The server address is the one given with --base-url or,
  // in a reinstall, the one explicitly saved by the previous installation (the
  // same rule as the .ps1 installer). With neither, it stops with a clear error.
  const installRoot =
    args["install-root"] ||
    args.installroot ||
    `${process.env.ProgramData || ""}\\SessionHubScannerBridge`;
  const baseUrl =
    args["base-url"] || args.baseurl || storedBaseUrl(installRoot) || "";
  // With --archive-legacy the migrator can take the address from the old
  // installation (it is not secret); the installer still fails clearly if it
  // cannot.
  const archiveLegacy = toBoolean(args["archive-legacy"] || args.archivelegacy, false);
  const planOnly = toBoolean(args["plan-only"] || args.planonly, false);
  if (!`${baseUrl}`.trim() && !archiveLegacy && !planOnly) {
    console.error(
      "Falta --base-url (direccion del servidor) y no hay una direccion guardada en una instalacion anterior. No hay direccion por defecto: no se instala.",
    );
    process.exit(1);
  }
  addPowerShellArg(
    installArgs,
    "KeepHostId",
    args["keep-host-id"] || args.keephostid || "",
  );
  addPowerShellArg(
    installArgs,
    "HostId",
    args["host-id"] || args.hostid || "",
  );
  addPowerShellArg(
    installArgs,
    "DisplayName",
    args["display-name"] || args.displayname || "",
  );
  addPowerShellArg(installArgs, "BaseUrl", baseUrl);
  addPowerShellArg(
    installArgs,
    "SerialPort",
    args["serial-port"] || args.serialport || "",
  );
  addPowerShellArg(
    installArgs,
    "ReaderUsbId",
    args["reader-usb-id"] || args.readerusbid || "",
  );
  addPowerShellArg(
    installArgs,
    "ReaderDeviceId",
    args["reader-device-id"] || args.readerdeviceid || "",
  );
  addPowerShellArg(
    installArgs,
    "ReadersJson",
    args.readers || args["readers-json"] || args.readersjson || "",
  );
  addPowerShellArg(
    installArgs,
    "SharedSecret",
    args["shared-secret"] || args.sharedsecret || "",
  );
  addPowerShellArg(installArgs, "Symbology", args.symbology || "");
  addPowerShellArg(
    installArgs,
    "SerialFallback",
    args["serial-fallback"] || args.serialfallback || "false",
  );
  addPowerShellArg(
    installArgs,
    "SerialInteractive",
    args["serial-interactive"] || args.serialinteractive || "false",
  );
  addPowerShellArg(
    installArgs,
    "TaskName",
    args["task-name"] || args.taskname || "SessionHubScannerBridge",
  );
  addPowerShellArg(
    installArgs,
    "TrayTaskName",
    args["tray-task-name"] ||
      args.traytaskname ||
      "SessionHubScannerBridgeTray",
  );
  addPowerShellArg(
    installArgs,
    "UpdaterTaskName",
    args["updater-task-name"] ||
      args.updatertaskname ||
      "SessionHubScannerBridgeUpdater",
  );
  addPowerShellArg(
    installArgs,
    "InstallRoot",
    args["install-root"] ||
      args.installroot ||
      `${process.env.ProgramData}\\SessionHubScannerBridge`,
  );
  addPowerShellArg(
    installArgs,
    "UpdateManifestUrl",
    args["manifest-url"] ||
      args.manifesturl ||
      args["update-manifest-url"] ||
      args.updatemanifesturl ||
      "",
  );
  addPowerShellArg(
    installArgs,
    "UpdateChannel",
    args["update-channel"] || args.updatechannel || "stable",
  );
  addPowerShellArg(
    installArgs,
    "UpdateIntervalMinutes",
    args["update-interval-minutes"] || args.updateintervalminutes || "240",
  );

  const startTask = toBoolean(args["start-task"], true);
  if (startTask !== null) {
    addPowerShellBoolArg(installArgs, "StartTask", startTask);
  }

  const installTray = toBoolean(args["install-tray"], true);
  if (installTray !== null) {
    addPowerShellBoolArg(installArgs, "InstallTray", installTray);
  }

  const startTrayTask = toBoolean(args["start-tray-task"], true);
  if (startTrayTask !== null) {
    addPowerShellBoolArg(installArgs, "StartTrayTask", startTrayTask);
  }

  const installUpdater = toBoolean(args["install-updater"], true);
  if (installUpdater !== null) {
    addPowerShellBoolArg(installArgs, "InstallUpdater", installUpdater);
  }

  const startUpdaterTask = toBoolean(args["start-updater-task"], true);
  if (startUpdaterTask !== null) {
    addPowerShellBoolArg(installArgs, "StartUpdaterTask", startUpdaterTask);
  }

  // Switches: explicit consent to set aside an unverifiable earlier installation
  // (nothing is deleted), or a plan-only run that changes nothing.
  if (archiveLegacy) installArgs.push("-ArchiveLegacy");
  if (planOnly) installArgs.push("-PlanOnly");

  const result = spawnSync(pwsh, installArgs, { stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  process.exit(result.status || 0);
}

main();
