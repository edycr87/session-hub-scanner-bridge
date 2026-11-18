param(
  [string]$Root = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$TaskName = 'SessionHubScannerBridge',
  [string]$BridgeTaskName = 'SessionHubScannerBridge',
  [string]$HostId = '',
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
$updateStatusPath = Join-Path $root 'update-status.json'
$script:UpdateAlertShown = ''

$stateFilePath = Join-Path $root 'bridge-state.json'
$uiPath = Join-Path $root 'ui'
$script:DeclaredHostId = $HostId
$script:BridgeState = $null
$script:BridgeStateFresh = $false
$script:SeenChoiceNonce = $null
$script:SeenChoiceInitialized = $false
$script:SelectorSignature = ''
$script:SelectorOpen = $false
$script:ConflictShown = $false

# Same normalization as the agent: the station is its hostname unless a name was
# declared. The agent state file (bridge-state.json) is the source of truth once
# it exists; this only covers the first seconds.
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
if ([string]::IsNullOrWhiteSpace($HostId)) {
  $stationName = ''
  try { $stationName = [System.Net.Dns]::GetHostName() } catch { $stationName = '' }
  if ([string]::IsNullOrWhiteSpace($stationName)) { $stationName = [string]$env:COMPUTERNAME }
  $HostId = ConvertTo-StationId -Name $stationName
}

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
  ReaderStates = @{}
  BindingStatus = 'unknown'
  BindingTarget = '-'
  BindingOwner = '-'
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
  $command = @(
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
    '-Root',
    $root
  )
  if (-not [string]::IsNullOrWhiteSpace($script:DeclaredHostId)) {
    $command += @('-HostId', $script:DeclaredHostId)
  }
  return $command
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
    Where-Object { $_.CommandLine -match 'bridge\.js' -and ($_.CommandLine -match [regex]::Escape($HostId) -or $_.CommandLine.ToLowerInvariant().Contains($root.ToLowerInvariant())) } |
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

      if ($task.reader_id) {
        $readerKey = [string]$task.reader_id
        if (-not $state.ReaderStates.ContainsKey($readerKey)) { $state.ReaderStates[$readerKey] = [ordered]@{ State = 'unknown'; Port = '-'; Device = '-'; LastScan = ''; Error = '' } }
        $readerState = $state.ReaderStates[$readerKey]
        if ($task.port) { $readerState.Port = [string]$task.port }
        if ($task.serial_port) { $readerState.Port = [string]$task.serial_port }
        if ($task.scanner_device_id) { $readerState.Device = [string]$task.scanner_device_id }
        if ($task.status -eq 'serial.reader.open') { $readerState.State = 'open' }
        if ($task.status -eq 'serial.reader.closed') { $readerState.State = 'disconnected' }
        if ($task.status -eq 'serial.reader.failed' -or $task.status -eq 'serial.reader.error') { $readerState.State = 'error'; $readerState.Error = [string]$task.message }
        if ($task.status -eq 'scan.captured' -and $task.value) { $readerState.LastScan = [string]$task.value }
      }

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
          if ($task.scanner_state) {
            if ($task.scanner_state.target_type) { $state.BindingTarget = [string]$task.scanner_state.target_type }
            if ($task.scanner_state.owner_mobile_session_id) { $state.BindingOwner = [string]$task.scanner_state.owner_mobile_session_id }
          }
          if ($task.status -eq 'binding.bound') {
            $state.BindingStatus = 'bound'
            $state.LastScanStatus = 'bound'
          }
          if ($task.status -eq 'binding.updated') {
            $state.BindingStatus = 'updated'
          }
          if ($task.status -eq 'binding.released') {
            $state.BindingStatus = 'released'
            $state.BindingOwner = '-'
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

# ---------------------------------------------------------------------------
# Agent state (bridge-state.json, no secrets, readable by every user) and the
# reader selector. The icon NEVER writes the configuration: a choice is a small
# request in the ui folder, which the agent validates and applies. If that
# folder is not writable the icon offers an explicit elevated retry.
# ---------------------------------------------------------------------------
function Read-BridgeStateFile {
  $script:BridgeState = $null
  $script:BridgeStateFresh = $false
  if (-not (Test-Path -LiteralPath $stateFilePath)) { return }
  try {
    $parsed = [System.IO.File]::ReadAllText($stateFilePath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $updated = [datetime]::Parse([string]$parsed.updated_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $script:BridgeState = $parsed
    $script:BridgeStateFresh = (((Get-Date).ToUniversalTime() - $updated).TotalSeconds -lt 20)
    if ($parsed.host_id) { $script:HostId = [string]$parsed.host_id; $state.HostId = $script:HostId }
  } catch {
    Log-Text "No se pudo leer bridge-state.json: $($_.Exception.Message)"
  }
}

function Get-ReaderLabel([string]$Code) {
  switch ($Code) {
    'waiting' { return 'esperando' }
    'open' { return 'abierto' }
    'failed' { return 'fallo' }
    'disconnected' { return 'desconectado' }
    'ambiguous' { return 'AMBIGUO' }
    'pending' { return 'iniciando' }
    default { return 'sin datos' }
  }
}

function Get-ReaderSummary {
  $summary = [PSCustomObject]@{ State = 'unknown'; Port = '-'; UsbId = '-'; Candidates = @(); HostState = 'ok' }
  if (-not $script:BridgeState -or -not $script:BridgeStateFresh) { return $summary }
  if ($script:BridgeState.host_state) { $summary.HostState = [string]$script:BridgeState.host_state }
  $reader = @($script:BridgeState.readers)[0]
  if (-not $reader) { return $summary }
  $summary.State = [string]$reader.state
  if ($reader.serial_port) { $summary.Port = [string]$reader.serial_port }
  if ($reader.vendor_id -and $reader.product_id) { $summary.UsbId = ('{0}:{1}' -f $reader.vendor_id, $reader.product_id) }
  if ($reader.candidates) { $summary.Candidates = @($reader.candidates) }
  return $summary
}

function Get-ChoiceMessage([string]$Code) {
  switch ($Code) {
    'CHOICE_NOT_A_CANDIDATE' { return 'El dispositivo elegido ya no esta conectado. Abri "Elegir lector" de nuevo.' }
    'CHOICE_NOT_IDENTIFIABLE' { return 'Hay dos dispositivos iguales sin numero de serie: no se pueden distinguir. Desenchufa el que no se use.' }
    default { return 'La solicitud no era valida.' }
  }
}

function Send-TrayReaderChoice {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('select', 'forget')][string]$Action,
    $Candidate
  )

  $nonce = [guid]::NewGuid().ToString('N')
  $request = [ordered]@{
    schema = 'session-hub-scanner-reader-choice/v1'
    action = $Action
    nonce = $nonce
    requested_at = (Get-Date).ToString('o')
  }
  $usbId = ''
  if ($Action -eq 'select') {
    $serial = if ($Candidate.serial_number) { [string]$Candidate.serial_number } else { $null }
    $request['device'] = [ordered]@{
      vendor_id = [string]$Candidate.vendor_id
      product_id = [string]$Candidate.product_id
      serial_number = $serial
    }
    $usbId = ('{0}:{1}' -f $Candidate.vendor_id, $Candidate.product_id)
    if ($serial) { $usbId += '/' + $serial }
  }

  try {
    if (-not (Test-Path -LiteralPath $uiPath)) {
      throw (New-Object System.IO.DirectoryNotFoundException('Falta la carpeta ui del agente'))
    }
    $final = Join-Path $uiPath 'reader-choice.request.json'
    $temporary = $final + '.' + $nonce.Substring(0, 8) + '.tmp'
    [System.IO.File]::WriteAllText($temporary, ($request | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $final -Force
    $notify.BalloonTipTitle = 'SessionHub Scanner Bridge'
    $notify.BalloonTipText = 'Solicitud enviada al agente; en unos segundos se aplica.'
    $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $notify.ShowBalloonTip(2500)
    Log-Text "Solicitud de lector enviada: $Action"
  } catch {
    Log-Text "No se pudo escribir la solicitud de lector: $($_.Exception.Message)"
    $answer = [System.Windows.Forms.MessageBox]::Show(
      "No se pudo enviar la eleccion del lector (permisos de la carpeta ui).`n`nSe puede repetir con permisos de administrador (aparece el aviso de Windows).`nSi no, un administrador puede fijarlo a mano con:`nrun-session-hub-bridge.ps1 -Mode choose-reader -ReaderUsbId $usbId`n`n¿Repetir como administrador ahora?",
      'SessionHub Scanner Bridge', 'YesNo', 'Warning')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
      $mode = if ($Action -eq 'select') { 'choose-reader' } else { 'forget-reader' }
      $elevated = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runnerScript + '"'), '-Mode', $mode, '-Root', ('"' + $root + '"'))
      if ($usbId) { $elevated += @('-ReaderUsbId', $usbId) }
      try {
        Start-Process -FilePath (Resolve-PowerShellExecutable) -Verb RunAs -WindowStyle Hidden -ArgumentList $elevated | Out-Null
      } catch {
        Log-Text "Elevacion cancelada o fallida: $($_.Exception.Message)"
      }
    }
  }
}

function Show-ReaderSelector {
  if ($script:SelectorOpen) { return }
  $summary = Get-ReaderSummary
  $candidates = @($summary.Candidates)
  if ($candidates.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show('No hay lectores USB conectados. Si el lector esta en modo teclado, escanea el codigo de configuracion que lo pasa a puerto serie (USB-VCOM).', 'SessionHub Scanner Bridge', 'OK', 'Information') | Out-Null
    return
  }
  $script:SelectorOpen = $true
  try {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Elegir lector'
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.TopMost = $true
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 260)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Hay mas de un dispositivo USB. Elegi cual es el lector de codigos (el puerto COM se muestra solo como referencia):'
    $label.Location = New-Object System.Drawing.Point(12, 10)
    $label.Size = New-Object System.Drawing.Size(496, 44)
    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 60)
    $list.Size = New-Object System.Drawing.Size(496, 150)
    foreach ($candidate in $candidates) {
      $serialText = if ($candidate.serial_number) { $candidate.serial_number } else { 'sin numero de serie' }
      $descText = if ($candidate.description) { $candidate.description } else { 'dispositivo serie USB' }
      [void]$list.Items.Add(('{0}:{1} | {2} | {3} | puerto actual {4}' -f $candidate.vendor_id, $candidate.product_id, $serialText, $descText, $candidate.port))
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Elegir'
    $ok.Location = New-Object System.Drawing.Point(342, 222)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'
    $cancel.Location = New-Object System.Drawing.Point(428, 222)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    $dialog.Controls.AddRange(@($label, $list, $ok, $cancel))
    $result = $dialog.ShowDialog()
    $index = $list.SelectedIndex
    $dialog.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $index -ge 0) {
      Send-TrayReaderChoice -Action 'select' -Candidate $candidates[$index]
    }
  } finally {
    $script:SelectorOpen = $false
  }
}

# Visible reactions to the agent state: the choice dialog pops up once for each
# distinct set of candidates (the menu stays available), a name conflict is
# announced once, and the result of a choice is reported.
function Update-ReaderAlerts {
  $summary = Get-ReaderSummary
  if ($summary.HostState -eq 'host_conflict' -and -not $script:ConflictShown) {
    $script:ConflictShown = $true
    $notify.BalloonTipTitle = 'SessionHub Scanner Bridge'
    $notify.BalloonTipText = "Conflicto de nombre: otra instalacion usa el puesto $HostId. Resolve el nombre duplicado y reinicia el agente."
    $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
    $notify.ShowBalloonTip(6000)
  }
  if ($summary.State -eq 'ambiguous' -and $summary.HostState -eq 'ok') {
    $signature = (($summary.Candidates | ForEach-Object { '{0}:{1}/{2}' -f $_.vendor_id, $_.product_id, $_.serial_number }) -join ',')
    if ($signature -ne $script:SelectorSignature) {
      $script:SelectorSignature = $signature
      Show-ReaderSelector
    }
  } elseif ($summary.State -ne 'ambiguous') {
    $script:SelectorSignature = ''
  }
  if ($script:BridgeStateFresh -and $script:BridgeState) {
    $choice = $script:BridgeState.reader_choice
    $nonce = if ($choice -and $choice.nonce) { [string]$choice.nonce } else { '' }
    if (-not $script:SeenChoiceInitialized) {
      $script:SeenChoiceInitialized = $true
      $script:SeenChoiceNonce = $nonce
    } elseif ($choice -and $nonce -ne $script:SeenChoiceNonce) {
      $script:SeenChoiceNonce = $nonce
      $notify.BalloonTipTitle = 'SessionHub Scanner Bridge'
      if ([string]$choice.result -eq 'applied') {
        $notify.BalloonTipText = 'Lector elegido: listo.'
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
      } else {
        $notify.BalloonTipText = (Get-ChoiceMessage -Code ([string]$choice.code))
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      }
      $notify.ShowBalloonTip(5000)
    }
  }
}

# OTA: secret-free status written by the updater. Deferred installs/rollbacks
# and the deferral alert are shown; nothing here changes the bridge.
function Get-UpdateStatusLine {
  if (-not (Test-Path -LiteralPath $updateStatusPath)) { return '' }
  try {
    $status = [System.IO.File]::ReadAllText($updateStatusPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
  } catch {
    return ''
  }
  $phase = [string]$status.phase
  if (@('install_deferred', 'rollback_deferred', 'install_blocked') -notcontains $phase) { return '' }
  $label = if ($phase -eq 'rollback_deferred') { 'Reversion pendiente' } elseif ($phase -eq 'install_blocked') { 'Actualizacion bloqueada por diagnostico' } else { 'Actualizacion pendiente' }
  $line = "$label $($status.target_version) (esperando cola; intentos=$($status.defer_count))"
  if ([bool]$status.alert) { $line = "ALERTA: $line" }
  return $line
}

function Build-StatusText {
  $conn = if ($state.Connected) { 'Conectado' } else { 'Desconectado' }
  # The tooltip is cut at 63 chars: a pending update goes first, short form.
  $updateLine = Get-UpdateStatusLine
  if ($updateLine) {
    $short = if ($updateLine.StartsWith('ALERTA')) { 'ALERTA upd' } else { 'Upd pendiente' }
    return "$short | $conn | $HostId"
  }
  $summary = Get-ReaderSummary
  if ($summary.HostState -eq 'host_conflict') {
    return "CONFLICTO de nombre: $HostId"
  }
  if ($summary.HostState -eq 'superseded') {
    return "Reemplazado por otra conexion: $HostId"
  }
  if ($summary.State -eq 'ambiguous') {
    return "$HostId | hay mas de un lector: elegir"
  }
  $label = Get-ReaderLabel -Code $summary.State
  $port = if ($summary.State -eq 'open' -and $summary.Port -ne '-') { " $($summary.Port)" } else { '' }
  return "$HostId | lector: $label$port"
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
  $notify.BalloonTipText = "Puesto $HostId"
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
$menuChooseReader = New-Object System.Windows.Forms.ToolStripMenuItem 'Elegir lector...'
$menuForgetReader = New-Object System.Windows.Forms.ToolStripMenuItem 'Olvidar lector recordado'
$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem 'Salir'

$menuStatus.Add_Click({
  Update-ConnectionStateFromLog
  [System.Windows.Forms.MessageBox]::Show((Get-StatusMessage), 'SessionHub Scanner Bridge', 'OK', 'Information') | Out-Null
})
$menuChooseReader.Add_Click({
  Read-BridgeStateFile
  Show-ReaderSelector
})
$menuForgetReader.Add_Click({
  $answer = [System.Windows.Forms.MessageBox]::Show('Se olvida el lector recordado: el agente vuelve a detectar solo (si hay uno, lo toma; si hay mas de uno, pregunta). ¿Seguir?', 'SessionHub Scanner Bridge', 'YesNo', 'Question')
  if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Send-TrayReaderChoice -Action 'forget' }
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

$menu.Items.AddRange(@($menuStatus, $menuChooseReader, $menuForgetReader, $menuRestart, $menuStop, $menuStart, $menuLogs, $menuToggleCapture, $menuExit))
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
  Read-BridgeStateFile
  $summary = Get-ReaderSummary
  $errorLine = if ($state.LastError) { "`nError: $($state.LastError)" } else { '' }
  $readerLines = if ($state.ReaderStates.Count -gt 0) { ($state.ReaderStates.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key): $($_.Value.State) | $($_.Value.Port) | $($_.Value.Device) | ult=$($_.Value.LastScan)" }) -join "`n" } else { '(sin lectores seriales observados)' }
  $hostLine = switch ($summary.HostState) {
    'host_conflict' { 'CONFLICTO DE NOMBRE: otra instalacion usa este puesto; el agente no reintenta. Resolve el nombre duplicado y reinicia el agente.' }
    'superseded' { 'Reemplazado: la misma instalacion abrio otra conexion; este proceso no reconecta.' }
    default { 'normal' }
  }
  $candidateLines = if (@($summary.Candidates).Count -gt 0) { (@($summary.Candidates) | ForEach-Object { "  {0}:{1} serie={2} (puerto actual {3})" -f $_.vendor_id, $_.product_id, $(if ($_.serial_number) { $_.serial_number } else { '-' }), $_.port }) -join "`n" } else { '  (ninguno)' }
  return @"
Estado tray del SessionHub Scanner Bridge

Puesto: $HostId
Estado del puesto: $hostLine
Lector: $(Get-ReaderLabel -Code $summary.State) | Puerto activo (referencia): $($summary.Port) | USB: $($summary.UsbId)
Candidatos USB:
$candidateLines
Task: $($state.BridgeTaskName)
TaskState: $($taskState.task)
Running: $($taskState.running_count)
Conexión: $([bool]$state.Connected)
Scanner: $($state.LastDevice)
Lectores (log):
$readerLines
Binding: $($state.BindingStatus) | Target: $($state.BindingTarget) | Owner: $($state.BindingOwner)
Último scan: $($state.LastScan)
Tipo: $($state.LastScanType)
Ack: $($state.LastAck)
Estado: $($state.LastScanStatus)$errorLine
Actualizacion: $(Get-UpdateStatusLine)
"@
}

$timer.Add_Tick({
  try {
    Update-ConnectionStateFromLog
    Read-BridgeStateFile
    $readerSummary = Get-ReaderSummary
    if ($state.RecentScan -and $state.LastScanTs -and ((Get-Date) - $state.LastScanTs).TotalMilliseconds -lt $RecentScanMs) {
      $notify.Icon = $iconScan
    } else {
      if ($readerSummary.HostState -ne 'ok') {
        $notify.Icon = $iconError
      } elseif (-not $state.Connected) {
        $notify.Icon = $iconDisconnected
      } elseif ($state.LastError -or $readerSummary.State -eq 'failed') {
        $notify.Icon = $iconError
      } elseif (@('waiting', 'ambiguous', 'disconnected') -contains $readerSummary.State) {
        $notify.Icon = $iconScan
      } else {
        $notify.Icon = $iconConnected
      }
      $state.RecentScan = $false
    }
    Update-ReaderAlerts

    Set-NotifyTooltipText (Build-StatusText)
    $updateLine = Get-UpdateStatusLine
    if ($updateLine -and $updateLine.StartsWith('ALERTA') -and $script:UpdateAlertShown -ne $updateLine) {
      $notify.BalloonTipTitle = 'SessionHub Scanner Bridge'
      $notify.BalloonTipText = $updateLine
      $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      $notify.ShowBalloonTip(4000)
      $script:UpdateAlertShown = $updateLine
    }
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
  Read-BridgeStateFile
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



