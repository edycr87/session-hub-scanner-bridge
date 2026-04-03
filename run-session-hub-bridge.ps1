param(
  [ValidateSet('run','install-task','start-task','stop-task','status-task','tail-logs','uninstall-task','install-tray-task','start-tray-task','stop-tray-task','status-tray-task','uninstall-tray-task')]
  [string]$Mode = 'run',

  [string]$TaskName = 'SessionHubScannerBridge',
  [string]$TrayTaskName = 'SessionHubScannerBridgeTray',
  [string]$Root = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$HostId = 'sucursal-1-caja-1',
  [string]$DisplayName = 'Scanner Caja 1',
  [string]$BaseUrl = 'https://app.dimensioncomercial.com.ar',
  [string]$SerialPort = 'COM6',
  [string]$ReaderDeviceId = '',
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
$bridgeConfigPath = Join-Path $root 'scanner-bridge-config.json'

function Trace-Runner {
  param([string]$Message)
  $ts = Get-Date -Format 'o'
  try {
    Add-Content -Path $runnerLog -Value "[$ts] $Message"
  } catch {
    # ignore
  }
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
    ('"' + $RootArg + '"'),
    '-HostId',
    ('"' + $HostIdArg + '"'),
    '-DisplayName',
    ('"' + $DisplayNameArg + '"'),
    '-BaseUrl',
    ('"' + $BaseUrlArg + '"'),
    '-SerialPort',
    ('"' + $SerialPortArg + '"'),
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
    ('"' + $RootArg + '"'),
    '-HostId',
    ('"' + $HostIdArg + '"'),
    '-DisplayName',
    ('"' + $DisplayNameArg + '"'),
    '-BaseUrl',
    ('"' + $BaseUrlArg + '"'),
    '-ReaderDeviceId',
    ('"' + $ReaderDeviceIdArg + '"'),
    '-SerialPort',
    ('"' + $SerialPortArg + '"'),
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
  Trace-Runner "Set-BridgeEnv: HostId=$HostId SerialPort=$SerialPort InputMode=$InputMode BaseUrl=$BaseUrl"
  $env:SESSION_HUB_BASE_URL = $BaseUrl
  $env:SESSION_HUB_SCANNER_HOST_ID = $HostId
  $env:SESSION_HUB_SCANNER_DISPLAY_NAME = $DisplayName
  $env:SESSION_HUB_SCANNER_INPUT_MODE = $InputMode
  if ($SerialPort) { $env:SESSION_HUB_SCANNER_SERIAL_PORT = $SerialPort }
  if ($ReaderDeviceId) { $env:SESSION_HUB_SCANNER_DEVICE_ID = $ReaderDeviceId }
  $env:SESSION_HUB_SCANNER_SERIAL_BAUD_RATE = [string]$SerialBaudRate
  $env:SESSION_HUB_SCANNER_SERIAL_WAIT_MS = [string]$SerialWaitMs
  $env:SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN = '0'
  $env:SESSION_HUB_SCANNER_SERIAL_INTERACTIVE = '0'
  $env:SESSION_HUB_SCANNER_HEARTBEAT_MS = [string]$HeartbeatMs
  $env:SESSION_HUB_SCANNER_CONFIG_PATH = $bridgeConfigPath
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
      '--config-path', $bridgeConfigPath,
      '--input-mode', $InputMode,
      '--serial-port', $SerialPort,
      '--heartbeat-ms', $HeartbeatMs,
      '--serial-baud-rate', $SerialBaudRate,
      '--serial-wait-ms', $SerialWaitMs,
      '--serial-fallback', '0'
    )

    if ($ReaderDeviceId) {
      $argList += @('--scanner-device-id', $ReaderDeviceId)
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
    '--config-path', $bridgeConfigPath,
    '--input-mode', $InputMode,
    '--serial-port', $SerialPort,
    '--heartbeat-ms', $HeartbeatMs,
    '--serial-baud-rate', $SerialBaudRate,
    '--serial-wait-ms', $SerialWaitMs,
    '--serial-fallback', '0'
  )

  if ($ReaderDeviceId) {
    $argList += @('--scanner-device-id', $ReaderDeviceId)
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

    $procHostId = Resolve-HostFromCommandLine -commandLine $proc.CommandLine
    if ($targetHostId -and $procHostId -and $procHostId.ToLowerInvariant() -ne $targetHostId) {
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
  Trace-Runner "Start-Bridge requested: HostId=$HostId BaseUrl=$BaseUrl InputMode=$InputMode SerialPort=$SerialPort"
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
  Write-Host "HostId: $HostId | Modo: $InputMode | Puerto: $SerialPort | Runtime: $($bridgeCommand.Mode)"
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
    -HostIdArg $HostId `
    -DisplayNameArg $DisplayName `
    -BaseUrlArg $BaseUrl `
    -ReaderDeviceIdArg $ReaderDeviceId `
    -SerialPortArg $SerialPort `
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
    -HostIdArg $HostId `
    -DisplayNameArg $DisplayName `
    -BaseUrlArg $BaseUrl `
    -ReaderDeviceIdArg $ReaderDeviceId `
    -SerialPortArg $SerialPort `
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
      '-HostId',
      $HostId,
      '-Root',
      $root
    )
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
  Write-Host ("ConfigPath: {0}" -f $bridgeConfigPath)
  if (Test-Path $bridgeConfigPath) {
    try {
      $cfg = Get-Content -Path $bridgeConfigPath -Raw | ConvertFrom-Json
      if ($cfg.routing_mode) {
        Write-Host ("RoutingMode: {0}" -f $cfg.routing_mode)
      }
      if ($cfg.base_url) {
        Write-Host ("BaseUrl: {0}" -f $cfg.base_url)
      }
    } catch {
      Write-Host ("RoutingMode: <config parse error>")
    }
  }

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

switch ($Mode) {
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
