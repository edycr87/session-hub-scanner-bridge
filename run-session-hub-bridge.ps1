param(
  [ValidateSet('run','install-task','start-task','stop-task','status-task','tail-logs','uninstall-task','install-tray-task','start-tray-task','stop-tray-task','status-tray-task','uninstall-tray-task','choose-reader','forget-reader')]
  [string]$Mode = 'run',

  [string]$TaskName = 'SessionHubScannerBridge',
  [string]$TrayTaskName = 'SessionHubScannerBridgeTray',
  [string]$Root = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$HostId = '',
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
  [string]$InputMode = 'serial',
  [int]$HeartbeatMs = 10000,
  [int]$SerialBaudRate = 9600,
  [int]$SerialWaitMs = 2000,
  [int]$TailLines = 200,
  [int]$TrayPollMs = 1500
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path $Root).Path
$out = Join-Path $root 'bridge.log'
$err = Join-Path $root 'bridge.err'
$bridgeScript = Join-Path $root 'bridge.js'
$bundledNode = Join-Path $root 'node.exe'
$bridgeExe = Join-Path $root 'session-hub-scanner-bridge.exe'
$runnerLog = Join-Path $root 'runner.log'
$trayScript = Join-Path $root 'tray-session-hub-bridge.ps1'

function Trace-Runner {
  param([string]$Message)
  $ts = Get-Date -Format 'o'
  try {
    Add-Content -Path $runnerLog -Value "[$ts] $Message"
  } catch {
    # ignore
  }
}

# ---------------------------------------------------------------------------
# Station identity. No shared defaults: the name is the hostname (computed on
# every start, so a renamed PC follows) unless a name was declared explicitly.
# Same normalization as bridge.js and the installer.
# ---------------------------------------------------------------------------
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

function Read-StoredConfig {
  $configPath = Join-Path $root 'scanner-bridge-config.json'
  if (-not (Test-Path -LiteralPath $configPath)) { return $null }
  try {
    return ([System.IO.File]::ReadAllText($configPath).TrimStart([char]0xFEFF) | ConvertFrom-Json)
  } catch {
    # Unreadable for an ordinary user (the config is restricted) or damaged.
    return $null
  }
}

# Decides the effective HostId, DisplayName, BaseUrl, SerialPort and ReaderUsbId.
# A HostId or SerialPort baked into a scheduled task by an installer older than
# 1.3.0 is the shared-default defect and is ignored when a config exists.
function Resolve-RuntimeIdentity {
  $stored = Read-StoredConfig
  $current = $stored -and $stored.PSObject.Properties['host_id_source']
  $stationName = Get-StationName

  $script:DeclaredHostId = ''
  $script:DeclaredSerialPort = ''
  $script:DeclaredDisplayName = $DisplayName
  if ($current) {
    if (-not [string]::IsNullOrWhiteSpace($HostId)) { $script:DeclaredHostId = $HostId }
    elseif ([string]$stored.host_id_source -eq 'explicit') { $script:DeclaredHostId = [string]$stored.host_id }
    if (-not [string]::IsNullOrWhiteSpace($SerialPort)) { $script:DeclaredSerialPort = $SerialPort }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$stored.serial_port)) { $script:DeclaredSerialPort = [string]$stored.serial_port }
  } elseif (-not $stored) {
    $script:DeclaredHostId = $HostId
    $script:DeclaredSerialPort = $SerialPort
  } else {
    Trace-Runner 'Config sin host_id_source (anterior a 1.3.0): se ignoran HostId y SerialPort horneados en la tarea.'
  }

  $script:HostId = if (-not [string]::IsNullOrWhiteSpace($script:DeclaredHostId)) { $script:DeclaredHostId } else { ConvertTo-StationId -Name $stationName }
  $script:DisplayName = if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName } elseif ($stationName) { $stationName } else { $script:HostId }
  $script:SerialPort = $script:DeclaredSerialPort
  if ([string]::IsNullOrWhiteSpace($BaseUrl) -and $stored -and -not [string]::IsNullOrWhiteSpace([string]$stored.base_url)) { $script:BaseUrl = [string]$stored.base_url }
  if ([string]::IsNullOrWhiteSpace($ReaderUsbId) -and $stored -and -not [string]::IsNullOrWhiteSpace([string]$stored.reader_usb_id)) { $script:ReaderUsbId = [string]$stored.reader_usb_id }
}

function Resolve-PowerShellExecutable {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if ($pwsh) {
    return $pwsh
  }
  return (Get-Command powershell).Source
}

function Resolve-InteractiveUser {
  if ($env:USERDOMAIN -and $env:USERNAME) {
    return "$env:USERDOMAIN\$env:USERNAME"
  }

  if ($env:USERNAME) {
    if ($env:USERDOMAIN) {
      return "$env:USERDOMAIN\$env:USERNAME"
    }
    return $env:USERNAME
  }

  $identity = Get-CurrentUserPrincipal
  if ($identity) {
    return $identity
  }

  try {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.SessionId -and $_.SessionId -gt 0 } |
      Select-Object -First 1
    if ($explorer) {
      $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
      if ($owner -and $owner.User -and $owner.Domain) {
        return "$($owner.Domain)\$($owner.User)"
      }
    }
  } catch {
    # ignore
  }

  return $null
}

function Stop-RunningTrayProcesses {
  $trayProcesses = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and $_.CommandLine -like "*tray-session-hub-bridge.ps1*"
    }

  if (-not $trayProcesses) {
    return
  }

  $trayProcesses | ForEach-Object {
    try {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      Trace-Runner "Stopped tray process PID=$($_.ProcessId)"
    } catch {
      # ignore
    }
  }
}

function Get-RunningTrayProcesses {
  $trayProcesses = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and $_.CommandLine -like "*tray-session-hub-bridge.ps1*"
    }
  if (-not $trayProcesses) {
    return @()
  }
  return @($trayProcesses)
}

function New-TaskActionArgumentString {
  param(
    [string]$scriptPath,
    [string]$TaskNameArg,
    [string]$RootArg,
    [string]$HostIdArg,
    [string]$DisplayNameArg,
    [string]$BaseUrlArg,
    [string]$ReaderDeviceIdArg,
    [string]$SerialPortArg,
    [string]$InputModeArg,
    [int]$HeartbeatMsArg,
    [int]$SerialBaudRateArg,
    [int]$SerialWaitMsArg
  )

  $parts = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    ('"' + $scriptPath + '"'),
    '-Mode',
    'run',
    '-TaskName',
    ('"' + $TaskNameArg + '"'),
    '-Root',
    ('"' + $RootArg + '"')
  )
  # Only what was declared explicitly is baked: the hostname is computed at
  # every start and the reader is detected automatically.
  if (-not [string]::IsNullOrWhiteSpace($HostIdArg)) { $parts += @('-HostId', ('"' + $HostIdArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($DisplayNameArg)) { $parts += @('-DisplayName', ('"' + $DisplayNameArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($BaseUrlArg)) { $parts += @('-BaseUrl', ('"' + $BaseUrlArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($SerialPortArg)) { $parts += @('-SerialPort', ('"' + $SerialPortArg + '"')) }
  $parts += @(
    '-InputMode',
    ('"' + $InputModeArg + '"'),
    '-HeartbeatMs',
    ('"' + $HeartbeatMsArg + '"'),
    '-SerialBaudRate',
    ('"' + $SerialBaudRateArg + '"'),
    '-SerialWaitMs',
    ('"' + $SerialWaitMsArg + '"')
  )

  return ($parts -join ' ')
}

function New-TrayTaskActionArgumentString {
  param(
    [string]$TaskScriptPath,
    [string]$TaskNameArg,
    [string]$TrayTaskNameArg,
    [string]$RootArg,
    [string]$HostIdArg,
    [string]$BridgeTaskNameArg,
    [string]$DisplayNameArg,
    [string]$BaseUrlArg,
    [string]$ReaderDeviceIdArg,
    [string]$SerialPortArg,
    [string]$InputModeArg,
    [int]$HeartbeatMsArg,
    [int]$SerialBaudRateArg,
    [int]$SerialWaitMsArg,
    [int]$TailLinesArg,
    [int]$PollMsArg
  )

  $parts = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Sta',
    '-WindowStyle',
    'Hidden',
    '-File',
    ('"' + $TaskScriptPath + '"'),
    '-TaskName',
    ('"' + $TaskNameArg + '"'),
    '-TrayTaskName',
    ('"' + $TrayTaskNameArg + '"'),
    '-Root',
    ('"' + $RootArg + '"')
  )
  if (-not [string]::IsNullOrWhiteSpace($HostIdArg)) { $parts += @('-HostId', ('"' + $HostIdArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($DisplayNameArg)) { $parts += @('-DisplayName', ('"' + $DisplayNameArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($BaseUrlArg)) { $parts += @('-BaseUrl', ('"' + $BaseUrlArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($ReaderDeviceIdArg)) { $parts += @('-ReaderDeviceId', ('"' + $ReaderDeviceIdArg + '"')) }
  if (-not [string]::IsNullOrWhiteSpace($SerialPortArg)) { $parts += @('-SerialPort', ('"' + $SerialPortArg + '"')) }
  $parts += @(
    '-InputMode',
    ('"' + $InputModeArg + '"'),
    '-HeartbeatMs',
    ('"' + $HeartbeatMsArg + '"'),
    '-SerialBaudRate',
    ('"' + $SerialBaudRateArg + '"'),
    '-SerialWaitMs',
    ('"' + $SerialWaitMsArg + '"'),
    '-BridgeTaskName',
    ('"' + $BridgeTaskNameArg + '"'),
    '-TailLines',
    ('"' + $TailLinesArg + '"'),
    '-TrayPollMs',
    ('"' + $PollMsArg + '"')
  )

  return ($parts -join ' ')
}

function Set-BridgeEnv {
  $configPath = Join-Path $root 'scanner-bridge-config.json'
  if (Test-Path $configPath) {
    try { $stored = Get-Content -Path $configPath -Raw | ConvertFrom-Json; if ([string]::IsNullOrWhiteSpace($ReadersJson) -and $stored.readers_json) { $ReadersJson = [string]$stored.readers_json }; if ([string]::IsNullOrWhiteSpace($SharedSecret) -and $stored.shared_secret) { $SharedSecret = [string]$stored.shared_secret }; if ([string]::IsNullOrWhiteSpace($Symbology) -and $stored.symbology) { $Symbology = [string]$stored.symbology }; if ($stored.serial_fallback -ne $null) { $SerialFallback = [string]$stored.serial_fallback }; if ($stored.serial_interactive -ne $null) { $SerialInteractive = [string]$stored.serial_interactive } } catch { Trace-Runner "No se pudo leer configuracion bridge: $($_.Exception.Message)" }
  }
  Trace-Runner "Set-BridgeEnv: HostId=$HostId SerialPort=$(if ($SerialPort) { $SerialPort } else { '(auto)' }) InputMode=$InputMode BaseUrl=$BaseUrl"
  $env:SESSION_HUB_BASE_URL = $BaseUrl
  $env:SESSION_HUB_SCANNER_HOST_ID = $HostId
  $env:SESSION_HUB_SCANNER_DISPLAY_NAME = $DisplayName
  $env:SESSION_HUB_SCANNER_INPUT_MODE = $InputMode
  if ($SerialPort) {
    $env:SESSION_HUB_SCANNER_SERIAL_PORT = $SerialPort
  } else {
    # A machine-level COM left by an older install must not pin the reader.
    Remove-Item -Path Env:SESSION_HUB_SCANNER_SERIAL_PORT -ErrorAction SilentlyContinue
  }
  if ($ReaderUsbId) { $env:SESSION_HUB_SCANNER_READER_USB_ID = $ReaderUsbId } else { Remove-Item -Path Env:SESSION_HUB_SCANNER_READER_USB_ID -ErrorAction SilentlyContinue }
  $env:SESSION_HUB_SCANNER_IDENTITY_FILE = Join-Path $root 'reader-identity.json'
  $env:SESSION_HUB_SCANNER_INSTALLATION_FILE = Join-Path $root 'installation-id.json'
  $env:SESSION_HUB_SCANNER_UI_DIR = Join-Path $root 'ui'
  if ($ReaderDeviceId) { $env:SESSION_HUB_SCANNER_DEVICE_ID = $ReaderDeviceId }
  if ($ReadersJson) { $env:SESSION_HUB_SCANNER_READERS = $ReadersJson }
  if ($SharedSecret) { $env:SESSION_HUB_SCANNER_SHARED_SECRET = $SharedSecret }
  if ($Symbology) { $env:SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY = $Symbology }
  $env:SESSION_HUB_SCANNER_SERIAL_BAUD_RATE = [string]$SerialBaudRate
  $env:SESSION_HUB_SCANNER_SERIAL_WAIT_MS = [string]$SerialWaitMs
  $env:SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN = $SerialFallback
  $env:SESSION_HUB_SCANNER_SERIAL_INTERACTIVE = $SerialInteractive
  $env:SESSION_HUB_SCANNER_HEARTBEAT_MS = [string]$HeartbeatMs
  # OTA: local state for the updater's inactivity/health checks and the drain
  # request file the updater writes; both live next to the config, never in it.
  $env:SESSION_HUB_SCANNER_STATE_FILE = Join-Path $root 'bridge-state.json'
  $env:SESSION_HUB_SCANNER_DRAIN_FILE = Join-Path $root 'update-drain.request'
}

function Test-OtaActivationInProgress {
  $journalPath = Join-Path (Join-Path $root '.ota') 'journal.json'
  if (-not (Test-Path -LiteralPath $journalPath)) {
    return $false
  }
  try {
    $journal = [System.IO.File]::ReadAllText($journalPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    return (@('backup', 'activate') -contains [string]$journal.phase)
  } catch {
    return $false
  }
}

function Get-RunningBridgeProcesses {
  return Find-RunningBridgeProcesses
}

function Resolve-BridgeLaunchCommand {
  if ((Test-Path $bundledNode) -and (Test-Path $bridgeScript)) {
    $argList = @(
      $bridgeScript,
      '--base-url', $BaseUrl,
      '--host-id', $HostId,
      '--display-name', $DisplayName,
      '--input-mode', $InputMode,
      '--heartbeat-ms', $HeartbeatMs,
      '--serial-baud-rate', $SerialBaudRate,
      '--serial-wait-ms', $SerialWaitMs,
      '--serial-fallback', $SerialFallback,
      '--serial-interactive', $SerialInteractive
    )

    if ($ReaderDeviceId) {
      $argList += @('--scanner-device-id', $ReaderDeviceId)
    }
    # Only an explicit pin reaches the agent; otherwise it detects the reader.
    if ($SerialPort) {
      $argList += @('--serial-port', $SerialPort)
    }
    if ($ReaderUsbId) {
      $argList += @('--reader-usb-id', $ReaderUsbId)
    }

    return [PSCustomObject]@{
      FilePath = $bundledNode
      ArgumentList = $argList
      Mode = 'bundled-node'
    }
  }

  if (Test-Path $bridgeExe) {
    return [PSCustomObject]@{
      FilePath = $bridgeExe
      ArgumentList = @()
      Mode = 'exe'
    }
  }

  $node = (Get-Command node -ErrorAction Stop).Source
  $argList = @(
    $bridgeScript,
    '--base-url', $BaseUrl,
    '--host-id', $HostId,
    '--display-name', $DisplayName,
    '--input-mode', $InputMode,
    '--heartbeat-ms', $HeartbeatMs,
    '--serial-baud-rate', $SerialBaudRate,
    '--serial-wait-ms', $SerialWaitMs,
    '--serial-fallback', $SerialFallback,
    '--serial-interactive', $SerialInteractive
  )

  if ($ReaderDeviceId) {
    $argList += @('--scanner-device-id', $ReaderDeviceId)
  }
  if ($SerialPort) {
    $argList += @('--serial-port', $SerialPort)
  }
  if ($ReaderUsbId) {
    $argList += @('--reader-usb-id', $ReaderUsbId)
  }

  return [PSCustomObject]@{
    FilePath = $node
    ArgumentList = $argList
    Mode = 'node'
  }
}

function Find-RunningBridgeProcesses {
  $bridgeScriptPath = $bridgeScript.ToLowerInvariant()
  $bridgeScriptName = [IO.Path]::GetFileName($bridgeScriptPath)
  $bridgeExePath = $bridgeExe.ToLowerInvariant()
  $bridgeExeName = [IO.Path]::GetFileName($bridgeExePath)
  $targetHostId = $HostId.ToLowerInvariant()
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'node.exe' -or $_.Name -eq 'session-hub-scanner-bridge.exe'
  }

  if (-not $processes) {
    return @()
  }

  $matched = @()
  foreach ($proc in $processes) {
    if ([string]::IsNullOrWhiteSpace($proc.CommandLine)) {
      continue
    }

    $normalized = $proc.CommandLine.ToLowerInvariant()
    $isBridgeProcess = $normalized.Contains('bridge.js') -or
      $normalized.Contains($bridgeScriptPath) -or
      $normalized.Contains($bridgeScriptName) -or
      $normalized.Contains($bridgeExePath) -or
      $normalized.Contains($bridgeExeName) -or
      $normalized.Contains('session-hub-scanner-bridge')

    if (-not $isBridgeProcess) {
      continue
    }

    # A process that runs from this install root is ours whatever name it was
    # started with (for example after the station was renamed to its hostname).
    $inThisRoot = $normalized.Contains($root.ToLowerInvariant())
    $procHostId = Resolve-HostFromCommandLine -commandLine $proc.CommandLine
    if (-not $inThisRoot -and $targetHostId -and $procHostId -and $procHostId.ToLowerInvariant() -ne $targetHostId) {
      Trace-Runner "Running bridge candidate skipped by host-id mismatch: PID=$($proc.ProcessId) candidateHost=$procHostId target=$targetHostId"
      continue
    }

    $matched += $proc
  }

  return $matched
}

function Get-CurrentUserPrincipal {
  try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity -and $identity.Name) {
      return $identity.Name
    }
  } catch {
    # ignored
  }
  if ($env:USERNAME) {
    if ($env:USERDOMAIN) {
      return "$env:USERDOMAIN\$env:USERNAME"
    }
    return $env:USERNAME
  }
  return $null
}

function Resolve-HostFromCommandLine {
  param([string]$commandLine)

  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    return $null
  }

  if ($commandLine -match '--host-id\s+"?([^"\s]+)') {
    return $Matches[1]
  }

  return $null
}
function Stop-RunningBridge {
  $running = @(Get-RunningBridgeProcesses)

  if (-not $running -or $running.Count -eq 0) {
    Trace-Runner "No running bridge process found for HostId=$HostId"
    Write-Host "No hay procesos bridge activos para detener."
    return
  }

  $running | ForEach-Object {
    try {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
      Write-Host "Proceso bridge detenido: PID=$($_.ProcessId)"
      Trace-Runner "Stopped bridge PID=$($_.ProcessId)"
    } catch {
      Write-Host "No pude detener proceso $($_.ProcessId): $($_.Exception.Message)"
      Trace-Runner "Failed to stop bridge PID=$($_.ProcessId): $($_.Exception.Message)"
    }
  }
}

function Start-Bridge {
  Trace-Runner "Start-Bridge requested: HostId=$HostId BaseUrl=$BaseUrl InputMode=$InputMode SerialPort=$(if ($SerialPort) { $SerialPort } else { '(auto)' })"
  if (Test-OtaActivationInProgress) {
    Trace-Runner 'Start-Bridge refused: OTA payload swap in progress; the updater restarts the bridge.'
    Write-Host 'Actualizacion en curso: el updater vuelve a iniciar el bridge.'
    return
  }
  $staleDrain = Join-Path $root 'update-drain.request'
  if (Test-Path -LiteralPath $staleDrain) {
    Remove-Item -LiteralPath $staleDrain -Force -ErrorAction SilentlyContinue
    Trace-Runner 'Removed stale update-drain.request before start.'
  }
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    Trace-Runner 'Start-Bridge refused: no BaseUrl (not on the command line and not in scanner-bridge-config.json).'
    throw 'Falta la direccion del servidor (BaseUrl). No hay direccion por defecto: no se arranca.'
  }
  Set-Location $root
  Set-BridgeEnv

  Stop-RunningBridge | Out-Null

  $bridgeCommand = Resolve-BridgeLaunchCommand

  $bridgeProcess = Start-Process -FilePath $bridgeCommand.FilePath `
    -ArgumentList $bridgeCommand.ArgumentList `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $out `
    -RedirectStandardError $err `
    -PassThru

  $bridgePid = $bridgeProcess.Id
  Write-Host "Arrancado daemon de bridge en background con argumentos explícitos."
  Write-Host ("PID: {0}" -f $bridgePid)
  Write-Host "LOG: $out"
  Write-Host "ERR: $err"
  Write-Host "HostId: $HostId | Modo: $InputMode | Puerto: $(if ($SerialPort) { $SerialPort } else { '(deteccion automatica)' }) | Runtime: $($bridgeCommand.Mode)"
  Trace-Runner "Bridge started. PID=$bridgePid Runtime=$($bridgeCommand.Mode)"
}

function Ensure-TaskAction {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
  }

  $scriptPath = Join-Path $root 'run-session-hub-bridge.ps1'
  $pwsh = Resolve-PowerShellExecutable

  $arguments = New-TaskActionArgumentString `
    -scriptPath $scriptPath `
    -TaskNameArg $TaskName `
    -RootArg $root `
    -HostIdArg $script:DeclaredHostId `
    -DisplayNameArg $script:DeclaredDisplayName `
    -BaseUrlArg $BaseUrl `
    -ReaderDeviceIdArg $ReaderDeviceId `
    -SerialPortArg $script:DeclaredSerialPort `
    -InputModeArg $InputMode `
    -HeartbeatMsArg $HeartbeatMs `
    -SerialBaudRateArg $SerialBaudRate `
    -SerialWaitMsArg $SerialWaitMs

  $action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument $arguments
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger, $logonTrigger) -Settings $settings -Principal $principal | Out-Null
  Write-Host "Task $TaskName registrada."
}

function Ensure-TrayTaskAction {
  if (Get-ScheduledTask -TaskName $TrayTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TrayTaskName -Confirm:$false | Out-Null
  }

  if (-not (Test-Path $trayScript)) {
    throw "No se encuentra tray-session-hub-bridge.ps1 en $trayScript"
  }

  $pwsh = Resolve-PowerShellExecutable
  if (-not $pwsh) {
    throw 'No se encontró un ejecutable de PowerShell para registrar la task de tray.'
  }

  $arguments = New-TrayTaskActionArgumentString `
    -TaskScriptPath $trayScript `
    -TaskNameArg $TaskName `
    -TrayTaskNameArg $TrayTaskName `
    -RootArg $root `
    -HostIdArg $script:DeclaredHostId `
    -DisplayNameArg $script:DeclaredDisplayName `
    -BaseUrlArg $BaseUrl `
    -ReaderDeviceIdArg $ReaderDeviceId `
    -SerialPortArg $script:DeclaredSerialPort `
    -InputModeArg $InputMode `
    -HeartbeatMsArg $HeartbeatMs `
    -SerialBaudRateArg $SerialBaudRate `
    -SerialWaitMsArg $SerialWaitMs `
    -TailLinesArg $TailLines `
    -PollMsArg $TrayPollMs `
    -BridgeTaskNameArg $TaskName

  $trayAction = New-ScheduledTaskAction -Execute $pwsh -Argument $arguments
  $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
  $trayUser = Resolve-InteractiveUser
  if (-not $trayUser) {
    throw 'No se pudo resolver un usuario interactivo para la task de tray.'
  }

  $principal = $null
  try {
    $principal = New-ScheduledTaskPrincipal -UserId $trayUser -LogonType Interactive -RunLevel Highest -ErrorAction Stop
  } catch {
    $trayUser = if ($env:USERNAME) {
      if ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { $env:USERNAME }
    } else {
      'NT AUTHORITY\SYSTEM'
    }

    $principal = New-ScheduledTaskPrincipal -UserId $trayUser -LogonType Interactive -RunLevel Highest -ErrorAction Stop
  }

  Register-ScheduledTask -TaskName $TrayTaskName -Action $trayAction -Trigger @($logonTrigger) -Settings $settings -Principal $principal -ErrorAction Stop | Out-Null
  Trace-Runner "Tray task $TrayTaskName registrada para $trayUser"
  Write-Host "Task $TrayTaskName registrada para contexto de usuario $trayUser."
}

function Start-Task {
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "Task $TaskName iniciada."
}

function Start-TrayTask {
  Stop-RunningTrayProcesses
  try {
    Start-ScheduledTask -TaskName $TrayTaskName
    Trace-Runner "Tray task start requested: $TrayTaskName"
    Start-Sleep -Seconds 2
    $trayProcesses = @(Get-RunningTrayProcesses)
    if ($trayProcesses.Count -gt 0) {
      Write-Host "Tray task $TrayTaskName iniciada."
      return
    }
    Trace-Runner "Tray task start returned without active tray process."
    Write-Host "La tray task no dejó proceso activo; uso fallback local."
  } catch {
    Trace-Runner "Tray task start failed: $($_.Exception.Message)"
    Write-Host "No se pudo iniciar task de tray: $($_.Exception.Message)"
  }

  # Fallback: lanzar tray en proceso del usuario actual para garantizar feedback gráfico inmediato
  try {
    $trayScript = Join-Path $root 'tray-session-hub-bridge.ps1'
    $pwsh = Resolve-PowerShellExecutable
    if (-not $pwsh) {
      throw 'No se encontró un ejecutable de PowerShell para el fallback del tray.'
    }
    $trayArgs = @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-Sta',
      '-File',
      $trayScript,
      '-TaskName',
      $TaskName,
      '-TrayTaskName',
      $TrayTaskName,
      '-Root',
      $root
    )
    if (-not [string]::IsNullOrWhiteSpace($script:DeclaredHostId)) { $trayArgs += @('-HostId', $script:DeclaredHostId) }
    $trayProcess = Start-Process -FilePath $pwsh -ArgumentList $trayArgs -WindowStyle Hidden -PassThru
    Trace-Runner "Tray fallback process started: PID=$($trayProcess.Id)"
    Write-Host "Tray lanzada en sesión actual como fallback."
  } catch {
    Trace-Runner "Tray fallback failed: $($_.Exception.Message)"
    Write-Host "Fallo fallback tray: $($_.Exception.Message)"
  }
}

function Stop-Task {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Stop-RunningBridge
  Write-Host "Task $TaskName detenida."
}

function Stop-TrayTask {
  Stop-ScheduledTask -TaskName $TrayTaskName -ErrorAction SilentlyContinue
  Stop-RunningTrayProcesses
  Trace-Runner "Tray task stopped: $TrayTaskName"
  Write-Host "Tray task $TrayTaskName detenida."
}

function Remove-Task {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Stop-RunningBridge
  Write-Host "Task $TaskName eliminada."
}

function Remove-TrayTask {
  Unregister-ScheduledTask -TaskName $TrayTaskName -Confirm:$false
  Write-Host "Task $TrayTaskName eliminada."
}

function Show-TaskStatus {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-Host "Task $TaskName no existe."
    return
  }
  $state = Get-ScheduledTaskInfo -TaskName $TaskName
  $taskState = $task.State
  Write-Host "TaskName: $TaskName"
  Write-Host ("State: {0}" -f $taskState)
  Write-Host ("LastRunTime: {0}" -f $state.LastRunTime)
  Write-Host ("LastTaskResult: {0}" -f $state.LastTaskResult)

  $running = @(Get-RunningBridgeProcesses)
  if ($running.Count -gt 0) {
    Write-Host ('Procesos bridge activos: {0}' -f $running.Count)
    $running | ForEach-Object {
      $hostMatch = Resolve-HostFromCommandLine -commandLine $_.CommandLine
      if ([string]::IsNullOrWhiteSpace($hostMatch)) {
        $hostMatch = '(sin host-id)'
      }
      Write-Host ("  PID={0} | HostId={1} | Cmd={2}" -f $_.ProcessId, $hostMatch, $_.CommandLine)
    }
  } else {
    Write-Host 'No hay procesos bridge activos.'
  }
}

function Show-TrayTaskStatus {
  $task = Get-ScheduledTask -TaskName $TrayTaskName -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-Host "Tray task $TrayTaskName no existe."
    return
  }
  $state = Get-ScheduledTaskInfo -TaskName $TrayTaskName
  $taskState = $task.State
  Write-Host "TrayTaskName: $TrayTaskName"
  Write-Host ("State: {0}" -f $taskState)
  Write-Host ("LastRunTime: {0}" -f $state.LastRunTime)
  Write-Host ("LastTaskResult: {0}" -f $state.LastTaskResult)
  $trayProcesses = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and $_.CommandLine -like "*tray-session-hub-bridge.ps1*"
    }
  if ($trayProcesses) {
    Write-Host ('Tray processes activos: {0}' -f @($trayProcesses).Count)
    $trayProcesses | ForEach-Object {
      Write-Host ("  PID={0} | Cmd={1}" -f $_.ProcessId, $_.CommandLine)
    }
  } else {
    Write-Host 'No hay procesos tray activos.'
  }
}

function Tail-Logs {
  if (-not (Test-Path $root)) {
    throw "No existe la carpeta $root"
  }

  Write-Host "===== tail $out ====="
  if (Test-Path $out) { Get-Content -Path $out -Tail $TailLines } else { Write-Host "No existe $out" }
  Write-Host "===== tail $err ====="
  if (Test-Path $err) { Get-Content -Path $err -Tail $TailLines } else { Write-Host "No existe $err" }
}

# Leaves a reader choice for the agent in the ui folder. It is the same request
# the tray icon writes; this mode exists for an elevated retry and for manual
# use (for example: -Mode choose-reader -ReaderUsbId 0c2e:0b61/SERIE).
function Send-ReaderChoice {
  param([Parameter(Mandatory = $true)][ValidateSet('select', 'forget')][string]$Action)

  $uiPath = Join-Path $root 'ui'
  if (-not (Test-Path -LiteralPath $uiPath)) {
    New-Item -ItemType Directory -Path $uiPath -Force | Out-Null
    & icacls.exe $uiPath /grant '*S-1-5-32-545:(OI)(CI)(M)' | Out-Null
  }
  $request = [ordered]@{
    schema = 'session-hub-scanner-reader-choice/v1'
    action = $Action
    nonce = [guid]::NewGuid().ToString('N')
    requested_at = (Get-Date).ToString('o')
  }
  if ($Action -eq 'select') {
    if ($ReaderUsbId -notmatch '^\s*([0-9a-fA-F]{1,4}):([0-9a-fA-F]{1,4})(?:/(.+?))?\s*$') {
      throw 'Use -ReaderUsbId <vid:pid> o <vid:pid/serie> (por ejemplo 0c2e:0b61/SERIE).'
    }
    $request['device'] = [ordered]@{
      vendor_id = $Matches[1].ToLowerInvariant()
      product_id = $Matches[2].ToLowerInvariant()
      serial_number = if ($Matches[3]) { $Matches[3].Trim() } else { $null }
    }
  }
  $final = Join-Path $uiPath 'reader-choice.request.json'
  $temporary = $final + '.tmp'
  [System.IO.File]::WriteAllText($temporary, ($request | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $final -Force
  Write-Host "Solicitud '$Action' enviada al agente (nonce $($request.nonce)). El agente la valida contra los lectores que ve y deja el resultado en bridge-state.json (reader_choice)."
}

Resolve-RuntimeIdentity

switch ($Mode) {
  'choose-reader' {
    Send-ReaderChoice -Action 'select'
  }
  'forget-reader' {
    Send-ReaderChoice -Action 'forget'
  }
  'run' {
    Start-Bridge
  }
  'install-task' {
    Ensure-TaskAction
    if ($ReaderDeviceId) {
      Write-Host "Task $TaskName registrada con reader-device-id."
    }
  }
  'start-task' {
    Start-Task
  }
  'stop-task' {
    Stop-Task
  }
  'status-task' {
    Show-TaskStatus
  }
  'install-tray-task' {
    Ensure-TrayTaskAction
  }
  'start-tray-task' {
    Start-TrayTask
  }
  'stop-tray-task' {
    Stop-TrayTask
  }
  'status-tray-task' {
    Show-TrayTaskStatus
  }
  'uninstall-tray-task' {
    Remove-TrayTask
  }
  'tail-logs' {
    Tail-Logs
  }
  'uninstall-task' {
    Remove-Task
  }
}
