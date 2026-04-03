param(
  [Parameter(Position = 0)]
  [string]$HostId,
  [string]$DisplayName = 'Scanner Caja 1',
  [string]$BaseUrl = 'https://devapp.dimensioncomercial.com.ar',
  [string]$SerialPort = 'COM6',
  [string]$ReaderDeviceId = '',
  [string]$InstallRoot = "$env:ProgramData\SessionHubScannerBridge",
  [string]$TaskName = 'SessionHubScannerBridge',
  [string]$TrayTaskName = 'SessionHubScannerBridgeTray',
  [string]$UpdaterTaskName = 'SessionHubScannerBridgeUpdater',
  [int]$HeartbeatMs = 10000,
  [int]$SerialBaudRate = 9600,
  [int]$SerialWaitMs = 2000,
  [string]$UpdateManifestUrl = '',
  [string]$UpdateChannel = 'stable',
  [int]$UpdateIntervalMinutes = 240,
  [string]$StartTask = 'true',
  [string]$InstallTray = 'true',
  [string]$StartTrayTask = 'true',
  [string]$InstallUpdater = 'true',
  [string]$StartUpdaterTask = 'true'
)
$ErrorActionPreference = 'Stop'

function Normalize-ArgKey {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  return ($Key -replace '^--?', '' -replace '[_ ]', '' -replace '-', '').ToLowerInvariant()
}

function Parse-InstallerArgs {
  param([string[]]$InputArgs)

  $values = @{}

  $positional = New-Object System.Collections.Generic.List[string]
  $i = 0
  while ($i -lt $InputArgs.Count) {
    $arg = "${InputArgs[$i]}"
    if (-not $arg.StartsWith('-')) {
      if ($arg) {
        [void]$positional.Add($arg)
      }
      $i += 1
      continue
    }

    $normalizedPair = $arg -replace '^-{1,2}', ''
    $parts = $normalizedPair -split '=', 2
    $key = Normalize-ArgKey $parts[0]

    if ($parts.Count -eq 2) {
      $values[$key] = $parts[1]
      $i += 1
      continue
    }

    $next = if ($i + 1 -lt $InputArgs.Count) { "${InputArgs[$i + 1]}" } else { $null }
    if ($next -and -not $next.StartsWith('-')) {
      $values[$key] = $next
      $i += 2
      continue
    }

    $values[$key] = 'true'
    $i += 1
  }

  if ($positional.Count -gt 0 -and -not $values.ContainsKey('hostid')) {
    $values['hostid'] = $positional[0]
  }

  return $values
}

function Read-InstallerConfig {
  param(
    [string[]]$InputArgs,
    [string]$HostIdValue,
    [string]$DisplayNameValue,
    [string]$BaseUrlValue,
    [string]$SerialPortValue,
    [string]$ReaderDeviceIdValue,
    [string]$InstallRootValue,
    [string]$TaskNameValue,
    [string]$TrayTaskNameValue,
    [string]$UpdaterTaskNameValue,
    [int]$HeartbeatMsValue,
    [int]$SerialBaudRateValue,
    [int]$SerialWaitMsValue,
    [string]$UpdateManifestUrlValue,
    [string]$UpdateChannelValue,
    [int]$UpdateIntervalMinutesValue,
    [string]$StartTaskValue,
    [string]$InstallTrayValue,
    [string]$StartTrayTaskValue,
    [string]$InstallUpdaterValue,
    [string]$StartUpdaterTaskValue
  )

  $parsed = Parse-InstallerArgs -InputArgs $InputArgs
  $boundHostId = if ($HostIdValue) { $HostIdValue } else { $null }
  $boundDisplayName = if ($DisplayNameValue) { $DisplayNameValue } else { $null }
  $boundBaseUrl = if ($BaseUrlValue) { $BaseUrlValue } else { $null }
  $boundSerialPort = if ($SerialPortValue) { $SerialPortValue } else { $null }
  $boundReaderDeviceId = if ($ReaderDeviceIdValue) { $ReaderDeviceIdValue } else { $null }
  $boundInstallRoot = if ($InstallRootValue) { $InstallRootValue } else { $null }
  $boundTaskName = if ($TaskNameValue) { $TaskNameValue } else { $null }
  $boundTrayTaskName = if ($TrayTaskNameValue) { $TrayTaskNameValue } else { $null }
  $boundUpdaterTaskName = if ($UpdaterTaskNameValue) { $UpdaterTaskNameValue } else { $null }
  $boundHeartbeatMs = if ($HeartbeatMsValue) { $HeartbeatMsValue } else { $null }
  $boundSerialBaudRate = if ($SerialBaudRateValue) { $SerialBaudRateValue } else { $null }
  $boundSerialWaitMs = if ($SerialWaitMsValue) { $SerialWaitMsValue } else { $null }
  $boundUpdateManifestUrl = if ($UpdateManifestUrlValue) { $UpdateManifestUrlValue } else { $null }
  $boundUpdateChannel = if ($UpdateChannelValue) { $UpdateChannelValue } else { $null }
  $boundUpdateIntervalMinutes = if ($UpdateIntervalMinutesValue) { $UpdateIntervalMinutesValue } else { $null }
  $boundStartTask = if ($StartTaskValue) { $StartTaskValue } else { $null }
  $boundInstallTray = if ($InstallTrayValue) { $InstallTrayValue } else { $null }
  $boundStartTrayTask = if ($StartTrayTaskValue) { $StartTrayTaskValue } else { $null }
  $boundInstallUpdater = if ($InstallUpdaterValue) { $InstallUpdaterValue } else { $null }
  $boundStartUpdaterTask = if ($StartUpdaterTaskValue) { $StartUpdaterTaskValue } else { $null }

  $cfg = @{
    HostId = if ($boundHostId) { $boundHostId } else { $parsed['hostid'] }
    DisplayName = if ($boundDisplayName) { $boundDisplayName } else { if ($parsed.ContainsKey('displayname')) { $parsed['displayname'] } else { 'Scanner Caja 1' } }
    BaseUrl = if ($boundBaseUrl) { $boundBaseUrl } else { if ($parsed.ContainsKey('baseurl')) { $parsed['baseurl'] } else { 'https://devapp.dimensioncomercial.com.ar' } }
    SerialPort = if ($boundSerialPort) { $boundSerialPort } else { if ($parsed.ContainsKey('serialport')) { $parsed['serialport'] } else { 'COM6' } }
    ReaderDeviceId = if ($boundReaderDeviceId) { $boundReaderDeviceId } else { if ($parsed.ContainsKey('readersdeviceid')) { $parsed['readersdeviceid'] } else { if ($parsed.ContainsKey('readerdeviceid')) { $parsed['readerdeviceid'] } else { '' } } }
    InstallRoot = if ($boundInstallRoot) { $boundInstallRoot } else { if ($parsed.ContainsKey('installroot')) { $parsed['installroot'] } else { "$env:ProgramData\SessionHubScannerBridge" } }
    TaskName = if ($boundTaskName) { $boundTaskName } else { if ($parsed.ContainsKey('taskname')) { $parsed['taskname'] } else { 'SessionHubScannerBridge' } }
    TrayTaskName = if ($boundTrayTaskName) { $boundTrayTaskName } else { if ($parsed.ContainsKey('traytaskname')) { $parsed['traytaskname'] } else { 'SessionHubScannerBridgeTray' } }
    UpdaterTaskName = if ($boundUpdaterTaskName) { $boundUpdaterTaskName } else { if ($parsed.ContainsKey('updatertaskname')) { $parsed['updatertaskname'] } else { 'SessionHubScannerBridgeUpdater' } }
    HeartbeatMs = if ($boundHeartbeatMs) { [int]$boundHeartbeatMs } else { if ($parsed.ContainsKey('heartbeatms')) { [int]$parsed['heartbeatms'] } else { 10000 } }
    SerialBaudRate = if ($boundSerialBaudRate) { [int]$boundSerialBaudRate } else { if ($parsed.ContainsKey('serialbaudrate')) { [int]$parsed['serialbaudrate'] } else { 9600 } }
    SerialWaitMs = if ($boundSerialWaitMs) { [int]$boundSerialWaitMs } else { if ($parsed.ContainsKey('serialwaitms')) { [int]$parsed['serialwaitms'] } else { 2000 } }
    UpdateManifestUrl = if ($boundUpdateManifestUrl) { $boundUpdateManifestUrl } else { if ($parsed.ContainsKey('updatemanifesturl')) { $parsed['updatemanifesturl'] } else { '' } }
    UpdateChannel = if ($boundUpdateChannel) { $boundUpdateChannel } else { if ($parsed.ContainsKey('updatechannel')) { $parsed['updatechannel'] } else { 'stable' } }
    UpdateIntervalMinutes = if ($boundUpdateIntervalMinutes) { [int]$boundUpdateIntervalMinutes } else { if ($parsed.ContainsKey('updateintervalminutes')) { [int]$parsed['updateintervalminutes'] } else { 240 } }
    StartTask = if ($boundStartTask) { $boundStartTask } else { if ($parsed.ContainsKey('starttask')) { $parsed['starttask'] } else { 'true' } }
    InstallTray = if ($boundInstallTray) { $boundInstallTray } else { if ($parsed.ContainsKey('installtray')) { $parsed['installtray'] } else { 'true' } }
    StartTrayTask = if ($boundStartTrayTask) { $boundStartTrayTask } else { if ($parsed.ContainsKey('starttraytask')) { $parsed['starttraytask'] } else { 'true' } }
    InstallUpdater = if ($boundInstallUpdater) { $boundInstallUpdater } else { if ($parsed.ContainsKey('installupdater')) { $parsed['installupdater'] } else { 'true' } }
    StartUpdaterTask = if ($boundStartUpdaterTask) { $boundStartUpdaterTask } else { if ($parsed.ContainsKey('startupdatertask')) { $parsed['startupdatertask'] } else { 'true' } }
  }

  if ([string]::IsNullOrWhiteSpace($cfg.HostId)) {
    throw 'Falta HostId. Use -HostId <valor> o primer argumento sin guion.'
  }

  $cfg.StartTask = if ([string]::IsNullOrWhiteSpace($cfg.StartTask)) { 'true' } else { $cfg.StartTask }
  $cfg.InstallUpdater = if ([string]::IsNullOrWhiteSpace($cfg.InstallUpdater)) { 'true' } else { $cfg.InstallUpdater }
  $cfg.StartUpdaterTask = if ([string]::IsNullOrWhiteSpace($cfg.StartUpdaterTask)) { 'true' } else { $cfg.StartUpdaterTask }
  return $cfg
}

function Normalize-Boolean {
  param([Parameter(Mandatory = $true)][string]$Value)

  $normalized = ($Value.ToString()).ToLowerInvariant().Trim()
  if ($normalized -in @('0', 'false', 'no', 'off')) { return $false }
  return $true
}

function Get-BridgePackageVersion {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath
  )

  $versionFile = Join-Path $SourcePath 'package-version.txt'
  if (Test-Path $versionFile) {
    return (Get-Content -Path $versionFile -Raw).Trim()
  }

  $packageJsonPath = Join-Path $SourcePath 'package.json'
  if (Test-Path $packageJsonPath) {
    try {
      $packageJson = Get-Content -Path $packageJsonPath -Raw | ConvertFrom-Json
      if ($packageJson.version) {
        return [string]$packageJson.version
      }
    } catch {
      # ignore malformed package json
    }
  }

  return '0.0.0'
}

function Write-BridgeConfig {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Cfg,
    [Parameter(Mandatory = $true)][string]$InstallPath,
    [Parameter(Mandatory = $true)][string]$Version
  )

  $configPath = Join-Path $InstallPath 'scanner-bridge-config.json'
  $installedVersionPath = Join-Path $InstallPath 'installed-version.txt'
  $payload = [ordered]@{
    version = $Version
    updated_at = (Get-Date).ToString('o')
    host_id = $Cfg.HostId
    display_name = $Cfg.DisplayName
    base_url = $Cfg.BaseUrl
    serial_port = $Cfg.SerialPort
    reader_device_id = $Cfg.ReaderDeviceId
    install_root = $InstallPath
    input_mode = 'serial'
    heartbeat_ms = $Cfg.HeartbeatMs
    serial_baud_rate = $Cfg.SerialBaudRate
    serial_wait_ms = $Cfg.SerialWaitMs
    task_name = $Cfg.TaskName
    tray_task_name = $Cfg.TrayTaskName
    updater_task_name = $Cfg.UpdaterTaskName
    update_manifest_url = $Cfg.UpdateManifestUrl
    update_channel = $Cfg.UpdateChannel
    update_interval_minutes = $Cfg.UpdateIntervalMinutes
    install_tray = (Normalize-Boolean -Value $Cfg.InstallTray)
    install_updater = (Normalize-Boolean -Value $Cfg.InstallUpdater)
  }

  $json = $payload | ConvertTo-Json -Depth 5
  Set-Content -Path $configPath -Value $json -Encoding UTF8
  Set-Content -Path $installedVersionPath -Value $Version -Encoding ASCII
}

function Install-TrayStartupLauncher {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Cfg
  )

  $startupDir = [Environment]::GetFolderPath('Startup')
  if ([string]::IsNullOrWhiteSpace($startupDir)) {
    return $null
  }

  if (-not (Test-Path $startupDir)) {
    New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
  }

  $launcherPath = Join-Path $startupDir 'SessionHubScannerBridgeTray.vbs'
  $powerShellExe = (Get-Command powershell).Source
  $trayScriptPath = Join-Path $Cfg.Root 'tray-session-hub-bridge.ps1'
  $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{1}" -TaskName "{2}" -TrayTaskName "{3}" -HostId "{4}" -Root "{5}"' -f `
    $powerShellExe, $trayScriptPath, $Cfg.TaskName, $Cfg.TrayTaskName, $Cfg.HostId, $Cfg.Root
  $escapedCommand = $command.Replace('"', '""')
  $content = @(
    'Set shell = CreateObject("WScript.Shell")',
    ('shell.Run "{0}", 0, False' -f $escapedCommand)
  )

  Set-Content -Path $launcherPath -Value $content -Encoding ASCII
  return $launcherPath
}

function Invoke-Runner {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$RunnerPath,
    [hashtable]$Cfg
  )

  $psExecutable = (Get-Command powershell).Source

  $argList = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $RunnerPath,
    '-Mode',
    $Mode
  )

  if ($Cfg.ContainsKey('TaskName') -and $Cfg.TaskName) { $argList += @('-TaskName', $Cfg.TaskName) }
  if ($Cfg.ContainsKey('Root') -and $Cfg.Root) { $argList += @('-Root', $Cfg.Root) }
  if ($Cfg.ContainsKey('HostId') -and $Cfg.HostId) { $argList += @('-HostId', $Cfg.HostId) }
  if ($Cfg.ContainsKey('DisplayName') -and $Cfg.DisplayName) { $argList += @('-DisplayName', $Cfg.DisplayName) }
  if ($Cfg.ContainsKey('BaseUrl') -and $Cfg.BaseUrl) { $argList += @('-BaseUrl', $Cfg.BaseUrl) }
  if ($Cfg.ContainsKey('SerialPort') -and $Cfg.SerialPort) { $argList += @('-SerialPort', $Cfg.SerialPort) }
  if ($Cfg.ContainsKey('ReaderDeviceId') -and $Cfg.ReaderDeviceId) { $argList += @('-ReaderDeviceId', $Cfg.ReaderDeviceId) }
  if ($Cfg.ContainsKey('InputMode') -and $Cfg.InputMode) { $argList += @('-InputMode', $Cfg.InputMode) }
  if ($Cfg.ContainsKey('HeartbeatMs')) { $argList += @('-HeartbeatMs', [string]$Cfg.HeartbeatMs) }
  if ($Cfg.ContainsKey('SerialBaudRate')) { $argList += @('-SerialBaudRate', [string]$Cfg.SerialBaudRate) }
  if ($Cfg.ContainsKey('SerialWaitMs')) { $argList += @('-SerialWaitMs', [string]$Cfg.SerialWaitMs) }
  if ($Cfg.ContainsKey('TrayTaskName') -and $Cfg.TrayTaskName) { $argList += @('-TrayTaskName', $Cfg.TrayTaskName) }

  & $psExecutable @argList | Out-Host
}

$config = Read-InstallerConfig -InputArgs $args `
  -HostIdValue $HostId `
  -DisplayNameValue $DisplayName `
  -BaseUrlValue $BaseUrl `
  -SerialPortValue $SerialPort `
  -ReaderDeviceIdValue $ReaderDeviceId `
  -InstallRootValue $InstallRoot `
  -TaskNameValue $TaskName `
  -TrayTaskNameValue $TrayTaskName `
  -UpdaterTaskNameValue $UpdaterTaskName `
  -HeartbeatMsValue $HeartbeatMs `
  -SerialBaudRateValue $SerialBaudRate `
  -SerialWaitMsValue $SerialWaitMs `
  -UpdateManifestUrlValue $UpdateManifestUrl `
  -UpdateChannelValue $UpdateChannel `
  -UpdateIntervalMinutesValue $UpdateIntervalMinutes `
  -StartTaskValue $StartTask `
  -InstallTrayValue $InstallTray `
  -StartTrayTaskValue $StartTrayTask `
  -InstallUpdaterValue $InstallUpdater `
  -StartUpdaterTaskValue $StartUpdaterTask

$runner = Join-Path $PSScriptRoot 'run-session-hub-bridge.ps1'
if (-not (Test-Path $runner)) {
  throw "No se encuentra run-session-hub-bridge.ps1 en $PSScriptRoot"
}

try {
  Invoke-Runner -Mode 'stop-tray-task' -RunnerPath $runner -Cfg @{
    TrayTaskName = $config.TrayTaskName
  }
} catch {
  # ignore if tray task not found
}

try {
  Invoke-Runner -Mode 'stop-task' -RunnerPath $runner -Cfg @{
    TaskName = $config.TaskName
    HostId = $config.HostId
    Root = $config.InstallRoot
  }
} catch {
  # ignore if task not found or task stop fails
}

try {
  $runningInstalled = Get-CimInstance Win32_Process | Where-Object {
    if (-not $_.CommandLine) {
      return $false
    }
    $_.CommandLine -like "*$($config.InstallRoot.Replace('\', '\\'))*bridge.js*" -or
    $_.CommandLine -like "*$($config.InstallRoot.Replace('\', '\\'))*session-hub-scanner-bridge.exe*"
  }
  if ($runningInstalled) {
    $runningInstalled | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
} catch {
  # ignore lock/permission errors while stopping installed processes
}

if (-not (Test-Path $config.InstallRoot)) {
  New-Item -ItemType Directory -Path $config.InstallRoot -Force | Out-Null
}

Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $config.InstallRoot -Recurse -Force

$packageVersion = Get-BridgePackageVersion -SourcePath $PSScriptRoot

Set-Location $config.InstallRoot
if ((Test-Path 'node.exe') -and (Test-Path 'bridge.js') -and (Test-Path 'node_modules')) {
  Write-Host "Runtime self-contained detectado: node.exe portable + node_modules"
} elseif (Test-Path 'session-hub-scanner-bridge.exe') {
  Write-Host "Runtime self-contained detectado: session-hub-scanner-bridge.exe"
} elseif ((Test-Path 'package-lock.json') -and (Test-Path 'package.json')) {
  Write-Host "Instalando dependencias npm..."
  npm ci
} else {
  throw "No se encontró runtime instalable en $($config.InstallRoot)"
}

$cfgTask = @{
  HostId = $config.HostId
  DisplayName = $config.DisplayName
  BaseUrl = $config.BaseUrl
  SerialPort = $config.SerialPort
  ReaderDeviceId = $config.ReaderDeviceId
  InputMode = 'serial'
  HeartbeatMs = $config.HeartbeatMs
  SerialBaudRate = $config.SerialBaudRate
  SerialWaitMs = $config.SerialWaitMs
  TaskName = $config.TaskName
  Root = $config.InstallRoot
  TrayTaskName = $config.TrayTaskName
  UpdaterTaskName = $config.UpdaterTaskName
  UpdateManifestUrl = $config.UpdateManifestUrl
  UpdateChannel = $config.UpdateChannel
  UpdateIntervalMinutes = $config.UpdateIntervalMinutes
  InstallTray = $config.InstallTray
  InstallUpdater = $config.InstallUpdater
}

$startupLauncher = $null

Write-BridgeConfig -Cfg $config -InstallPath $config.InstallRoot -Version $packageVersion

Invoke-Runner -Mode 'install-task' -RunnerPath $runner -Cfg $cfgTask
if ((Normalize-Boolean -Value $config.InstallTray)) {
  try {
    Invoke-Runner -Mode 'uninstall-tray-task' -RunnerPath $runner -Cfg $cfgTask
  } catch {
    # ignore if tray task does not exist
  }
  $startupLauncher = Install-TrayStartupLauncher -Cfg $cfgTask
  if ($startupLauncher) {
    Write-Host "Launcher de autoinicio tray: $startupLauncher"
  }
}

$startTaskEnabled = Normalize-Boolean -Value $config.StartTask
if ($startTaskEnabled) {
  Invoke-Runner -Mode 'start-task' -RunnerPath $runner -Cfg @{ TaskName = $config.TaskName; Root = $config.InstallRoot }
  Invoke-Runner -Mode 'status-task' -RunnerPath $runner -Cfg @{ TaskName = $config.TaskName; Root = $config.InstallRoot }
}

if ((Normalize-Boolean -Value $config.InstallTray) -and (Normalize-Boolean -Value $config.StartTrayTask) -and $startupLauncher) {
  & wscript.exe $startupLauncher
  Start-Sleep -Seconds 2
  Invoke-Runner -Mode 'status-tray-task' -RunnerPath $runner -Cfg @{ TrayTaskName = $config.TrayTaskName; HostId = $config.HostId; Root = $config.InstallRoot }
}

$updaterScript = Join-Path $config.InstallRoot 'update-session-hub-scanner.ps1'
if ((Normalize-Boolean -Value $config.InstallUpdater) -and -not [string]::IsNullOrWhiteSpace($config.UpdateManifestUrl) -and (Test-Path $updaterScript)) {
  $psExecutable = (Get-Command powershell).Source
  $updaterInstallArgs = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $updaterScript,
    '-Mode',
    'install-task',
    '-InstallRoot',
    $config.InstallRoot,
    '-UpdaterTaskName',
    $config.UpdaterTaskName,
    '-ManifestUrl',
    $config.UpdateManifestUrl,
    '-Channel',
    $config.UpdateChannel,
    '-UpdateIntervalMinutes',
    [string]$config.UpdateIntervalMinutes
  )
  & $psExecutable @updaterInstallArgs | Out-Host

  if (Normalize-Boolean -Value $config.StartUpdaterTask) {
    $updaterStartArgs = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      $updaterScript,
      '-Mode',
      'start-task',
      '-InstallRoot',
      $config.InstallRoot,
      '-UpdaterTaskName',
      $config.UpdaterTaskName
    )
    & $psExecutable @updaterStartArgs | Out-Host
  }
} elseif (Normalize-Boolean -Value $config.InstallUpdater) {
  Write-Host 'Updater omitido: no hay UpdateManifestUrl configurado.'
}

Write-Host "Instalacion finalizada."
Write-Host "Instalacion Root: $($config.InstallRoot)"
Write-Host "Task: $($config.TaskName)"
Write-Host "TrayTask: $($config.TrayTaskName)"
Write-Host "UpdaterTask: $($config.UpdaterTaskName)"
Write-Host "Version: $packageVersion"
Write-Host "UpdateManifestUrl: $($config.UpdateManifestUrl)"
Write-Host "HostId: $($config.HostId) | Puerto: $($config.SerialPort) | ReaderDeviceId: $($config.ReaderDeviceId)"

