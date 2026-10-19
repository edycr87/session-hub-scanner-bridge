param(
  [ValidateSet('report','install','ota')]
  [string]$Context = 'report',
  [string]$TargetInstallRoot = "$env:ProgramData\SessionHubScannerBridge",
  [string[]]$ExtraRoots = @(),
  [string]$PlannedPath = '',
  [string]$AcknowledgeDrop = '',
  [string]$OutputPath = '',
  [string]$FactsOnlyPath = ''
)

# READ-ONLY diagnostic of the Session Hub Scanner client installed on this PC.
# It never writes outside -OutputPath/-FactsOnlyPath, never stops, starts or
# changes tasks/processes/files, and never emits secret values: secret-named
# settings are reported as presence only (no value, no hash). Values are
# emitted only for an allowlist of non-secret keys; URLs lose credentials and
# query values.

$ErrorActionPreference = 'Stop'

# Must match SECRET_NAME_RE in diagnose-session-hub-scanner.js.
$SecretNamePattern = '(secret|token|password|passwd|pwd|api[_-]?key|auth|credential|private)'
$ValueAllowKeys = @(
  'version', 'updated_at', 'host_id', 'display_name', 'base_url', 'serial_port',
  'reader_device_id', 'symbology', 'serial_fallback', 'serial_interactive',
  'install_root', 'input_mode', 'heartbeat_ms', 'serial_baud_rate', 'serial_wait_ms',
  'task_name', 'tray_task_name', 'updater_task_name', 'update_manifest_url',
  'update_channel', 'update_interval_minutes', 'install_tray', 'install_updater',
  'update_window', 'update_quiet_seconds'
)
$ReaderAllowKeys = @('reader_id', 'readerId', 'serial_port', 'serialPort', 'scanner_device_id', 'scannerDeviceId', 'device_id', 'serial_baud_rate', 'serialBaudRate', 'serial_wait_ms', 'serialWaitMs')
$EnvValueAllow = @(
  'SESSION_HUB_BASE_URL', 'SESSION_HUB_SCANNER_HOST_ID', 'SESSION_HUB_SCANNER_DISPLAY_NAME',
  'SESSION_HUB_SCANNER_INPUT_MODE', 'SESSION_HUB_SCANNER_SERIAL_PORT', 'SESSION_HUB_SCANNER_SERIAL_BAUD_RATE',
  'SESSION_HUB_SCANNER_SERIAL_WAIT_MS', 'SESSION_HUB_SCANNER_DEVICE_ID', 'SESSION_HUB_SCANNER_READER_ID',
  'SESSION_HUB_SCANNER_HEARTBEAT_MS', 'SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY',
  'SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN', 'SESSION_HUB_SCANNER_SERIAL_INTERACTIVE',
  'SESSION_HUB_SCANNER_ACK_TIMEOUT_MS', 'SESSION_HUB_SCANNER_MAX_PENDING_SCANS'
)
$TextExtensions = @('.js', '.ps1', '.json', '.md', '.txt', '.vbs', '.cmd')

function Get-TextSha256 {
  param([byte[]]$Bytes)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-FileFacts {
  param([System.IO.FileInfo]$File)
  $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
  $facts = [ordered]@{
    name = $File.Name
    size = $File.Length
    modified_utc = $File.LastWriteTimeUtc.ToString('o')
    sha256 = Get-TextSha256 -Bytes $bytes
  }
  if ($TextExtensions -contains $File.Extension.ToLowerInvariant()) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF).Replace("`r`n", "`n")
    $facts.sha256_lf = Get-TextSha256 -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
  }
  return $facts
}

function Get-SafeUrl {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
  try {
    $uri = [Uri]$Value
    if (-not $uri.IsAbsoluteUri) { return $Value }
    $query = ''
    if ($uri.Query.Length -gt 1) {
      $names = @($uri.Query.TrimStart('?').Split('&') | ForEach-Object { ($_ -split '=', 2)[0] + '=<redacted>' })
      $query = '?' + ($names -join '&')
    }
    return ('{0}://{1}{2}{3}' -f $uri.Scheme, $uri.Authority.Split('@')[-1], $uri.AbsolutePath, $query)
  } catch {
    return '<unparseable-url-redacted>'
  }
}

# Windows user names are not needed by Root: profile paths and principals are masked.
function Hide-UserName {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  return [regex]::Replace($Text, '(?i)([A-Za-z]:\\Users\\)[^\\"\s]+', '$1<user>')
}

function Get-SafePrincipal {
  param([string]$UserId)
  if ([string]::IsNullOrWhiteSpace($UserId)) { return $UserId }
  if ($UserId -match '(?i)^(NT AUTHORITY\\|SYSTEM$|S-1-5-18$|LOCAL SERVICE|NETWORK SERVICE|BUILTIN\\)') { return $UserId }
  return '<interactive-user>'
}

function Get-RedactedText {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return @{ text = $Text; secret_present = $false } }
  $secret = $false
  $flagPattern = '(?i)((?:--?|/)[\w-]*(?:secret|token|password|passwd|api[_-]?key)[\w-]*)(\s+|=|:)("[^"]*"|''[^'']*''|\S+)'
  if ([regex]::IsMatch($Text, $flagPattern)) { $secret = $true }
  $out = [regex]::Replace($Text, $flagPattern, '$1$2<redacted>')
  $out = [regex]::Replace($out, '(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@', '$1<redacted>@')
  $out = [regex]::Replace($out, '(?i)(SESSION_HUB_SCANNER(?:_BRIDGE)?_SHARED_SECRET\s*=\s*)("[^"]*"|\S+)', '$1<redacted>')
  $out = Hide-UserName $out
  return @{ text = $out; secret_present = $secret }
}

function Get-KeyFacts {
  param([string]$Name, $Value)
  $present = -not ($null -eq $Value -or ([string]$Value).Trim() -eq '')
  if ($Name -match $SecretNamePattern) {
    return [ordered]@{ name = $Name; kind = 'secret'; present = $present }
  }
  if ($ValueAllowKeys -contains $Name) {
    $text = [string]$Value
    if ($Name -like '*url*') { $text = Get-SafeUrl $text }
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    return [ordered]@{ name = $Name; kind = 'value'; present = $present; value = $text }
  }
  $type = if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
  $length = if ($null -eq $Value) { 0 } else { ([string]$Value).Length }
  return [ordered]@{ name = $Name; kind = 'redacted'; present = $present; value_type = $type; length = $length }
}

function Get-ReaderFacts {
  param([string]$ReadersJson)
  $result = [ordered]@{ readers_present = -not [string]::IsNullOrWhiteSpace($ReadersJson); readers_parse_ok = $true; readers = @(); reader_extra_keys = @() }
  if (-not $result.readers_present) { return $result }
  try {
    $parsed = @($ReadersJson | ConvertFrom-Json)
    $extra = @()
    $readers = @()
    foreach ($item in $parsed) {
      $reader = [ordered]@{}
      foreach ($property in $item.PSObject.Properties) {
        if ($ReaderAllowKeys -contains $property.Name -and -not ($property.Name -match $SecretNamePattern)) {
          $reader[$property.Name] = [string]$property.Value
        } else {
          $extra += $property.Name
        }
      }
      $readers += [ordered]@{
        reader_id = if ($reader.reader_id) { $reader.reader_id } else { $reader.readerId }
        serial_port = if ($reader.serial_port) { $reader.serial_port } else { $reader.serialPort }
        scanner_device_id = if ($reader.scanner_device_id) { $reader.scanner_device_id } elseif ($reader.scannerDeviceId) { $reader.scannerDeviceId } else { $reader.device_id }
        serial_baud_rate = if ($reader.serial_baud_rate) { $reader.serial_baud_rate } else { $reader.serialBaudRate }
      }
    }
    $result.readers = $readers
    $result.reader_extra_keys = @($extra | Select-Object -Unique)
  } catch {
    $result.readers_parse_ok = $false
  }
  return $result
}

function Get-RootFacts {
  param([string]$Path, [string[]]$Sources)
  $root = [ordered]@{ path = (Hide-UserName $Path); sources = $Sources; exists = (Test-Path -LiteralPath $Path -PathType Container) }
  if (-not $root.exists) { return $root }
  $versions = [ordered]@{}
  foreach ($name in @('installed-version.txt', 'package-version.txt')) {
    $file = Join-Path $Path $name
    if (Test-Path -LiteralPath $file) { $versions[$name] = ([System.IO.File]::ReadAllText($file)).TrimStart([char]0xFEFF).Trim() }
  }
  $packageJson = Join-Path $Path 'package.json'
  if (Test-Path -LiteralPath $packageJson) {
    try { $versions['package.json'] = [string](([System.IO.File]::ReadAllText($packageJson)).TrimStart([char]0xFEFF) | ConvertFrom-Json).version } catch { $versions['package.json'] = '<unreadable>' }
  }
  $root.versions = $versions

  $files = @()
  $logs = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
    if ($file.Name -eq 'scanner-bridge-config.json') { continue }
    if ($file.Name -match $SecretNamePattern -or $file.Name -match '(?i)^\.env|\.env$|\.pem$|\.key$|\.pfx$') {
      # Possible secret material: presence and size only, never content or hash.
      $files += [ordered]@{ name = $file.Name; size = $file.Length; modified_utc = $file.LastWriteTimeUtc.ToString('o'); content = 'not-read' }
      continue
    }
    if ($file.Extension -in @('.log', '.err')) {
      $logs += [ordered]@{ name = $file.Name; size = $file.Length; modified_utc = $file.LastWriteTimeUtc.ToString('o') }
      continue
    }
    $files += Get-FileFacts -File $file
  }
  $root.files = $files
  $root.logs = $logs
  $root.directories = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

  $nodeModules = Join-Path $Path 'node_modules'
  if (Test-Path -LiteralPath $nodeModules) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $nodeModules -File -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
      $relative = $file.FullName.Substring($nodeModules.Length).Replace('\', '/')
      $lines.Add($relative + ':' + (Get-TextSha256 -Bytes ([System.IO.File]::ReadAllBytes($file.FullName))))
    }
    $root.node_modules = [ordered]@{
      present = $true
      file_count = $lines.Count
      aggregate_sha256 = Get-TextSha256 -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join "`n")))
    }
  } else {
    $root.node_modules = [ordered]@{ present = $false }
  }

  # The config holds secrets: it is parsed in memory and only redacted facts leave.
  $configPath = Join-Path $Path 'scanner-bridge-config.json'
  $config = [ordered]@{ present = (Test-Path -LiteralPath $configPath); parse_ok = $false; keys = @() }
  if ($config.present) {
    $configFile = Get-Item -LiteralPath $configPath
    $config.size = $configFile.Length
    $config.modified_utc = $configFile.LastWriteTimeUtc.ToString('o')
    try {
      $stored = ([System.IO.File]::ReadAllText($configPath)).TrimStart([char]0xFEFF) | ConvertFrom-Json
      $config.parse_ok = $true
      $keys = @()
      foreach ($property in $stored.PSObject.Properties) {
        $keys += Get-KeyFacts -Name $property.Name -Value $property.Value
      }
      $config.keys = $keys
      $readerFacts = Get-ReaderFacts -ReadersJson ([string]$stored.readers_json)
      foreach ($key in $readerFacts.Keys) { $config[$key] = $readerFacts[$key] }
    } catch {
      $config.parse_ok = $false
    }
  }
  $root.config = $config

  $journal = Join-Path (Join-Path $Path '.ota') 'journal.json'
  $root.ota = [ordered]@{ journal_present = (Test-Path -LiteralPath $journal) }
  if ($root.ota.journal_present) {
    try { $root.ota.journal_phase = [string](([System.IO.File]::ReadAllText($journal)).TrimStart([char]0xFEFF) | ConvertFrom-Json).phase } catch { $root.ota.journal_phase = '<unreadable>' }
  }
  return $root
}

function Get-RootHint {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $match = [regex]::Match($Text, '(?i)-Root\s+"([^"]+)"|-Root\s+(\S+)|-InstallRoot\s+"([^"]+)"|-InstallRoot\s+(\S+)')
  if ($match.Success) {
    foreach ($index in 1..4) { if ($match.Groups[$index].Success) { return $match.Groups[$index].Value.TrimEnd('\') } }
  }
  $script = [regex]::Match($Text, '(?i)"?([A-Za-z]:\\[^"]*?)\\(?:bridge\.js|run-session-hub-bridge\.ps1|update-session-hub-scanner\.ps1|tray-session-hub-bridge\.ps1|session-hub-scanner-bridge\.exe)')
  if ($script.Success) { return $script.Groups[1].Value }
  return $null
}

$facts = [ordered]@{
  schema = 'session-hub-scanner-diagnostic/v1'
  collected_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  context = $Context
  target_install_root = (Hide-UserName $TargetInstallRoot)
  computer = [ordered]@{
    os_version = [Environment]::OSVersion.VersionString
    ps_version = $PSVersionTable.PSVersion.ToString()
    is_admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
}

$rootSources = @{}
function Add-RootCandidate {
  param([string]$Path, [string]$Source)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $key = $Path.TrimEnd('\')
  if (-not $rootSources.ContainsKey($key)) { $rootSources[$key] = @() }
  if ($rootSources[$key] -notcontains $Source) { $rootSources[$key] += $Source }
}
Add-RootCandidate -Path $TargetInstallRoot -Source 'target'
# Discover dormant instances too: a missing task/process is not permission to overwrite.
foreach ($instance in @('SessionHubScannerBridge', 'SessionHubScannerBridge_Caja2', 'SessionHubScannerBridge_Caja3')) {
  Add-RootCandidate -Path (Join-Path $env:ProgramData $instance) -Source 'known-instance-root'
}
Add-RootCandidate -Path 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge' -Source 'legacy-default'
Add-RootCandidate -Path 'C:\gestor_produccion\tools\session-hub-scanner-bridge' -Source 'legacy-default'
foreach ($extra in $ExtraRoots) { Add-RootCandidate -Path $extra -Source 'extra' }

$tasks = @()
foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'SessionHubScanner*' -or (@($_.Actions | ForEach-Object { [string]$_.Arguments + ' ' + [string]$_.Execute }) -join ' ') -match '(?i)session-hub|bridge\.js' })) {
  $info = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
  $action = @($task.Actions)[0]
  $redacted = Get-RedactedText -Text ([string]$action.Arguments)
  $hint = Get-RootHint -Text ([string]$action.Arguments)
  if ($hint) { Add-RootCandidate -Path $hint -Source ('task:' + $task.TaskName) }
  $tasks += [ordered]@{
    name = $task.TaskName
    path = $task.TaskPath
    state = [string]$task.State
    principal = Get-SafePrincipal ([string]$task.Principal.UserId)
    triggers = @($task.Triggers | ForEach-Object { $_.CimClass.CimClassName })
    last_run_utc = if ($info -and $info.LastRunTime) { $info.LastRunTime.ToUniversalTime().ToString('o') } else { $null }
    last_result = if ($info) { $info.LastTaskResult } else { $null }
    action_execute = [string]$action.Execute
    action_arguments_redacted = $redacted.text
    secret_present = $redacted.secret_present
    root_hint = (Hide-UserName $hint)
  }
}
$facts.tasks = $tasks

$processes = @()
foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match '(?i)(?:^|[\s"\\/])(?:bridge\.js|session-hub-scanner-bridge\.exe|run-session-hub-bridge\.ps1|tray-session-hub-bridge\.ps1)(?:[\s"]|$)' })) {
  $redacted = Get-RedactedText -Text ([string]$proc.CommandLine)
  $hint = Get-RootHint -Text ([string]$proc.CommandLine)
  if ($hint) { Add-RootCandidate -Path $hint -Source ('process:' + $proc.ProcessId) }
  $processes += [ordered]@{ pid = $proc.ProcessId; name = $proc.Name; command_line_redacted = $redacted.text; secret_present = $redacted.secret_present; root_hint = (Hide-UserName $hint) }
}
$facts.processes = $processes

$launchers = @()
$startupDirs = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
foreach ($profileStartup in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' })) { $startupDirs += $profileStartup }
foreach ($dir in @($startupDirs | Where-Object { $_ } | Select-Object -Unique)) {
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter 'SessionHubScanner*' -ErrorAction SilentlyContinue)) {
    $redacted = Get-RedactedText -Text ([System.IO.File]::ReadAllText($file.FullName))
    $hint = Get-RootHint -Text $redacted.text
    if ($hint) { Add-RootCandidate -Path $hint -Source 'startup' }
    $launchers += [ordered]@{ path = (Hide-UserName $file.FullName); content_redacted = $redacted.text; secret_present = $redacted.secret_present; root_hint = (Hide-UserName $hint) }
  }
}
$facts.startup_launchers = $launchers

$envFacts = @()
foreach ($scope in @('Machine', 'User')) {
  $vars = [Environment]::GetEnvironmentVariables($scope)
  foreach ($name in @($vars.Keys | Where-Object { $_ -like 'SESSION_HUB*' } | Sort-Object)) {
    $value = [string]$vars[$name]
    $entry = $null
    if ($name -match $SecretNamePattern) {
      $entry = [ordered]@{ scope = $scope; name = $name; kind = 'secret'; present = ($value.Trim() -ne '') }
    } elseif ($EnvValueAllow -contains $name) {
      $shown = if ($name -like '*URL*') { Get-SafeUrl $value } else { $value }
      $entry = [ordered]@{ scope = $scope; name = $name; kind = 'value'; present = ($value.Trim() -ne ''); value = $shown }
    } elseif ($name -eq 'SESSION_HUB_SCANNER_READERS') {
      $readerFacts = Get-ReaderFacts -ReadersJson $value
      $entry = [ordered]@{ scope = $scope; name = $name; kind = 'readers'; present = $readerFacts.readers_present; readers = $readerFacts.readers; readers_parse_ok = $readerFacts.readers_parse_ok }
    } else {
      $entry = [ordered]@{ scope = $scope; name = $name; kind = 'redacted'; present = ($value.Trim() -ne ''); length = $value.Length }
    }
    $envFacts += $entry
  }
}
$facts.env = $envFacts

$ports = @()
foreach ($port in @(Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue)) {
  $ports += [ordered]@{ device_id = [string]$port.DeviceID; name = [string]$port.Name; pnp_device_id = [string]$port.PNPDeviceID; is_bluetooth = ([string]$port.PNPDeviceID -match 'BTHENUM' -or [string]$port.Name -match 'Bluetooth') }
}
foreach ($pnp in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\(COM\d+\)' })) {
  $com = [regex]::Match([string]$pnp.Name, '\((COM\d+)\)').Groups[1].Value
  if (-not ($ports | Where-Object { $_.device_id -eq $com })) {
    $ports += [ordered]@{ device_id = $com; name = [string]$pnp.Name; pnp_device_id = [string]$pnp.PNPDeviceID; is_bluetooth = ([string]$pnp.PNPDeviceID -match 'BTHENUM') }
  }
}
$facts.serial_ports = $ports

$roots = @()
foreach ($key in @($rootSources.Keys | Sort-Object)) {
  $roots += Get-RootFacts -Path $key -Sources $rootSources[$key]
}
$facts.roots = $roots

$factsJson = $facts | ConvertTo-Json -Depth 10
$utf8 = New-Object System.Text.UTF8Encoding($false)
$factsFile = if ($FactsOnlyPath) { $FactsOnlyPath } else { Join-Path ([System.IO.Path]::GetTempPath()) ('session-hub-diagnostic-' + [guid]::NewGuid().ToString('N') + '.json') }
[System.IO.File]::WriteAllText($factsFile, $factsJson, $utf8)

# Evaluate with the bundled node.exe (shipped in every package next to this script).
$node = Join-Path $PSScriptRoot 'node.exe'
if (-not (Test-Path -LiteralPath $node)) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
$evaluator = Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.js'
$evaluation = $null
$exitCode = 1
if ($node -and (Test-Path -LiteralPath $evaluator)) {
  $evalArgs = @($evaluator, '--facts', $factsFile, '--context', $Context)
  if ($PlannedPath) { $evalArgs += @('--planned', $PlannedPath) }
  if ($AcknowledgeDrop) { $evalArgs += @('--acknowledge-drop', $AcknowledgeDrop) }
  $evalOutput = & $node @evalArgs
  $exitCode = $LASTEXITCODE
  try { $evaluation = ($evalOutput -join "`n") | ConvertFrom-Json } catch { $evaluation = $null }
} else {
  Write-Host 'No se encontro node.exe o el evaluador; solo se recolectaron datos.'
}

if ($OutputPath) {
  $report = [ordered]@{ facts = ($factsJson | ConvertFrom-Json); evaluation = $evaluation }
  [System.IO.File]::WriteAllText($OutputPath, ($report | ConvertTo-Json -Depth 12), $utf8)
}
if (-not $FactsOnlyPath -and (Test-Path -LiteralPath $factsFile)) { Remove-Item -LiteralPath $factsFile -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '=== Diagnostico Session Hub Scanner (solo lectura) ==='
Write-Host ("Carpeta objetivo: {0}" -f $TargetInstallRoot)
foreach ($root in $roots) {
  $version = if ($root.versions) { (@($root.versions.Values) -join ' / ') } else { '-' }
  Write-Host ("Instalacion: {0} existe={1} version={2}" -f $root.path, $root.exists, $version)
}
Write-Host ("Tareas programadas: {0} | Procesos bridge: {1} | Puertos COM: {2}" -f @($tasks).Count, @($processes).Count, (@($ports | ForEach-Object { $_.device_id }) -join ','))
if ($evaluation) {
  Write-Host ("Resultado: {0}" -f $evaluation.verdict)
  foreach ($item in @($evaluation.blockers)) { if ($item) { Write-Host ("  BLOQUEA: {0} {1}" -f $item.code, $item.detail) } }
  foreach ($item in @($evaluation.warnings)) { if ($item) { Write-Host ("  aviso: {0} {1}" -f $item.code, $item.detail) } }
}
if ($OutputPath) { Write-Host ("Archivo para enviar (no contiene secretos): {0}" -f $OutputPath) }
exit $exitCode
