param(
  [Parameter(Position = 0)]
  [string]$HostId,
  [string]$KeepHostId = '',
  [string]$DisplayName = '',
  [string]$BaseUrl = '',
  [string]$SerialPort = '',
  [string]$ReaderUsbId = '',
  [string]$ReaderDeviceId = '',
  [string]$ReadersJson = '',
  [string]$SharedSecret = '',
  [string]$Symbology = '',
  [string]$SerialFallback = 'false',
  [string]$SerialInteractive = 'false',
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
  [string]$StartUpdaterTask = 'true',
  [string]$AcknowledgeDiagnosticDrop = '',
  # Consent to set aside (rename, never delete) an earlier installation that
  # this package cannot verify. See migrate-legacy-session-hub-scanner.ps1.
  [switch]$ArchiveLegacy,
  # Print what -ArchiveLegacy would do and stop. Changes nothing.
  [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'

# The installer stops and replaces scheduled tasks and processes; without
# Administrator those steps fail silently and files would be copied over a live
# agent. It stops first, before reading anything. No automatic relaunch: that
# would pass -SharedSecret through a new command line.
function Assert-Administrator {
  $isAdmin = $false
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    $isAdmin = $false
  }
  if (-not $isAdmin) {
    Write-Host 'NOT_ADMIN: Este instalador necesita permisos de Administrador. Cerra esta ventana, abri PowerShell con "Ejecutar como administrador" y repeti el mismo comando. No se toco nada.'
    exit 3
  }
}
Assert-Administrator

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
    [string]$KeepHostIdValue,
    [string]$DisplayNameValue,
    [string]$BaseUrlValue,
    [string]$SerialPortValue,
    [string]$ReaderUsbIdValue,
    [string]$ReaderDeviceIdValue,
    [string]$ReadersJsonValue,
    [string]$SharedSecretValue,
    [string]$SymbologyValue,
    [string]$SerialFallbackValue,
    [string]$SerialInteractiveValue,
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
  $boundKeepHostId = if ($KeepHostIdValue) { $KeepHostIdValue } else { $null }
  $boundReaderUsbId = if ($ReaderUsbIdValue) { $ReaderUsbIdValue } else { $null }
  $boundDisplayName = if ($DisplayNameValue) { $DisplayNameValue } else { $null }
  $boundBaseUrl = if ($BaseUrlValue) { $BaseUrlValue } else { $null }
  $boundSerialPort = if ($SerialPortValue) { $SerialPortValue } else { $null }
  $boundReaderDeviceId = if ($ReaderDeviceIdValue) { $ReaderDeviceIdValue } else { $null }
  $boundReadersJson = if ($ReadersJsonValue) { $ReadersJsonValue } else { $null }
  $boundSharedSecret = if ($SharedSecretValue) { $SharedSecretValue } else { $null }
  $boundSymbology = if ($SymbologyValue) { $SymbologyValue } else { $null }
  $boundSerialFallback = if ($SerialFallbackValue) { $SerialFallbackValue } else { $null }
  $boundSerialInteractive = if ($SerialInteractiveValue) { $SerialInteractiveValue } else { $null }
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
    KeepHostId = if ($boundKeepHostId) { $boundKeepHostId } else { if ($parsed.ContainsKey('keephostid')) { $parsed['keephostid'] } else { '' } }
    DisplayName = if ($boundDisplayName) { $boundDisplayName } else { if ($parsed.ContainsKey('displayname')) { $parsed['displayname'] } else { '' } }
    BaseUrl = if ($boundBaseUrl) { $boundBaseUrl } else { if ($parsed.ContainsKey('baseurl')) { $parsed['baseurl'] } else { '' } }
    SerialPort = if ($boundSerialPort) { $boundSerialPort } else { if ($parsed.ContainsKey('serialport')) { $parsed['serialport'] } else { '' } }
    ReaderUsbId = if ($boundReaderUsbId) { $boundReaderUsbId } else { if ($parsed.ContainsKey('readerusbid')) { $parsed['readerusbid'] } else { '' } }
    ReaderDeviceId = if ($boundReaderDeviceId) { $boundReaderDeviceId } else { if ($parsed.ContainsKey('readersdeviceid')) { $parsed['readersdeviceid'] } else { if ($parsed.ContainsKey('readerdeviceid')) { $parsed['readerdeviceid'] } else { '' } } }
    ReadersJson = if ($boundReadersJson) { $boundReadersJson } else { if ($parsed.ContainsKey('readersjson')) { $parsed['readersjson'] } else { '' } }
    SharedSecret = if ($boundSharedSecret) { $boundSharedSecret } else { if ($parsed.ContainsKey('sharedsecret')) { $parsed['sharedsecret'] } else { '' } }
    Symbology = if ($boundSymbology) { $boundSymbology } else { if ($parsed.ContainsKey('symbology')) { $parsed['symbology'] } else { '' } }
    SerialFallback = if ($boundSerialFallback) { $boundSerialFallback } else { if ($parsed.ContainsKey('serialfallback')) { $parsed['serialfallback'] } else { 'false' } }
    SerialInteractive = if ($boundSerialInteractive) { $boundSerialInteractive } else { if ($parsed.ContainsKey('serialinteractive')) { $parsed['serialinteractive'] } else { 'false' } }
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

  # No HostId is required: the station is named after the PC (see
  # Resolve-StationIdentity). A name is explicit only with -KeepHostId/-HostId.
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

# The station name is the hostname of the PC. Same rules as bridge.js
# (normalizeHostId): lower case, no accents, [a-z0-9-], repeated '-' collapsed,
# no '-' at the ends, at most 40 characters.
function ConvertTo-StationId {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
  $decomposed = $Name.Normalize([System.Text.NormalizationForm]::FormD)
  $id = [regex]::Replace($decomposed, '[\u0300-\u036f]', '').ToLowerInvariant()
  $id = [regex]::Replace($id, '[^a-z0-9-]+', '-')
  $id = [regex]::Replace($id, '-+', '-')
  $id = $id.TrimStart('-')
  if ($id.Length -gt 40) { $id = $id.Substring(0, 40) }
  return $id.TrimEnd('-')
}

function Get-StationName {
  $name = ''
  try { $name = [System.Net.Dns]::GetHostName() } catch { $name = '' }
  if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$env:COMPUTERNAME }
  return ([string]$name).Trim()
}

# host_id = hostname normalized, display_name = hostname as is, in every
# install (new or reinstall). A previous host_id is kept only with an explicit
# -KeepHostId (or -HostId). There is no shared default: if nothing usable is
# available the installer stops.
function Resolve-StationIdentity {
  param([Parameter(Mandatory = $true)][hashtable]$Cfg)

  $stationName = Get-StationName
  $explicit = ''
  if (-not [string]::IsNullOrWhiteSpace($Cfg.KeepHostId)) {
    $explicit = $Cfg.KeepHostId.Trim()
  } elseif (-not [string]::IsNullOrWhiteSpace($Cfg.HostId)) {
    $explicit = $Cfg.HostId.Trim()
  }

  if ($explicit) {
    if ($explicit.Length -gt 80) {
      throw 'El nombre de puesto explicito (-KeepHostId/-HostId) supera los 80 caracteres.'
    }
    $Cfg.HostId = $explicit
    $Cfg.HostIdSource = 'explicit'
  } else {
    $derived = ConvertTo-StationId -Name $stationName
    if ([string]::IsNullOrWhiteSpace($derived)) {
      throw "No se pudo derivar el nombre del puesto del hostname de la PC ('$stationName'). No se instala. Use -KeepHostId <valor> para declarar un nombre."
    }
    $Cfg.HostId = $derived
    $Cfg.HostIdSource = 'hostname'
  }

  # An explicit -DisplayName is baked into the tasks; otherwise the runner uses
  # the current hostname on every start, so a renamed PC follows without reinstall.
  $Cfg.DisplayNameExplicit = -not [string]::IsNullOrWhiteSpace($Cfg.DisplayName)
  if (-not $Cfg.DisplayNameExplicit) {
    $Cfg.DisplayName = if ($stationName) { $stationName } else { $Cfg.HostId }
  }
}

function Assert-ServerAddress {
  param([Parameter(Mandatory = $true)][hashtable]$Cfg)
  if ([string]::IsNullOrWhiteSpace($Cfg.BaseUrl)) {
    throw 'Falta -BaseUrl (direccion del servidor, por ejemplo https://servidor). No hay direccion por defecto: no se instala.'
  }
  if ($Cfg.BaseUrl -notmatch '^https?://[^/\s]+') {
    throw "BaseUrl invalida ('$($Cfg.BaseUrl)'): debe empezar con http:// o https://."
  }
}

# A reinstall (for example the manual bootstrap to the first OTA-capable
# version) must not wipe local identity, readers or secrets that were not passed
# again. Empty values inherit the stored ones; a value passed explicitly wins.
# Clearing a stored value requires editing scanner-bridge-config.json by hand.
function Merge-PreservedConfig {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Cfg,
    [Parameter(Mandatory = $true)][string]$InstallPath
  )

  $configPath = Join-Path $InstallPath 'scanner-bridge-config.json'
  if (-not (Test-Path -LiteralPath $configPath)) {
    return
  }
  try {
    $stored = [System.IO.File]::ReadAllText($configPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
  } catch {
    throw "scanner-bridge-config.json existente no se pudo leer; no se sobrescribe. Revisar el archivo antes de reinstalar."
  }
  $map = [ordered]@{
    ReadersJson = 'readers_json'
    SharedSecret = 'shared_secret'
    Symbology = 'symbology'
    ReaderDeviceId = 'reader_device_id'
    ReaderUsbId = 'reader_usb_id'
    BaseUrl = 'base_url'
    UpdateManifestUrl = 'update_manifest_url'
  }
  foreach ($key in $map.Keys) {
    $storedValue = $stored.($map[$key])
    if ([string]::IsNullOrWhiteSpace([string]$Cfg[$key]) -and -not [string]::IsNullOrWhiteSpace([string]$storedValue)) {
      $Cfg[$key] = [string]$storedValue
      Write-Host "Config preservada: $($map[$key])"
    }
  }
  # An explicit COM pin written by a 1.3.0 install is kept; a COM written by an
  # older installer was a shared default (the very defect) and is never kept.
  if ($stored.PSObject.Properties['host_id_source'] -and [string]::IsNullOrWhiteSpace($Cfg.SerialPort) -and -not [string]::IsNullOrWhiteSpace([string]$stored.serial_port)) {
    $Cfg.SerialPort = [string]$stored.serial_port
    Write-Host 'Config preservada: serial_port (fijado a mano)'
  }
  $script:PreservedOptionalConfig = @{}
  foreach ($optional in @('update_window', 'update_quiet_seconds')) {
    if ($null -ne $stored.$optional) {
      $script:PreservedOptionalConfig[$optional] = $stored.$optional
    }
  }
}

function Get-PlannedReaders {
  param([string]$ReadersJson)
  if ([string]::IsNullOrWhiteSpace($ReadersJson)) { return $null }
  $readers = @()
  foreach ($item in @($ReadersJson | ConvertFrom-Json)) {
    $readers += [ordered]@{
      reader_id = if ($item.reader_id) { [string]$item.reader_id } else { [string]$item.readerId }
      serial_port = if ($item.serial_port) { [string]$item.serial_port } else { [string]$item.serialPort }
      scanner_device_id = if ($item.scanner_device_id) { [string]$item.scanner_device_id } elseif ($item.scannerDeviceId) { [string]$item.scannerDeviceId } else { [string]$item.device_id }
      serial_baud_rate = if ($item.serial_baud_rate) { [string]$item.serial_baud_rate } else { [string]$item.serialBaudRate }
    }
  }
  return ,$readers
}

function Invoke-InstallPreflight {
  param([Parameter(Mandatory = $true)][hashtable]$Cfg)
  $diagnostic = Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.ps1'
  if (-not (Test-Path -LiteralPath $diagnostic) -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.js'))) {
    throw 'Falta el diagnostico de preinstalacion en el paquete; no se instala (falla cerrado).'
  }
  # Planned values only; the secret travels as presence, never as a value.
  $planned = [ordered]@{
    input_mode = 'serial'
    install_root = $Cfg.InstallRoot
    host_id = $Cfg.HostId
    display_name = $Cfg.DisplayName
    host_id_migration = $true
    base_url = $Cfg.BaseUrl
    serial_port = $Cfg.SerialPort
    reader_device_id = $Cfg.ReaderDeviceId
    symbology = $Cfg.Symbology
    serial_fallback = $Cfg.SerialFallback
    serial_interactive = $Cfg.SerialInteractive
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
    readers = (Get-PlannedReaders -ReadersJson $Cfg.ReadersJson)
    shared_secret_present = -not [string]::IsNullOrWhiteSpace([string]$Cfg.SharedSecret)
  }
  $plannedPath = Join-Path ([System.IO.Path]::GetTempPath()) ('session-hub-planned-' + [guid]::NewGuid().ToString('N') + '.json')
  $reportPath = Join-Path ([System.IO.Path]::GetTempPath()) ('session-hub-preinstall-diagnostic-' + (Get-Date).ToString('yyyyMMddTHHmmss') + '.json')
  [System.IO.File]::WriteAllText($plannedPath, ($planned | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  try {
    $acknowledge = $AcknowledgeDiagnosticDrop
    & $diagnostic -Context install -TargetInstallRoot $Cfg.InstallRoot -PlannedPath $plannedPath -AcknowledgeDrop $acknowledge -OutputPath $reportPath
    $code = $LASTEXITCODE
  } finally {
    Remove-Item -LiteralPath $plannedPath -Force -ErrorAction SilentlyContinue
  }
  if ($code -ne 0) {
    throw "Diagnostico de preinstalacion: BLOQUEADO (codigo $code). No se toco nada. Informe sin secretos: $reportPath"
  }
  Write-Host "Diagnostico de preinstalacion: PASS. Informe: $reportPath"
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
    host_id_source = $Cfg.HostIdSource
    display_name = $Cfg.DisplayName
    base_url = $Cfg.BaseUrl
    serial_port = $Cfg.SerialPort
    reader_usb_id = $Cfg.ReaderUsbId
    reader_device_id = $Cfg.ReaderDeviceId
    readers_json = $Cfg.ReadersJson
    shared_secret = $Cfg.SharedSecret
    symbology = $Cfg.Symbology
    serial_fallback = $Cfg.SerialFallback
    serial_interactive = $Cfg.SerialInteractive
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
  if ($script:PreservedOptionalConfig) {
    foreach ($optional in $script:PreservedOptionalConfig.Keys) {
      $payload[$optional] = $script:PreservedOptionalConfig[$optional]
    }
  }

  $json = $payload | ConvertTo-Json -Depth 5
  Set-Content -Path $configPath -Value $json -Encoding UTF8
  Set-Content -Path $installedVersionPath -Value $Version -Encoding ASCII
  Set-ConfigAccess -ConfigPath $configPath -InstallPath $InstallPath
}

# The config can hold the shared secret: only SYSTEM and Administrators may read
# it (well-known SIDs, so it does not depend on the Windows language). The `ui`
# folder is the one place ordinary users may write: the tray icon leaves reader
# choices there and the agent validates them; the icon never writes the config.
function Set-ConfigAccess {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$InstallPath
  )

  & icacls.exe $ConfigPath /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo restringir el acceso a scanner-bridge-config.json (icacls codigo $LASTEXITCODE). Se detiene: el secreto no puede quedar legible por usuarios comunes."
  }

  $uiPath = Join-Path $InstallPath 'ui'
  if (-not (Test-Path -LiteralPath $uiPath)) {
    New-Item -ItemType Directory -Path $uiPath -Force | Out-Null
  }
  & icacls.exe $uiPath /grant '*S-1-5-32-545:(OI)(CI)(M)' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "No se pudo dar acceso de escritura a la carpeta ui (icacls codigo $LASTEXITCODE). El icono pedira elevacion para elegir el lector."
  }
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
  $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{1}" -TaskName "{2}" -TrayTaskName "{3}" -Root "{4}"' -f `
    $powerShellExe, $trayScriptPath, $Cfg.TaskName, $Cfg.TrayTaskName, $Cfg.Root
  # The name is baked only when it was declared explicitly; otherwise the tray
  # reads it from the agent state (hostname).
  if (-not [string]::IsNullOrWhiteSpace($Cfg.HostId)) {
    $command += (' -HostId "{0}"' -f $Cfg.HostId)
  }
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
  if ($Cfg.ContainsKey('ReaderUsbId') -and $Cfg.ReaderUsbId) { $argList += @('-ReaderUsbId', $Cfg.ReaderUsbId) }
  if ($Cfg.ContainsKey('ReadersJson') -and $Cfg.ReadersJson) { $argList += @('-ReadersJson', $Cfg.ReadersJson) }
  if ($Cfg.ContainsKey('InputMode') -and $Cfg.InputMode) { $argList += @('-InputMode', $Cfg.InputMode) }
  if ($Cfg.ContainsKey('HeartbeatMs')) { $argList += @('-HeartbeatMs', [string]$Cfg.HeartbeatMs) }
  if ($Cfg.ContainsKey('SerialBaudRate')) { $argList += @('-SerialBaudRate', [string]$Cfg.SerialBaudRate) }
  if ($Cfg.ContainsKey('SerialWaitMs')) { $argList += @('-SerialWaitMs', [string]$Cfg.SerialWaitMs) }
  if ($Cfg.ContainsKey('TrayTaskName') -and $Cfg.TrayTaskName) { $argList += @('-TrayTaskName', $Cfg.TrayTaskName) }

  & $psExecutable @argList | Out-Host
}

$config = Read-InstallerConfig -InputArgs $args `
  -HostIdValue $HostId `
  -KeepHostIdValue $KeepHostId `
  -DisplayNameValue $DisplayName `
  -BaseUrlValue $BaseUrl `
  -SerialPortValue $SerialPort `
  -ReaderUsbIdValue $ReaderUsbId `
  -ReaderDeviceIdValue $ReaderDeviceId `
  -ReadersJsonValue $ReadersJson `
  -SharedSecretValue $SharedSecret `
  -SymbologyValue $Symbology `
  -SerialFallbackValue $SerialFallback `
  -SerialInteractiveValue $SerialInteractive `
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

# Optional assisted migration (explicit consent only): an earlier installation
# that this package cannot verify is set aside by the migrator (tasks exported
# and disabled, its own processes stopped by path, folders renamed with a date,
# receipt written) BEFORE the preflight and BEFORE Merge-PreservedConfig reads
# the target folder. Without -ArchiveLegacy/-PlanOnly nothing changes: the
# preflight below blocks and touches nothing, as before.
if ($ArchiveLegacy -or $PlanOnly) {
  $migrator = Join-Path $PSScriptRoot 'migrate-legacy-session-hub-scanner.ps1'
  if (-not (Test-Path -LiteralPath $migrator)) {
    throw 'Falta migrate-legacy-session-hub-scanner.ps1 en el paquete; no se migra (falla cerrado).'
  }
  $explicitName = if (-not [string]::IsNullOrWhiteSpace($config.KeepHostId)) { $config.KeepHostId } else { [string]$config.HostId }
  $migrationArgs = @{
    InstallRoot = $config.InstallRoot
    StationId = (ConvertTo-StationId -Name (Get-StationName))
    BaseUrl = [string]$config.BaseUrl
    KeepHostId = [string]$explicitName
  }
  if ($PlanOnly) { $migrationArgs.PlanOnly = $true }
  elseif ($ArchiveLegacy) { $migrationArgs.ArchiveLegacy = $true }
  $migration = & $migrator @migrationArgs
  if ($LASTEXITCODE -ne 0) {
    throw "La migracion no se completo (codigo $LASTEXITCODE). Nada mas se instala. Revise el mensaje de arriba."
  }
  if ($PlanOnly) {
    Write-Host 'Solo se mostro el plan (-PlanOnly). No se instalo ni se cambio nada.'
    exit 0
  }
  $proposedBaseUrl = if ($migration) { [string]@($migration)[-1].BaseUrl } else { '' }
  if ([string]::IsNullOrWhiteSpace($config.BaseUrl) -and -not [string]::IsNullOrWhiteSpace($proposedBaseUrl)) {
    $config.BaseUrl = $proposedBaseUrl
    Write-Host "Direccion del servidor tomada de la instalacion anterior (no es secreta): $proposedBaseUrl"
  }
}

# Read-only preflight BEFORE stopping or touching anything: what is installed
# today (version, hashes, readers, manifest URL, tasks) is compared with what
# this installer is about to write. Anything it would not keep fails closed.
Merge-PreservedConfig -Cfg $config -InstallPath $config.InstallRoot
Resolve-StationIdentity -Cfg $config
Assert-ServerAddress -Cfg $config
Write-Host "Puesto: $($config.HostId) (origen: $($config.HostIdSource)) | Nombre visible: $($config.DisplayName)"
Invoke-InstallPreflight -Cfg $config

# The runner resolves -Root first and fails if the folder does not exist (a
# clean install, or a folder just set aside). Without a folder there is nothing
# of ours to stop here. -Root is always passed: the runner's own default points
# to another folder.
if (Test-Path -LiteralPath $config.InstallRoot) {
  try {
    Invoke-Runner -Mode 'stop-tray-task' -RunnerPath $runner -Cfg @{
      TrayTaskName = $config.TrayTaskName
      Root = $config.InstallRoot
    }
  } catch {
    # ignore if tray task not found
  }

  try {
    Invoke-Runner -Mode 'stop-task' -RunnerPath $runner -Cfg @{
      TaskName = $config.TaskName
      Root = $config.InstallRoot
    }
  } catch {
    # ignore if task not found or task stop fails
  }
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

$protectedInstallNames = @('scanner-bridge-config.json', 'installed-version.txt', 'bridge-state.json', 'update-drain.request', 'update-status.json', 'update.lock', '.ota', 'reader-identity.json', 'installation-id.json', 'ui')
Get-ChildItem -Path $PSScriptRoot -Force | Where-Object { $protectedInstallNames -notcontains $_.Name } | ForEach-Object {
  Copy-Item -Path $_.FullName -Destination $config.InstallRoot -Recurse -Force
}

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

# Only an explicit name or COM pin is baked into the scheduled tasks; the
# hostname is computed again by the runner on every start.
$cfgTask = @{
  HostId = if ($config.HostIdSource -eq 'explicit') { $config.HostId } else { '' }
  DisplayName = if ($config.DisplayNameExplicit) { $config.DisplayName } else { '' }
  BaseUrl = $config.BaseUrl
  SerialPort = $config.SerialPort
  ReaderUsbId = $config.ReaderUsbId
  ReaderDeviceId = $config.ReaderDeviceId
  ReadersJson = $config.ReadersJson
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
  Invoke-Runner -Mode 'status-tray-task' -RunnerPath $runner -Cfg @{ TrayTaskName = $config.TrayTaskName; Root = $config.InstallRoot }
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
$portSummary = if ([string]::IsNullOrWhiteSpace($config.SerialPort)) { '(deteccion automatica)' } else { $config.SerialPort }
Write-Host "HostId: $($config.HostId) | Puerto: $portSummary | ReaderDeviceId: $($config.ReaderDeviceId) | ReaderUsbId: $($config.ReaderUsbId)"

