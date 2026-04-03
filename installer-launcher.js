const { spawnSync } = require('child_process');
const path = require('path');
const process = global.process;
const fs = require('fs');

const launcherDir = path.dirname(process.execPath);

function resolveInstallerScript() {
  const candidatePaths = [
    launcherDir,
    path.join(launcherDir, 'payload'),
    process.cwd(),
    path.join(process.cwd(), 'payload'),
  ];

  for (let i = 0; i < candidatePaths.length; i += 1) {
    const candidate = path.join(candidatePaths[i], 'install-session-hub-scanner.ps1');
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
  if (normalized === '1' || normalized === 'true' || normalized === 'yes' || normalized === 'on') {
    return true;
  }
  if (normalized === '0' || normalized === 'false' || normalized === 'no' || normalized === 'off') {
    return false;
  }
  return fallback;
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      continue;
    }
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[key] = next;
      i += 1;
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

function addPowerShellArg(output, key, value) {
  if (value === undefined || value === null || `${value}`.trim() === '') {
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
  output.push(value ? '1' : '0');
}

function main() {
  const installerScript = resolveInstallerScript();
  if (!installerScript) {
    console.error('No se encuentra el instalador: install-session-hub-scanner.ps1');
    console.error(`Ruta base: ${launcherDir}`);
    process.exit(1);
  }

  const args = parseArgs(process.argv.slice(2));
  const pwsh = (process.platform === 'win32' ? 'powershell.exe' : 'powershell');
  const installArgs = [
    '-NoProfile',
    '-NoLogo',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    installerScript,
  ];

  addPowerShellArg(installArgs, 'HostId', args['host-id'] || args.hostid || 'sucursal-1-caja-1');
  addPowerShellArg(installArgs, 'DisplayName', args['display-name'] || args.displayname || 'Scanner Caja 1');
  addPowerShellArg(installArgs, 'BaseUrl', args['base-url'] || args.baseurl || 'https://devapp.dimensioncomercial.com.ar');
  addPowerShellArg(installArgs, 'SerialPort', args['serial-port'] || args.serialport || 'COM6');
  addPowerShellArg(installArgs, 'ReaderDeviceId', args['reader-device-id'] || args.readerdeviceid || '');
  addPowerShellArg(installArgs, 'TaskName', args['task-name'] || args.taskname || 'SessionHubScannerBridge');
  addPowerShellArg(installArgs, 'TrayTaskName', args['tray-task-name'] || args.traytaskname || 'SessionHubScannerBridgeTray');
  addPowerShellArg(installArgs, 'UpdaterTaskName', args['updater-task-name'] || args.updatertaskname || 'SessionHubScannerBridgeUpdater');
  addPowerShellArg(installArgs, 'InstallRoot', args['install-root'] || args.installroot || `${process.env.ProgramData}\\SessionHubScannerBridge`);
  addPowerShellArg(installArgs, 'UpdateManifestUrl', args['manifest-url'] || args.manifesturl || args['update-manifest-url'] || args.updatemanifesturl || '');
  addPowerShellArg(installArgs, 'UpdateChannel', args['update-channel'] || args.updatechannel || 'stable');
  addPowerShellArg(installArgs, 'UpdateIntervalMinutes', args['update-interval-minutes'] || args.updateintervalminutes || '240');

  const startTask = toBoolean(args['start-task'], true);
  if (startTask !== null) {
    addPowerShellBoolArg(installArgs, 'StartTask', startTask);
  }

  const installTray = toBoolean(args['install-tray'], true);
  if (installTray !== null) {
    addPowerShellBoolArg(installArgs, 'InstallTray', installTray);
  }

  const startTrayTask = toBoolean(args['start-tray-task'], true);
  if (startTrayTask !== null) {
    addPowerShellBoolArg(installArgs, 'StartTrayTask', startTrayTask);
  }

  const installUpdater = toBoolean(args['install-updater'], true);
  if (installUpdater !== null) {
    addPowerShellBoolArg(installArgs, 'InstallUpdater', installUpdater);
  }

  const startUpdaterTask = toBoolean(args['start-updater-task'], true);
  if (startUpdaterTask !== null) {
    addPowerShellBoolArg(installArgs, 'StartUpdaterTask', startUpdaterTask);
  }

  const result = spawnSync(pwsh, installArgs, { stdio: 'inherit' });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  process.exit(result.status || 0);
}

main();
