param(
  [string]$Root = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$TaskName = 'SessionHubScannerBridge',
  [string]$BridgeTaskName = 'SessionHubScannerBridge',
  [string]$HostId = 'sucursal-1-caja-1',
  [int]$TailLines = 80,
  [int]$PollMs = 1500,
  [int]$RecentScanMs = 2000,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

$bootstrapRoot = if (Test-Path $Root) { (Resolve-Path $Root).Path } else { $Root }
$bootstrapLog = Join-Path $bootstrapRoot 'tray.log'

function Write-BootstrapLog {
  param([string]$Message)
  $ts = Get-Date -Format 'o'
  try {
    Add-Content -Path $bootstrapLog -Value "[$ts] $Message"
  } catch {
    # ignore
  }
}

Write-BootstrapLog "Tray bootstrap start. Root=$bootstrapRoot Host=$HostId BridgeTask=$BridgeTaskName UserInteractive=$([Environment]::UserInteractive) Apartment=$([Threading.Thread]::CurrentThread.GetApartmentState())"

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()
  Write-BootstrapLog 'Tray assemblies loaded.'
} catch {
  Write-BootstrapLog "Tray bootstrap failed before UI start: $($_.Exception.Message)"
  throw
}

$root = (Resolve-Path $Root).Path
$bridgeLog = Join-Path $root 'bridge.log'
$runnerScript = Join-Path $root 'run-session-hub-bridge.ps1'
$outErr = Join-Path $root 'tray.log'

$state = [ordered]@{
  BridgeTaskName = $BridgeTaskName
  HostId = $HostId
  Connected = $false
  TaskState = 'Unknown'
  RunningCount = 0
  LastEvent = 'Inicializando'
  LastEventAt = Get-Date
  LastSerialPort = '(sin puerto)'
  LastDevice = '-'
  LastScan = ''
  LastScanType = ''
  LastScanTs = $null
  LastAck = ''
  LastScanStatus = 'idle'
  LastError = ''
  RecentScan = $false
}

$script:BridgeLogSignature = ''
$script:BridgeLogLoadedOnce = $false
$script:CachedTaskState = [PSCustomObject]@{
  task = 'Unknown'
  running = $false
  running_count = 0
}
$script:LastTaskStateRefresh = [datetime]::MinValue

function Log-Text {
  param([string]$Message)
  $ts = Get-Date -Format 'o'
  try {
    Add-Content -Path $outErr -Value "[$ts] $Message"
  } catch {
    # ignore
  }
}

if (-not [Environment]::UserInteractive) {
  Log-Text 'Non-interactive session detected. Tray icon may not render in this context.'
}

function Resolve-PowerShellExecutable {
  $runExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $runExe) {
    $runExe = (Get-Command powershell).Source
  }
  return $runExe
}

function Get-RunnerCommand([string]$Mode, [string]$TaskArg) {
  return @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    $runnerScript,
    '-Mode',
    $Mode,
    '-TaskName',
    $TaskArg,
    '-HostId',
    $HostId,
    '-Root',
    $root
  )
}

function Invoke-RunnerAsync([string]$Mode, [string]$TaskArg) {
  $runExe = Resolve-PowerShellExecutable
  $argList = Get-RunnerCommand -Mode $Mode -TaskArg $TaskArg
  Start-Process -FilePath $runExe -ArgumentList $argList -WindowStyle Hidden | Out-Null
}

function Get-TaskState {
  $taskState = 'Unknown'
  try {
    $task = Get-ScheduledTask -TaskName $BridgeTaskName -ErrorAction Stop
    $taskState = $task.State
  } catch {
    $taskState = 'Missing'
  }
  $isRunning = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'bridge\.js' -and $_.CommandLine -match [regex]::Escape($HostId) } |
    Measure-Object | Select-Object -ExpandProperty Count
  [PSCustomObject]@{
    task = $taskState
    running = $isRunning -gt 0
    running_count = $isRunning
  }
}

function Refresh-TaskState {
  param([switch]$Force)

  $now = Get-Date
  if (-not $Force -and (($now - $script:LastTaskStateRefresh).TotalSeconds -lt 5)) {
    return $script:CachedTaskState
  }

  $script:CachedTaskState = Get-TaskState
  $script:LastTaskStateRefresh = $now
  $state.TaskState = $script:CachedTaskState.task
  $state.RunningCount = $script:CachedTaskState.running_count
  return $script:CachedTaskState
}

function Read-BridgeLogEntries {
  if (-not (Test-Path $bridgeLog)) {
    return @()
  }

  $logInfo = Get-Item $bridgeLog -ErrorAction SilentlyContinue
  if (-not $logInfo) {
    return @()
  }

  $signature = '{0}|{1}' -f $logInfo.Length, $logInfo.LastWriteTimeUtc.Ticks
  if ($script:BridgeLogSignature -eq $signature) {
    return $null
  }

  $script:BridgeLogSignature = $signature

  try {
    $raw = if (-not $script:BridgeLogLoadedOnce) {
      Get-Content -Path $bridgeLog -Raw
    } else {
      Get-Content -Path $bridgeLog -Tail $TailLines -Raw
    }
    $script:BridgeLogLoadedOnce = $true
  } catch {
    return @()
  }

  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }

  $entries = New-Object System.Collections.Generic.List[object]
  $depth = 0
  $start = -1
  $inString = $false
  $escaped = $false

  for ($i = 0; $i -lt $raw.Length; $i++) {
    $ch = $raw[$i]

    if ($escaped) {
      $escaped = $false
      continue
    }

    if ($ch -eq '\') {
      if ($inString) {
        $escaped = $true
      }
      continue
    }

    if ($ch -eq '"') {
      $inString = -not $inString
      continue
    }

    if ($inString) {
      continue
    }

    if ($ch -eq '{') {
      if ($depth -eq 0) {
        $start = $i
      }
      $depth += 1
      continue
    }

    if ($ch -eq '}') {
      if ($depth -gt 0) {
        $depth -= 1
        if ($depth -eq 0 -and $start -ge 0) {
          $json = $raw.Substring($start, $i - $start + 1)
          try {
            [void]$entries.Add(($json | ConvertFrom-Json))
          } catch {
            Log-Text "JSON log parse failed: $($_.Exception.Message)"
          }
          $start = -1
        }
      }
    }
  }

  return $entries.ToArray()
}

function Update-ConnectionStateFromLog {
  param([switch]$ForceTaskState)

  $entries = Read-BridgeLogEntries
  if ($entries -ne $null) {
    foreach ($task in $entries) {
      if (-not $task -or -not $task.label) {
        continue
      }

      $state.LastEvent = "{0} :: {1}" -f $task.label, ($task.status -or $task.event -or '')
      $state.LastEventAt = Get-Date

      switch ($task.label) {
        'bridge.connected' {
          $state.Connected = $true
          $state.LastError = ''
        }
        'bridge.disconnected' {
          $state.Connected = $false
        }
        'bridge.status' {
          if ($task.status -eq 'starting' -and $task.serial_port) {
            $state.LastSerialPort = [string]$task.serial_port
          }
          if ($task.status -eq 'serial.port.open' -and $task.port) {
            $state.LastSerialPort = [string]$task.port
          }
          if ($task.status -eq 'serial.scan' -and $task.value) {
            $state.LastScan = [string]$task.value
            $state.LastScanType = if ($task.inferred_type) { [string]$task.inferred_type } else { 'scan' }
            $state.RecentScan = $true
            $state.LastScanTs = Get-Date
            $state.LastScanStatus = 'captured'
          }
          if ($task.status -eq 'scanner.ack') {
            if ($task.kind) {
              $state.LastAck = [string]$task.kind
            }
            if ($task.kind -and $task.kind -ne 'heartbeat') {
              $state.LastScanStatus = if ($task.ok -eq $false) { 'ack-failed' } else { 'ack' }
            }
          }
          if ($task.status -eq 'scanner.registered') {
            $state.LastScanStatus = 'registered'
          }
          if ($task.status -eq 'binding.bound') {
            $state.LastScanStatus = 'bound'
          }
          if ($task.status -eq 'binding.released') {
            $state.LastScanStatus = 'released'
          }
          if ($task.status -eq 'serial.port.failed' -and $task.message) {
            $state.LastError = [string]$task.message
            $state.LastScanStatus = 'serial-error'
          }
          if ($task.status -eq 'serial.device_id.request_not_found' -and $task.requested_device_id) {
            $state.LastError = "device_id no encontrado: $($task.requested_device_id)"
            $state.LastScanStatus = 'serial-error'
          }
        }
        'bridge.serial' {
          if ($task.port) {
            $state.LastSerialPort = [string]$task.port
          }
          if ($task.scanner_device_id) {
            $state.LastDevice = [string]$task.scanner_device_id
          }
          if ($task.status -eq 'serial.parse' -and $task.line) {
            $state.LastScan = [string]$task.line
            $state.LastScanTs = Get-Date
            $state.RecentScan = $true
            $state.LastScanStatus = 'parsed'
          }
        }
        'bridge.scan' {
          if ($task.status -eq 'scan.outbound') {
            $state.LastScan = [string]$task.value
            $state.LastScanType = if ($task.type) { [string]$task.type } else { 'scan' }
            $state.LastScanTs = Get-Date
            $state.RecentScan = $true
            $state.LastScanStatus = 'sent'
          }
        }
        'bridge.message' {
          if ($task.event -eq 'scanner.registered') {
            $state.Connected = $true
            $state.LastScanStatus = 'registered'
          }
        }
        'bridge.error' {
          if ($task.error) {
            $state.LastError = [string]$task.error
          }
          if ($task.code) {
            $state.LastError = if ($state.LastError) { "$($task.code): $($state.LastError)" } else { [string]$task.code }
          }
          if ($task.status -and $task.status -ne '') {
            $state.LastScanStatus = [string]$task.status
          }
        }
        'bridge.not_ready' {
          if ($task.reason) {
            $state.LastError = [string]$task.reason
            $state.LastScanStatus = 'not-ready'
          }
        }
        default {
          # no-op
        }
      }
    }
  }

  $current = Refresh-TaskState -Force:$ForceTaskState
  if ($current.running -and -not $state.Connected) {
    $state.Connected = $true
  }
  if (-not $current.running -and $current.task -ne 'Running') {
    $state.Connected = $false
  }
}

function Build-StatusText {
  $conn = if ($state.Connected) { 'Conectado' } else { 'Desconectado' }
  $scanInfo = ''
  if ($state.LastScan) {
    $scanInfo = " | ULT: $($state.LastScanType) $($state.LastScan)"
  }
  return "Host: $HostId | Tarea: $($state.BridgeTaskName) | $conn$scanInfo"
}

function New-QrTrayIcon {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Color]$AccentColor
  )

  $bitmap = New-Object System.Drawing.Bitmap 16, 16
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $blackBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
  $whiteBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
  $accentBrush = New-Object System.Drawing.SolidBrush $AccentColor

  function Draw-Finder {
    param(
      [System.Drawing.Graphics]$G,
      [System.Drawing.Brush]$Outer,
      [System.Drawing.Brush]$Inner,
      [int]$X,
      [int]$Y
    )

    $G.FillRectangle($Outer, $X, $Y, 5, 5)
    $G.FillRectangle($Inner, $X + 1, $Y + 1, 3, 3)
    $G.FillRectangle($Outer, $X + 2, $Y + 2, 1, 1)
  }

  Draw-Finder -G $graphics -Outer $blackBrush -Inner $whiteBrush -X 1 -Y 1
  Draw-Finder -G $graphics -Outer $blackBrush -Inner $whiteBrush -X 10 -Y 1
  Draw-Finder -G $graphics -Outer $blackBrush -Inner $whiteBrush -X 1 -Y 10

  $graphics.FillRectangle($blackBrush, 8, 8, 1, 1)
  $graphics.FillRectangle($blackBrush, 9, 9, 1, 1)
  $graphics.FillRectangle($blackBrush, 10, 8, 1, 1)
  $graphics.FillRectangle($blackBrush, 11, 10, 1, 1)
  $graphics.FillRectangle($blackBrush, 8, 11, 1, 1)
  $graphics.FillRectangle($blackBrush, 10, 12, 1, 1)
  $graphics.FillRectangle($blackBrush, 12, 11, 1, 1)

  $graphics.FillEllipse($accentBrush, 11, 11, 4, 4)
  $graphics.DrawEllipse([System.Drawing.Pens]::White, 11, 11, 4, 4)

  $graphics.Dispose()
  $blackBrush.Dispose()
  $whiteBrush.Dispose()
  $accentBrush.Dispose()

  $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon()).Clone()
  $bitmap.Dispose()
  return $icon
}

$iconConnected = New-QrTrayIcon -AccentColor ([System.Drawing.Color]::FromArgb(24, 163, 82))
$iconDisconnected = New-QrTrayIcon -AccentColor ([System.Drawing.Color]::FromArgb(214, 48, 49))
$iconScan = New-QrTrayIcon -AccentColor ([System.Drawing.Color]::FromArgb(243, 156, 18))
$iconError = New-QrTrayIcon -AccentColor ([System.Drawing.Color]::FromArgb(192, 57, 43))

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $iconDisconnected
$notify.Text = 'SessionHub Scanner Bridge'
$notify.Visible = $true
Log-Text "Tray arranque. Host=$HostId Root=$root BridgeTask=$BridgeTaskName PollMs=${PollMs}ms"
Log-Text "NotifyIcon visible. UserInteractive=$([Environment]::UserInteractive)"
try {
  $notify.BalloonTipTitle = 'Scanner host activo'
  $notify.BalloonTipText = "Host $HostId listo"
  $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
  $notify.ShowBalloonTip(2500)
} catch {
  Log-Text "No se pudo mostrar balloon tip inicial: $($_.Exception.Message)"
}

function Set-NotifyTooltipText {
  param([string]$Text)
  $normalized = if ([string]::IsNullOrWhiteSpace($Text)) { 'SessionHub Scanner Bridge' } else { "$Text" }
  $normalized = $normalized.Replace("`r", ' ').Replace("`n", ' ').Trim()
  if ($normalized.Length -gt 63) {
    $normalized = ($normalized.Substring(0, 60)) + '...'
  }
  try {
    $notify.Text = $normalized
  } catch {
    Log-Text "No se pudo setear tooltip del ícono tray: $($_.Exception.Message)"
  }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$menuStatus = New-Object System.Windows.Forms.ToolStripMenuItem 'Ver estado'
$menuRestart = New-Object System.Windows.Forms.ToolStripMenuItem 'Reiniciar puente'
$menuStop = New-Object System.Windows.Forms.ToolStripMenuItem 'Detener puente'
$menuStart = New-Object System.Windows.Forms.ToolStripMenuItem 'Iniciar puente'
$menuLogs = New-Object System.Windows.Forms.ToolStripMenuItem 'Abrir logs'
$menuToggleCapture = New-Object System.Windows.Forms.ToolStripMenuItem 'Ver último escaneo'
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Salir'

$menuStatus.Add_Click({
  Update-ConnectionStateFromLog
  [System.Windows.Forms.MessageBox]::Show((Get-StatusMessage), 'SessionHub Scanner Bridge', 'OK', 'Information') | Out-Null
})
$menuRestart.Add_Click({
  Invoke-RunnerAsync -Mode stop-task -TaskArg $BridgeTaskName
  Start-Sleep -Milliseconds 900
  Invoke-RunnerAsync -Mode start-task -TaskArg $BridgeTaskName
})
$menuStop.Add_Click({
  Invoke-RunnerAsync -Mode stop-task -TaskArg $BridgeTaskName
})
$menuStart.Add_Click({
  Invoke-RunnerAsync -Mode start-task -TaskArg $BridgeTaskName
})
$menuLogs.Add_Click({
  if (Test-Path $bridgeLog) {
    Start-Process notepad.exe -ArgumentList ('"' + $bridgeLog + '"') | Out-Null
  } else {
    [System.Windows.Forms.MessageBox]::Show("No existe log: $bridgeLog", 'SessionHub Scanner Bridge', 'OK', 'Warning') | Out-Null
  }
})
$menuToggleCapture.Add_Click({
  Update-ConnectionStateFromLog
  $lastScan = if ($state.LastScan) { $state.LastScan } else { '(sin escaneos)' }
  $lastType = if ($state.LastScanType) { $state.LastScanType } else { '-' }
  $lastStatus = if ($state.LastScanStatus) { $state.LastScanStatus } else { '-' }
  $lastError = if ($state.LastError) { $state.LastError } else { '-' }
  [System.Windows.Forms.MessageBox]::Show("Último escaneo:`n$lastScan`nTipo: $lastType`nEstado: $lastStatus`nError: $lastError", 'SessionHub Scanner Bridge', 'OK', 'Information') | Out-Null
})
$menuExit.Add_Click({
  $notify.Visible = $false
  $notify.Dispose()
  $iconConnected.Dispose()
  $iconDisconnected.Dispose()
  $iconScan.Dispose()
  $iconError.Dispose()
  [System.Windows.Forms.Application]::Exit()
})

$menu.Items.AddRange(@($menuStatus, $menuRestart, $menuStop, $menuStart, $menuLogs, $menuToggleCapture, $menuExit))
$notify.ContextMenuStrip = $menu

$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = 'Minimized'
$form.ShowIcon = $false
$form.FormBorderStyle = 'FixedToolWindow'
$form.StartPosition = 'Manual'
$form.Location = New-Object System.Drawing.Point(-10000, -10000)
$form.Add_Shown({ $form.Hide() })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(500, [int]$PollMs)

function Get-StatusMessage {
  $taskState = Refresh-TaskState -Force
  $errorLine = if ($state.LastError) { "`nError: $($state.LastError)" } else { '' }
  return @"
Estado tray del SessionHub Scanner Bridge

Host: $HostId
Task: $($state.BridgeTaskName)
TaskState: $($taskState.task)
Running: $($taskState.running_count)
Conexión: $([bool]$state.Connected)
Puerto: $($state.LastSerialPort)
Scanner: $($state.LastDevice)
Último scan: $($state.LastScan)
Tipo: $($state.LastScanType)
Ack: $($state.LastAck)
Estado: $($state.LastScanStatus)$errorLine
"@
}

$timer.Add_Tick({
  try {
    Update-ConnectionStateFromLog
    if ($state.RecentScan -and $state.LastScanTs -and ((Get-Date) - $state.LastScanTs).TotalMilliseconds -lt $RecentScanMs) {
      $notify.Icon = $iconScan
    } else {
      if (-not $state.Connected) {
        $notify.Icon = $iconDisconnected
      } elseif ($state.LastError) {
        $notify.Icon = $iconError
      } else {
        $notify.Icon = $iconConnected
      }
      $state.RecentScan = $false
    }

    Set-NotifyTooltipText (Build-StatusText)
    if ($state.LastError) {
      $notify.BalloonTipTitle = 'SessionHub Scanner Bridge'
      $notify.BalloonTipText = $state.LastError
      $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      $notify.ShowBalloonTip(2000)
      $state.LastError = ''
    }

  } catch {
    Set-NotifyTooltipText 'SessionHub Scanner Bridge (error de estado)'
    Log-Text "tray error: $($_.Exception.Message)"
  }
})

try {
  $timer.Start()
  Update-ConnectionStateFromLog -ForceTaskState
  $notify.Icon = $iconDisconnected
  Set-NotifyTooltipText (Build-StatusText)
  Log-Text 'Tray message loop starting.'

  [void][System.Windows.Forms.Application]::Run($form)
  Log-Text 'Tray message loop ended.'
} catch {
  Log-Text ("Tray fatal error: {0}" -f $_.Exception.Message)
  Log-Text $_.InvocationInfo.PositionMessage
  throw
} finally {
  $iconConnected.Dispose()
  $iconDisconnected.Dispose()
  $iconScan.Dispose()
  $iconError.Dispose()
}



