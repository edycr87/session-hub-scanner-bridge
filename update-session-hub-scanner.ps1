param(
  [ValidateSet('run','check','recover','install-task','start-task','stop-task','status-task','uninstall-task')]
  [string]$Mode = 'run',
  [string]$InstallRoot = 'C:\ProgramData\SessionHubScannerBridge',
  [string]$ConfigPath = '',
  [string]$UpdaterTaskName = 'SessionHubScannerBridgeUpdater',
  [string]$ManifestUrl = '',
  [string]$Channel = '',
  [int]$UpdateIntervalMinutes = 240,
  [int]$QuietSeconds = 0,
  [int]$HealthTimeoutSeconds = 120,
  [int]$DrainWindowSeconds = 30,
  [int]$InstallDrainAttempts = 4,
  [int]$RollbackDrainAttempts = 6,
  [int]$DeferAlertAfter = 12,
  [int]$FastRetryMinutes = 15
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# OTA policy (see OTA_DESIGN.md). Integrity is mandatory: an update is applied
# only when the manifest entry carries sha256 + size_bytes + a valid signature
# from a pinned key. With no pinned key the updater refuses to apply anything.
# ---------------------------------------------------------------------------
$ReleaseStatementHeader = 'session-hub-scanner-bridge-release/v1'
$ReleaseSignatureAlg = 'RSA-SHA256-PKCS1'
# DEV laboratory trust only; this is public RSA material, never a private key.
$PinnedReleaseKeys = @(
  @{ key_id = 'dev-lab-20261019'; modulus_b64 = 'sN1d5cAe4JG3zlfiVnS5r7Gq9tDoQvVCVfFa+A++ghZAi26rSmfwm34e5MOFaRUkZcvoE+61R4QZAm811xDmI2pd5jKkrVkXk200oD+sKyD7F7L+cUzQdl0Jc6H1MsKmU+ojhXeP5Isoi82gwL8NStS3b4xeeFBLzNe/mjNfthBtoMFoHgnUpNiiprUiTw5KXOQY2jNDjZ7uX0Bral9h6otpONHavKZ45yO9z/TDoQ+AzOKVCryvhWr1GatyShXFO3ccYXqKksDn8Dc6qTFY5wXbFbeIEY7nl4AVLfOncRzxvC3DmvxyjzZTP9WsivbGK+gnMLHsCtCNcKGz9eP/1JfO/3AEp9TVHVWRGjatCnM5lwBWi+1FUKTOF/5xVabbYZLPr1xQW8namr2kqRfJz2nXWK4tbsorAapzsYAhiqGG9QC6wBqA20v0AlIBl2RHM2JQkWZ5rGUuUtF+uEpM2r+o33KRsO270std8ncuywMNTawjHeiUYBp24Ujy4XWV'; exponent_b64 = 'AQAB' }
)
$MaxPackageBytes = 536870912
# Closed schema of a signed manifest entry (manifest.signed_channels.<channel>).
# Must match SIGNED_ENTRY_KEYS / SIGNATURE_KEYS in
# backend/scripts/publish_session_hub_scanner_release.js.
$SignedEntryKeys = @('version', 'package_url', 'sha256', 'size_bytes', 'min_installed_version', 'notes', 'signature')
$SignatureKeys = @('alg', 'key_id', 'value')
# Never shipped in a package, never moved, never written by the updater.
$ProtectedNames = @(
  'scanner-bridge-config.json',
  'installed-version.txt',
  'bridge-state.json',
  'update-drain.request',
  'update-status.json',
  'update.lock',
  'bridge.log',
  'bridge.err',
  'runner.log',
  'tray.log',
  'update.log',
  '.ota'
)
$RequiredPackageFiles = @(
  'bridge.js',
  'node.exe',
  'package.json',
  'package-version.txt',
  'run-session-hub-bridge.ps1',
  'update-session-hub-scanner.ps1',
  'diagnose-session-hub-scanner.ps1',
  'diagnose-session-hub-scanner.js'
)
# Payload names known from packages built before the inventory existed.
$LegacyManagedNames = @(
  'bridge.js',
  'README.md',
  'package.json',
  'package-lock.json',
  'run-session-hub-bridge.ps1',
  'install-session-hub-scanner.ps1',
  'update-session-hub-scanner.ps1',
  'build-session-hub-scanner-package.ps1',
  'discover-session-hub-readers.ps1',
  'tray-session-hub-bridge.ps1',
  'node_modules',
  'node.exe',
  'package-version.txt'
)

$resolvedInstallRoot = if (Test-Path $InstallRoot) { (Resolve-Path $InstallRoot).Path } else { $InstallRoot }
$resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $resolvedInstallRoot 'scanner-bridge-config.json' }
$updateLog = Join-Path $resolvedInstallRoot 'update.log'
$runnerScript = Join-Path $resolvedInstallRoot 'run-session-hub-bridge.ps1'
$statePath = Join-Path $resolvedInstallRoot 'bridge-state.json'
$drainPath = Join-Path $resolvedInstallRoot 'update-drain.request'
$lockPath = Join-Path $resolvedInstallRoot 'update.lock'
$installedVersionPath = Join-Path $resolvedInstallRoot 'installed-version.txt'
$otaRoot = Join-Path $resolvedInstallRoot '.ota'
$journalPath = Join-Path $otaRoot 'journal.json'
$inventoryPath = Join-Path $otaRoot 'installed-inventory.json'
$blockedPath = Join-Path $otaRoot 'blocked-versions.json'
$lastCheckPath = Join-Path $otaRoot 'last-check.json'
# Public, secret-free mirror of the update state for the tray (user context
# cannot read .ota, which is SYSTEM/Administrators only).
$statusPath = Join-Path $resolvedInstallRoot 'update-status.json'

function Trace-Update {
  param([string]$Message)
  $ts = Get-Date -Format 'o'
  try {
    Add-Content -Path $updateLog -Value "[$ts] $Message"
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

function Write-DurableText {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $tmp = "$Path.tmp"
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
  $stream = New-Object System.IO.FileStream($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  } finally {
    $stream.Dispose()
  }
  if (Test-Path -LiteralPath $Path) {
    [System.IO.File]::Replace($tmp, $Path, $null)
  } else {
    [System.IO.File]::Move($tmp, $Path)
  }
}

function Write-JsonDurable {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  Write-DurableText -Path $Path -Text ($Value | ConvertTo-Json -Depth 8)
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  try {
    $text = [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    return $text | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-UtcDate {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
  try {
    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  } catch {
    return $null
  }
}

function ConvertTo-StrictVersion {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $trimmed = $Value.Trim()
  if ($trimmed -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$') { return $null }
  return [Version]$trimmed
}

function Read-BridgeConfig {
  if (-not (Test-Path $resolvedConfigPath)) {
    return $null
  }

  try {
    return Get-Content -Path $resolvedConfigPath -Raw | ConvertFrom-Json
  } catch {
    Trace-Update "Config read failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-InstalledVersion {
  if (Test-Path $installedVersionPath) {
    return (Get-Content -Path $installedVersionPath -Raw).Trim()
  }

  $packageVersionFile = Join-Path $resolvedInstallRoot 'package-version.txt'
  if (Test-Path $packageVersionFile) {
    return (Get-Content -Path $packageVersionFile -Raw).Trim()
  }

  $packageJsonPath = Join-Path $resolvedInstallRoot 'package.json'
  if (Test-Path $packageJsonPath) {
    try {
      $packageJson = Get-Content -Path $packageJsonPath -Raw | ConvertFrom-Json
      if ($packageJson.version) {
        return [string]$packageJson.version
      }
    } catch {
      # ignore
    }
  }

  return '0.0.0'
}

function Initialize-OtaRoot {
  if (-not (Test-Path -LiteralPath $otaRoot)) {
    New-Item -ItemType Directory -Path $otaRoot -Force | Out-Null
  }
  # Only SYSTEM and Administrators may touch staged payloads (no TOCTOU by
  # unprivileged local users between verification and activation).
  try {
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
      $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
      $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', $inherit, $propagation, 'Allow')
      $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $otaRoot -AclObject $acl
  } catch {
    throw "OTA_ACL_SETUP_FAILED: $($_.Exception.Message)"
  }
}

function Enter-UpdateLock {
  try {
    return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  } catch {
    return $null
  }
}

function Resolve-DownloadUrl {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$CandidateUrl
  )

  if ($CandidateUrl -match '^https?://') {
    return $CandidateUrl
  }

  $baseUri = [Uri]$BaseUrl
  return ([Uri]::new($baseUri, $CandidateUrl)).AbsoluteUri
}

function Invoke-BridgeRunner {
  param(
    [Parameter(Mandatory = $true)][string]$RunnerMode
  )

  if (-not (Test-Path $runnerScript)) {
    throw "No existe $runnerScript"
  }

  $config = Read-BridgeConfig
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $runnerScript,
    '-Mode',
    $RunnerMode,
    '-Root',
    $resolvedInstallRoot
  )

  if ($config -and $config.task_name) {
    $args += @('-TaskName', [string]$config.task_name)
  }
  if ($config -and $config.tray_task_name) {
    $args += @('-TrayTaskName', [string]$config.tray_task_name)
  }
  if ($config -and $config.host_id) {
    $args += @('-HostId', [string]$config.host_id)
  }

  & (Resolve-PowerShellExecutable) @args | Out-Host
}

function Get-BridgeTaskName {
  $config = Read-BridgeConfig
  if ($config -and $config.task_name) { return [string]$config.task_name }
  return 'SessionHubScannerBridge'
}

function Set-BridgeTaskEnabled {
  param([bool]$Enabled)
  $name = Get-BridgeTaskName
  if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) { return }
  if ($Enabled) {
    Enable-ScheduledTask -TaskName $name | Out-Null
  } else {
    Disable-ScheduledTask -TaskName $name | Out-Null
  }
}

function Get-RunningBridgeProcessIds {
  $needle = (Join-Path $resolvedInstallRoot 'bridge.js').ToLowerInvariant()
  $exeNeedle = (Join-Path $resolvedInstallRoot 'session-hub-scanner-bridge.exe').ToLowerInvariant()
  $found = @()
  $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -eq 'node.exe' -or $_.Name -eq 'session-hub-scanner-bridge.exe'
  }
  foreach ($proc in @($processes)) {
    if (-not $proc -or [string]::IsNullOrWhiteSpace($proc.CommandLine)) { continue }
    $line = $proc.CommandLine.ToLowerInvariant()
    if ($line.Contains($needle) -or $line.Contains($exeNeedle)) {
      $found += [int]$proc.ProcessId
    }
  }
  return $found
}

function Test-ProcessAlive {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $false }
  return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-BridgeState {
  return Read-JsonFile -Path $statePath
}

function Test-StateFresh {
  param($State, [int]$MaxAgeSeconds = 15)
  if (-not $State) { return $false }
  $updated = ConvertTo-UtcDate $State.updated_at
  if (-not $updated) { return $false }
  return (((Get-Date).ToUniversalTime() - $updated).TotalSeconds -le $MaxAgeSeconds)
}

function Test-InUpdateWindow {
  param($Config)
  if (-not $Config -or -not $Config.update_window) { return $true }
  $window = [string]$Config.update_window
  if ($window -notmatch '^(\d{2}):(\d{2})-(\d{2}):(\d{2})$') {
    Trace-Update "UPDATE_WINDOW_INVALID value=$window; deferring (fail-closed)"
    return $false
  }
  $start = [int]$Matches[1] * 60 + [int]$Matches[2]
  $end = [int]$Matches[3] * 60 + [int]$Matches[4]
  $now = (Get-Date).Hour * 60 + (Get-Date).Minute
  if ($start -le $end) { return ($now -ge $start -and $now -lt $end) }
  return ($now -ge $start -or $now -lt $end)
}

function Get-QuietSeconds {
  param($Config)
  if ($QuietSeconds -gt 0) { return $QuietSeconds }
  if ($Config -and $Config.update_quiet_seconds) {
    try { return [Math]::Max(10, [int]$Config.update_quiet_seconds) } catch { }
  }
  return 120
}

# Returns @{ verdict = 'not_running' | 'idle' | 'busy' | 'unknown'; detail; state }
function Get-IdleVerdict {
  param([int]$Quiet)
  $state = Get-BridgeState
  $running = @(Get-RunningBridgeProcessIds)
  if ($running.Count -eq 0) {
    return @{ verdict = 'not_running'; detail = 'no bridge process'; state = $state }
  }
  if (-not $state -or -not (Test-StateFresh -State $state)) {
    return @{ verdict = 'unknown'; detail = 'bridge running without fresh state file'; state = $state }
  }
  if (-not ($running -contains [int]$state.pid)) {
    return @{ verdict = 'unknown'; detail = 'state pid does not match running bridge'; state = $state }
  }
  if ([int]$state.pending_total -gt 0 -or [bool]$state.in_flight -or [bool]$state.partial_input) {
    return @{ verdict = 'busy'; detail = "pending_total=$($state.pending_total) in_flight=$($state.in_flight) partial_input=$($state.partial_input)"; state = $state }
  }
  $lastCapture = ConvertTo-UtcDate $state.last_capture_at
  if ($lastCapture -and (((Get-Date).ToUniversalTime() - $lastCapture).TotalSeconds -lt $Quiet)) {
    return @{ verdict = 'busy'; detail = "last capture less than $Quiet s ago"; state = $state }
  }
  return @{ verdict = 'idle'; detail = 'no pending scans or ACKs'; state = $state }
}

function Remove-DrainRequest {
  if (Test-Path -LiteralPath $drainPath) {
    Remove-Item -LiteralPath $drainPath -Force -ErrorAction SilentlyContinue
  }
}

# Asks the bridge to exit by itself once nothing is pending. Never kills it.
function Invoke-BridgeDrain {
  param([int]$TimeoutSeconds)
  $nonce = [guid]::NewGuid().ToString('N')
  Write-DurableText -Path $drainPath -Text ((@{ nonce = $nonce; requested_at = (Get-Date).ToUniversalTime().ToString('o') }) | ConvertTo-Json)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $state = Get-BridgeState
    $running = @(Get-RunningBridgeProcessIds)
    if ($state -and [bool]$state.drained -and [string]$state.drain_nonce -eq $nonce -and $running.Count -eq 0) {
      Remove-DrainRequest
      return $true
    }
  }
  Remove-DrainRequest
  return $false
}

function Get-ReleaseStatement {
  param([string]$ChannelName, $Entry)
  $lines = @(
    $ReleaseStatementHeader,
    ('channel=' + $ChannelName),
    ('version=' + [string]$Entry.version),
    ('sha256=' + ([string]$Entry.sha256).ToLowerInvariant()),
    ('size_bytes=' + [string]([int64]$Entry.size_bytes)),
    ('min_installed_version=' + [string]$Entry.min_installed_version)
  )
  return (($lines -join "`n") + "`n")
}

function Test-ReleaseSignature {
  param([string]$Statement, $Signature)
  if (-not $Signature -or [string]$Signature.alg -ne $ReleaseSignatureAlg) { return $false }
  $key = $PinnedReleaseKeys | Where-Object { $_.key_id -eq [string]$Signature.key_id } | Select-Object -First 1
  if (-not $key) { return $false }
  $rsa = $null
  try {
    $parameters = New-Object System.Security.Cryptography.RSAParameters
    $parameters.Modulus = [Convert]::FromBase64String([string]$key.modulus_b64)
    $parameters.Exponent = [Convert]::FromBase64String([string]$key.exponent_b64)
    $rsa = New-Object System.Security.Cryptography.RSACng
    $rsa.ImportParameters($parameters)
    if ($rsa.KeySize -lt 3072) { return $false }
    $data = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Statement)
    $sig = [Convert]::FromBase64String([string]$Signature.value)
    return $rsa.VerifyData($data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  } catch {
    return $false
  } finally {
    if ($rsa) { $rsa.Dispose() }
  }
}

# Validates the manifest entry before any download. Returns an error code or $null.
function Test-ManifestEntry {
  param([string]$ChannelName, $Entry)
  if (-not $Entry) { return 'MANIFEST_CHANNEL_MISSING' }
  $entryKeys = @($Entry.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
  if (($entryKeys -join ',') -cne ((@($SignedEntryKeys) | Sort-Object) -join ',')) { return 'MANIFEST_ENTRY_FIELDS_INVALID' }
  if (-not $Entry.signature) { return 'MANIFEST_SIGNATURE_INVALID' }
  $signatureKeys = @($Entry.signature.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
  if (($signatureKeys -join ',') -cne ((@($SignatureKeys) | Sort-Object) -join ',')) { return 'MANIFEST_SIGNATURE_FIELDS_INVALID' }
  if (-not (ConvertTo-StrictVersion ([string]$Entry.version))) { return 'MANIFEST_VERSION_INVALID' }
  if ([string]$Entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { return 'MANIFEST_SHA256_REQUIRED' }
  if (-not (($Entry.size_bytes -is [int32]) -or ($Entry.size_bytes -is [int64]))) { return 'MANIFEST_SIZE_REQUIRED' }
  $size = [int64]$Entry.size_bytes
  if ($size -le 0 -or $size -gt $MaxPackageBytes) { return 'MANIFEST_SIZE_REQUIRED' }
  $minVersion = ConvertTo-StrictVersion ([string]$Entry.min_installed_version)
  if (-not $minVersion) { return 'MANIFEST_MIN_INSTALLED_VERSION_REQUIRED' }
  if ($minVersion -gt (ConvertTo-StrictVersion ([string]$Entry.version))) { return 'MANIFEST_MIN_INSTALLED_VERSION_ABOVE_VERSION' }
  if (-not ($Entry.package_url -is [string]) -or [string]::IsNullOrWhiteSpace($Entry.package_url)) { return 'MANIFEST_PACKAGE_URL_REQUIRED' }
  if (@($PinnedReleaseKeys).Count -eq 0) { return 'UPDATE_SIGNING_KEY_NOT_PINNED' }
  $statement = Get-ReleaseStatement -ChannelName $ChannelName -Entry $Entry
  if (-not (Test-ReleaseSignature -Statement $statement -Signature $Entry.signature)) { return 'MANIFEST_SIGNATURE_INVALID' }
  return $null
}

function Test-VersionBlocked {
  param([string]$Version)
  $blocked = Read-JsonFile -Path $blockedPath
  if (-not $blocked -or -not $blocked.versions) { return $false }
  return (@($blocked.versions) -contains $Version)
}

function Add-BlockedVersion {
  param([string]$Version, [string]$Reason)
  $blocked = Read-JsonFile -Path $blockedPath
  $versions = @()
  if ($blocked -and $blocked.versions) { $versions = @($blocked.versions) }
  if (-not ($versions -contains $Version)) { $versions += $Version }
  Write-JsonDurable -Path $blockedPath -Value @{ versions = $versions; last_reason = $Reason; updated_at = (Get-Date).ToUniversalTime().ToString('o') }
}

function Save-Journal {
  param([hashtable]$Journal, [string]$Phase)
  $Journal.phase = $Phase
  $Journal.updated_at = (Get-Date).ToUniversalTime().ToString('o')
  Write-JsonDurable -Path $journalPath -Value $Journal
  Write-UpdateStatus -Journal $Journal
  Trace-Update "Journal phase=$Phase id=$($Journal.id) target=$($Journal.target_version)"
}

function ConvertTo-JournalHashtable {
  param($Object)
  $result = @{}
  if (-not $Object) { return $result }
  foreach ($property in $Object.PSObject.Properties) {
    $result[$property.Name] = $property.Value
  }
  return $result
}

# Extracts the zip into $Destination refusing traversal, protected names and
# extra top-level layouts. Returns the list of top-level payload names.
function Expand-VerifiedPackage {
  param([string]$ZipPath, [string]$Destination, [string]$ExpectedVersion)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
  $prefix = 'session-hub-scanner-bridge/'
  $topLevel = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if (-not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "PACKAGE_LAYOUT_INVALID: $name"
      }
      $relative = $name.Substring($prefix.Length)
      if ([string]::IsNullOrEmpty($relative)) { continue }
      $first = $relative.Split('/')[0]
      foreach ($protected in $ProtectedNames) {
        if ($first -ieq $protected) { throw "PACKAGE_CONTAINS_PROTECTED_FILE: $first" }
      }
      $target = [System.IO.Path]::GetFullPath((Join-Path $Destination ($relative.Replace('/', '\'))))
      if (-not $target.StartsWith($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "PACKAGE_PATH_TRAVERSAL: $name"
      }
      [void]$topLevel.Add($first)
      if ($name.EndsWith('/')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        continue
      }
      $parent = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
    }
  } finally {
    $zip.Dispose()
  }
  foreach ($required in $RequiredPackageFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $Destination $required))) {
      throw "PACKAGE_MISSING_REQUIRED_FILE: $required"
    }
  }
  $packageVersion = ([System.IO.File]::ReadAllText((Join-Path $Destination 'package-version.txt'))).TrimStart([char]0xFEFF).Trim()
  if ($packageVersion -ne $ExpectedVersion) {
    throw "PACKAGE_VERSION_MISMATCH: package=$packageVersion manifest=$ExpectedVersion"
  }
  return @($topLevel)
}

function Get-ManagedNames {
  param([string[]]$NewNames)
  $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @($NewNames)) { [void]$set.Add($name) }
  $inventory = Read-JsonFile -Path $inventoryPath
  $previous = if ($inventory -and $inventory.names) { @($inventory.names) } else { $LegacyManagedNames }
  foreach ($name in @($previous)) { [void]$set.Add([string]$name) }
  foreach ($protected in $ProtectedNames) { [void]$set.Remove($protected) }
  return @($set)
}

# Restores the previous payload from the backup recorded in the journal.
# restore_mode 'moved_only' (interrupted during 'backup'): only moves back what
# was already moved. 'full': removes managed names from root, then moves the
# backup back. The mode is fixed when the rollback starts, so a deferred
# rollback keeps it.
function Restore-FromJournal {
  param([hashtable]$Journal)
  $backupDir = [string]$Journal.backup_dir
  $mode = [string]$Journal.restore_mode
  $names = @($Journal.managed_names)
  if ($mode -ne 'moved_only') {
    foreach ($name in $names) {
      $current = Join-Path $resolvedInstallRoot $name
      if (Test-Path -LiteralPath $current) {
        Remove-Item -LiteralPath $current -Recurse -Force
      }
    }
  }
  foreach ($name in $names) {
    $saved = Join-Path $backupDir $name
    $current = Join-Path $resolvedInstallRoot $name
    if (Test-Path -LiteralPath $saved) {
      if (Test-Path -LiteralPath $current) {
        Remove-Item -LiteralPath $current -Recurse -Force
      }
      Move-Item -LiteralPath $saved -Destination $current
    }
  }
  if ($Journal.previous_version) {
    Write-DurableText -Path $installedVersionPath -Text ([string]$Journal.previous_version)
  }
}

function Test-ConfigPreserved {
  param([hashtable]$Journal)
  if (-not $Journal.config_sha256) { return $true }
  if ((Test-Path -LiteralPath $resolvedConfigPath) -and ((Get-FileSha256 -Path $resolvedConfigPath) -eq [string]$Journal.config_sha256)) {
    return $true
  }
  $guard = [string]$Journal.config_guard
  if ($guard -and (Test-Path -LiteralPath $guard)) {
    Copy-Item -LiteralPath $guard -Destination $resolvedConfigPath -Force
    Trace-Update 'CONFIG_RESTORED_FROM_GUARD (config changed or missing during update)'
  }
  return $false
}

function Remove-ConfigGuard {
  param([hashtable]$Journal)
  $guard = [string]$Journal.config_guard
  if ($guard -and (Test-Path -LiteralPath $guard)) {
    Remove-Item -LiteralPath $guard -Force -ErrorAction SilentlyContinue
  }
}

# Health: new process, expected version, registered with the backend, every
# reader that was open before the update is open again, config untouched.
function Wait-BridgeHealthy {
  param([string]$ExpectedVersion, [DateTime]$StartedAfterUtc, $BaselineOpenReaders, [int]$TimeoutSeconds)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $last = 'no state yet'
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $state = Get-BridgeState
    if (-not $state) { $last = 'no state file'; continue }
    $started = ConvertTo-UtcDate $state.started_at
    if (-not $started -or $started -lt $StartedAfterUtc.AddSeconds(-2)) { $last = 'state belongs to an older process'; continue }
    if (-not (Test-ProcessAlive -ProcessId ([int]$state.pid))) { $last = 'bridge process exited'; continue }
    if ([string]$state.version -ne $ExpectedVersion) { $last = "version=$($state.version)"; continue }
    if (-not [bool]$state.ws_ready) { $last = 'not registered with backend'; continue }
    $missing = @()
    foreach ($readerId in @(@($BaselineOpenReaders) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
      $match = @($state.readers) | Where-Object { [string]$_.reader_id -eq [string]$readerId -and [string]$_.state -eq 'open' }
      if (-not $match) { $missing += [string]$readerId }
    }
    if ($missing.Count -gt 0) { $last = 'readers not open: ' + ($missing -join ','); continue }
    return @{ ok = $true; detail = 'healthy' }
  }
  return @{ ok = $false; detail = $last }
}

function Get-OpenReaderIds {
  param($State)
  if (-not $State -or -not $State.readers) { return @() }
  return @(@($State.readers) | Where-Object { [string]$_.state -eq 'open' } | ForEach-Object { [string]$_.reader_id })
}

# Never stops the bridge: retries the cooperative drain with exponential backoff.
# Between attempts the drain request is removed, so the bridge never exits while
# nobody is waiting to restart it. Returns $true only when no bridge is running.
function Wait-BridgeDrainWithBackoff {
  param([int]$Attempts, [string]$Why)
  for ($attempt = 1; $attempt -le [Math]::Max(1, $Attempts); $attempt++) {
    if (@(Get-RunningBridgeProcessIds).Count -eq 0) { return $true }
    if (Invoke-BridgeDrain -TimeoutSeconds $DrainWindowSeconds) { return $true }
    $state = Get-BridgeState
    $pending = if ($state) { [int]$state.pending_total } else { -1 }
    Trace-Update "DRAIN_NOT_IDLE reason=$Why attempt=$attempt/$Attempts pending_total=$pending"
    if ($attempt -lt $Attempts) {
      $delay = [Math]::Min(300, $DrainWindowSeconds * [Math]::Pow(2, $attempt - 1))
      Start-Sleep -Seconds ([int]$delay)
    }
  }
  return $false
}

function Write-UpdateStatus {
  param([hashtable]$Journal)
  $status = [ordered]@{
    schema = 'session-hub-scanner-update-status/v1'
    phase = [string]$Journal.phase
    target_version = [string]$Journal.target_version
    previous_version = [string]$Journal.previous_version
    defer_count = [int]$Journal.defer_count
    last_deferral_reason = [string]$Journal.last_deferral_reason
    alert = [bool]$Journal.defer_alert
    updated_at = (Get-Date).ToUniversalTime().ToString('o')
  }
  try {
    Write-DurableText -Path $statusPath -Text ($status | ConvertTo-Json)
  } catch {
    Trace-Update "STATUS_WRITE_FAILED: $($_.Exception.Message)"
  }
}

# Records a deferral (install or rollback). The cap only raises an alert.
function Register-Deferral {
  param([hashtable]$Journal, [string]$Phase, [string]$Reason)
  $count = 0
  try { $count = [int]$Journal.defer_count } catch { $count = 0 }
  $Journal.defer_count = $count + 1
  $Journal.last_deferral_reason = $Reason
  $Journal.last_deferral_at = (Get-Date).ToUniversalTime().ToString('o')
  if ($Journal.defer_count -ge $DeferAlertAfter) {
    $Journal.defer_alert = $true
    Trace-Update "UPDATE_DEFER_LIMIT_ALERT phase=$Phase count=$($Journal.defer_count) target=$($Journal.target_version); not forcing"
  }
  Save-Journal -Journal $Journal -Phase $Phase
  Trace-Update "UPDATE_DEFERRED phase=$Phase count=$($Journal.defer_count) reason=$Reason"
}

# Starting through the runner kills any running bridge (Stop-RunningBridge), so
# the updater only starts when none is running.
function Start-BridgeIfStopped {
  if (@(Get-RunningBridgeProcessIds).Count -gt 0) {
    Trace-Update 'Start skipped: a bridge process is already running (never killed by the updater).'
    return
  }
  Invoke-BridgeRunner -RunnerMode 'start-task'
}

# Returns 'rolled_back' or 'rollback_deferred'. While deferred, the version
# that is running (possibly the new, degraded one) keeps capturing: its memory
# holds the only copy of the pending scans, so stopping it would lose them.
function Invoke-Rollback {
  param([hashtable]$Journal, [string]$Reason, [bool]$BlockVersion)
  if (-not $Journal.restore_mode) {
    $Journal.restore_mode = if ([string]$Journal.phase -eq 'backup') { 'moved_only' } else { 'full' }
  }
  if (-not $Journal.rollback_reason) { $Journal.rollback_reason = $Reason }
  if ($BlockVersion) { $Journal.block_target_on_rollback = $true }
  Trace-Update "Rollback requested: $Reason"
  if (-not (Wait-BridgeDrainWithBackoff -Attempts $RollbackDrainAttempts -Why "rollback:$Reason")) {
    Set-BridgeTaskEnabled -Enabled $true
    Register-Deferral -Journal $Journal -Phase 'rollback_deferred' -Reason "pending scans/ACK during rollback ($Reason)"
    return 'rollback_deferred'
  }
  Set-BridgeTaskEnabled -Enabled $false
  if (@(Get-RunningBridgeProcessIds).Count -gt 0) {
    # A bridge started between the drain and the task disable (e.g. AtLogOn).
    Set-BridgeTaskEnabled -Enabled $true
    Register-Deferral -Journal $Journal -Phase 'rollback_deferred' -Reason 'bridge restarted before restore'
    return 'rollback_deferred'
  }
  Restore-FromJournal -Journal $Journal
  $configOk = Test-ConfigPreserved -Journal $Journal
  Save-Journal -Journal $Journal -Phase 'restored'
  Set-BridgeTaskEnabled -Enabled $true
  $restartAt = (Get-Date).ToUniversalTime()
  Start-BridgeIfStopped
  $health = Wait-BridgeHealthy -ExpectedVersion ([string]$Journal.previous_version) -StartedAfterUtc $restartAt -BaselineOpenReaders $Journal.baseline_open_readers -TimeoutSeconds $HealthTimeoutSeconds
  if ([bool]$Journal.block_target_on_rollback) { Add-BlockedVersion -Version ([string]$Journal.target_version) -Reason ([string]$Journal.rollback_reason) }
  $Journal.rollback_health = $health.detail
  $Journal.config_preserved = $configOk
  Remove-ConfigGuard -Journal $Journal
  Save-Journal -Journal $Journal -Phase 'rolled_back'
  Trace-Update "Rollback finished. previous=$($Journal.previous_version) health=$($health.detail) config_preserved=$configOk"
  return 'rolled_back'
}

# Called at every start (the updater task also runs AtStartup and every
# FastRetryMinutes): finishes or reverts an update interrupted by a crash or a
# power cut, and retries deferred rollbacks. Returns $true while a rollback is
# still pending, so no new install starts on top of it.
function Resume-PendingUpdate {
  $raw = Read-JsonFile -Path $journalPath
  if (-not $raw) { return $false }
  $journal = ConvertTo-JournalHashtable $raw
  $phase = [string]$journal.phase
  if (@('backup', 'activate', 'starting', 'health', 'rollback_deferred') -contains $phase) {
    $reason = if ($phase -eq 'rollback_deferred') { [string]$journal.rollback_reason } else { "interrupted_in_$phase" }
    Trace-Update "Pending update found (phase=$phase); reverting to $($journal.previous_version)"
    try {
      $result = Invoke-Rollback -Journal $journal -Reason $reason -BlockVersion ([bool]$journal.block_target_on_rollback)
      return ($result -eq 'rollback_deferred')
    } catch {
      Trace-Update "RECOVERY_FAILED: $($_.Exception.Message)"
      Set-BridgeTaskEnabled -Enabled $true
      throw
    }
  } elseif ($phase -eq 'restored') {
    Set-BridgeTaskEnabled -Enabled $true
    Save-Journal -Journal $journal -Phase 'rolled_back'
  }
  return $false
}

function Test-CheckDue {
  param($Config)
  $journal = Read-JsonFile -Path $journalPath
  if ($journal -and [string]$journal.phase -eq 'install_deferred') { return $true }
  $interval = $UpdateIntervalMinutes
  if ($Config -and $Config.update_interval_minutes) {
    try { $interval = [Math]::Max(15, [int]$Config.update_interval_minutes) } catch { }
  }
  $last = Read-JsonFile -Path $lastCheckPath
  $lastAt = if ($last) { ConvertTo-UtcDate $last.checked_at } else { $null }
  if (-not $lastAt) { return $true }
  return (((Get-Date).ToUniversalTime() - $lastAt).TotalMinutes -ge ($interval - 1))
}

function Write-InstallDeferral {
  param([string]$TargetVersion, [string]$InstalledVersion, [string]$Reason)
  $previous = Read-JsonFile -Path $journalPath
  $journal = @{
    id = 'deferred-' + $TargetVersion
    target_version = $TargetVersion
    previous_version = $InstalledVersion
    defer_count = 0
  }
  if ($previous -and [string]$previous.phase -eq 'install_deferred' -and [string]$previous.target_version -eq $TargetVersion) {
    $journal.defer_count = [int]$previous.defer_count
    $journal.defer_alert = [bool]$previous.defer_alert
  }
  Register-Deferral -Journal $journal -Phase 'install_deferred' -Reason $Reason
}

function Apply-UpdateFromManifest {
  param(
    [Parameter(Mandatory = $true)]$Entry,
    [Parameter(Mandatory = $true)][string]$BaseManifestUrl,
    [Parameter(Mandatory = $true)][string]$ChannelName,
    [Parameter(Mandatory = $true)][string]$InstalledVersion,
    $Config
  )

  $targetVersion = [string]$Entry.version
  $expectedSha = ([string]$Entry.sha256).ToLowerInvariant()
  $expectedSize = [int64]$Entry.size_bytes
  $packageUrlCandidate = if ($Entry.package_url) { [string]$Entry.package_url } else { [string]$Entry.url }
  $packageUrl = Resolve-DownloadUrl -BaseUrl $BaseManifestUrl -CandidateUrl $packageUrlCandidate
  if ($packageUrl -notmatch '^https://') { throw 'PACKAGE_URL_NOT_HTTPS' }

  $id = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $targetVersion
  $downloadDir = Join-Path $otaRoot 'download'
  $stagingDir = Join-Path (Join-Path $otaRoot 'staging') $id
  $backupDir = Join-Path (Join-Path $otaRoot 'backup') $id
  New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
  $partialZip = Join-Path $downloadDir ($id + '.zip.partial')
  $zipPath = Join-Path $downloadDir ($id + '.zip')

  try {
    Trace-Update "Downloading $packageUrl"
    Invoke-WebRequest -Uri $packageUrl -OutFile $partialZip -UseBasicParsing -TimeoutSec 600
    $actualSize = (Get-Item -LiteralPath $partialZip).Length
    if ($actualSize -ne $expectedSize) { throw "PACKAGE_SIZE_MISMATCH expected=$expectedSize actual=$actualSize" }
    $actualSha = Get-FileSha256 -Path $partialZip
    if ($actualSha -ne $expectedSha) { throw "PACKAGE_SHA256_MISMATCH expected=$expectedSha actual=$actualSha" }
    Move-Item -LiteralPath $partialZip -Destination $zipPath
    $newNames = Expand-VerifiedPackage -ZipPath $zipPath -Destination $stagingDir -ExpectedVersion $targetVersion
  } catch {
    Trace-Update "UPDATE_REJECTED_BEFORE_ACTIVATION: $($_.Exception.Message)"
    foreach ($path in @($partialZip, $zipPath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    return
  }

  # Read-only diagnostic of the installed client with the verified (staged)
  # diagnostic, before anything is drained or moved. BLOCK or error stops here.
  $diagnosticReport = Join-Path $otaRoot ('diagnostic-' + $id + '.json')
  $diagnosticCode = 1
  try {
    & (Resolve-PowerShellExecutable) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $stagingDir 'diagnose-session-hub-scanner.ps1') -Context ota -TargetInstallRoot $resolvedInstallRoot -OutputPath $diagnosticReport | Out-Null
    $diagnosticCode = $LASTEXITCODE
  } catch {
    $diagnosticCode = 1
  }
  if ($diagnosticCode -ne 0) {
    Trace-Update "UPDATE_BLOCKED_BY_DIAGNOSTIC code=$diagnosticCode report=$diagnosticReport"
    $blocked = @{ id = 'blocked-' + $targetVersion; target_version = $targetVersion; previous_version = $InstalledVersion; diagnostic_report = $diagnosticReport; defer_alert = $true; last_deferral_reason = "diagnostic exit $diagnosticCode" }
    Save-Journal -Journal $blocked -Phase 'install_blocked'
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    return
  }

  # Inactivity gate: never cut a scan or an ACK. Postpone instead.
  $quiet = Get-QuietSeconds -Config $Config
  $verdict = Get-IdleVerdict -Quiet $quiet
  # Readers that must be open again after the update: only meaningful when the
  # bridge was running and reporting fresh state.
  $baselineOpen = if ($verdict.verdict -eq 'idle' -or $verdict.verdict -eq 'busy') { Get-OpenReaderIds -State $verdict.state } else { @() }
  if ($verdict.verdict -eq 'busy') {
    # Busy now: back off inside this run before giving up until the next one.
    if (Wait-BridgeDrainWithBackoff -Attempts $InstallDrainAttempts -Why 'install') {
      $verdict = @{ verdict = 'drained'; detail = 'drained after backoff'; state = $verdict.state }
    }
  }
  if ($verdict.verdict -eq 'busy' -or $verdict.verdict -eq 'unknown') {
    Trace-Update "UPDATE_DEFERRED_BUSY verdict=$($verdict.verdict) detail=$($verdict.detail)"
    Write-InstallDeferral -TargetVersion $targetVersion -InstalledVersion $InstalledVersion -Reason "install: $($verdict.verdict) $($verdict.detail)"
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    return
  }

  $configSha = if (Test-Path -LiteralPath $resolvedConfigPath) { Get-FileSha256 -Path $resolvedConfigPath } else { $null }
  $guard = $null
  if ($configSha) {
    $guard = Join-Path $otaRoot ('config-guard-' + $id + '.json')
    Copy-Item -LiteralPath $resolvedConfigPath -Destination $guard -Force
  }
  $journal = @{
    id = $id
    target_version = $targetVersion
    previous_version = $InstalledVersion
    channel = $ChannelName
    package_sha256 = $expectedSha
    staging_dir = $stagingDir
    backup_dir = $backupDir
    managed_names = (Get-ManagedNames -NewNames $newNames)
    new_names = $newNames
    baseline_open_readers = $baselineOpen
    config_sha256 = $configSha
    config_guard = $guard
  }

  Set-BridgeTaskEnabled -Enabled $false
  if ($verdict.verdict -eq 'idle') {
    if (-not (Wait-BridgeDrainWithBackoff -Attempts $InstallDrainAttempts -Why 'install')) {
      Set-BridgeTaskEnabled -Enabled $true
      Trace-Update 'UPDATE_DEFERRED_DRAIN_TIMEOUT (scan arrived or bridge did not drain); bridge keeps running'
      Write-InstallDeferral -TargetVersion $targetVersion -InstalledVersion $InstalledVersion -Reason 'install: drain timeout with pending scans/ACK'
      Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
      Remove-ConfigGuard -Journal $journal
      return
    }
  }
  if (@(Get-RunningBridgeProcessIds).Count -gt 0) {
    Set-BridgeTaskEnabled -Enabled $true
    Write-InstallDeferral -TargetVersion $targetVersion -InstalledVersion $InstalledVersion -Reason 'install: bridge still running after drain'
    Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-ConfigGuard -Journal $journal
    return
  }

  try {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Save-Journal -Journal $journal -Phase 'backup'
    foreach ($name in @($journal.managed_names)) {
      $current = Join-Path $resolvedInstallRoot $name
      if (Test-Path -LiteralPath $current) {
        Move-Item -LiteralPath $current -Destination (Join-Path $backupDir $name)
      }
    }
    Save-Journal -Journal $journal -Phase 'activate'
    foreach ($name in @($newNames)) {
      Move-Item -LiteralPath (Join-Path $stagingDir $name) -Destination (Join-Path $resolvedInstallRoot $name)
    }
    Write-DurableText -Path $installedVersionPath -Text $targetVersion
    Save-Journal -Journal $journal -Phase 'starting'
    if (-not (Test-ConfigPreserved -Journal $journal)) { throw 'CONFIG_CHANGED_DURING_ACTIVATION' }
    Set-BridgeTaskEnabled -Enabled $true
    $startAt = (Get-Date).ToUniversalTime()
    Start-BridgeIfStopped
    Save-Journal -Journal $journal -Phase 'health'
    $health = Wait-BridgeHealthy -ExpectedVersion $targetVersion -StartedAfterUtc $startAt -BaselineOpenReaders $baselineOpen -TimeoutSeconds $HealthTimeoutSeconds
    if (-not $health.ok) { throw "HEALTH_FAILED: $($health.detail)" }
    if (-not (Test-ConfigPreserved -Journal $journal)) { throw 'CONFIG_CHANGED_AFTER_START' }
  } catch {
    $failure = $_.Exception.Message
    Trace-Update "UPDATE_FAILED: $failure"
    try {
      [void](Invoke-Rollback -Journal $journal -Reason $failure -BlockVersion $true)
    } catch {
      # Journal keeps the interrupted phase: the next run (or AtStartup) retries
      # the restore. The bridge task is never left disabled.
      Trace-Update "ROLLBACK_FAILED: $($_.Exception.Message)"
      Set-BridgeTaskEnabled -Enabled $true
    }
    return
  }

  Write-JsonDurable -Path $inventoryPath -Value @{ version = $targetVersion; names = $newNames; updated_at = (Get-Date).ToUniversalTime().ToString('o') }
  Remove-ConfigGuard -Journal $journal
  Save-Journal -Journal $journal -Phase 'committed'
  # Keep only this update's backup (the previous version) for manual recovery.
  $backupParent = Join-Path $otaRoot 'backup'
  foreach ($dir in @(Get-ChildItem -LiteralPath $backupParent -Directory -ErrorAction SilentlyContinue)) {
    if ($dir.FullName -ne $backupDir) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
  Trace-Update "Update applied successfully. Version=$targetVersion previous=$InstalledVersion"
}

function Invoke-UpdateCheck {
  param([bool]$Apply)
  $config = Read-BridgeConfig

  if (-not $ManifestUrl -and $config -and $config.update_manifest_url) {
    $ManifestUrl = [string]$config.update_manifest_url
  }
  if (-not $Channel) {
    if ($config -and $config.update_channel) {
      $Channel = [string]$config.update_channel
    } else {
      $Channel = 'stable'
    }
  }

  if (-not $ManifestUrl) {
    Trace-Update 'Update check skipped: no update manifest URL configured.'
    Write-Host 'No hay update manifest configurado.'
    return
  }
  if ($ManifestUrl -notmatch '^https://') {
    Trace-Update 'UPDATE_MANIFEST_URL_NOT_HTTPS; refusing.'
    return
  }

  if ($Apply -and -not (Test-CheckDue -Config $config)) {
    return
  }
  Write-JsonDurable -Path $lastCheckPath -Value @{ checked_at = (Get-Date).ToUniversalTime().ToString('o') }
  Trace-Update "Checking updates. Manifest=$ManifestUrl Channel=$Channel Apply=$Apply"
  try {
    $manifest = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 30
  } catch {
    Trace-Update "UPDATE_CHECK_NETWORK_ERROR: $($_.Exception.Message)"
    Write-Host 'No se pudo leer el manifest; se reintenta en el proximo ciclo.'
    return
  }
  $entry = $null
  # Signed entries live in signed_channels: the 1.0.0 updater only reads
  # channels.<channel>, so it never sees (nor applies with its legacy copy) them.
  if ($manifest -and $manifest.signed_channels) { $entry = $manifest.signed_channels.$Channel }

  $problem = Test-ManifestEntry -ChannelName $Channel -Entry $entry
  if ($problem) {
    Trace-Update "UPDATE_REJECTED: $problem"
    Write-Host "Manifest rechazado: $problem"
    return
  }

  $installedVersion = Get-InstalledVersion
  $current = ConvertTo-StrictVersion $installedVersion
  if (-not $current) { $current = [Version]'0.0.0' }
  $available = ConvertTo-StrictVersion ([string]$entry.version)
  Trace-Update "Installed=$installedVersion Available=$($entry.version)"

  if ($available -le $current) {
    $pendingJournal = Read-JsonFile -Path $journalPath
    if ($pendingJournal -and [string]$pendingJournal.phase -eq 'install_deferred') {
      $cleared = ConvertTo-JournalHashtable $pendingJournal
      Save-Journal -Journal $cleared -Phase 'install_deferral_cleared'
    }
    Write-Host "Sin actualizaciones (no se permite downgrade). Instalado=$installedVersion"
    return
  }
  if ($current -lt (ConvertTo-StrictVersion ([string]$entry.min_installed_version))) {
    Trace-Update "UPDATE_REQUIRES_MANUAL_INSTALL installed=$installedVersion min=$($entry.min_installed_version)"
    return
  }
  if (Test-VersionBlocked -Version ([string]$entry.version)) {
    Trace-Update "UPDATE_SKIPPED_BLOCKED_VERSION $($entry.version) (failed health before)"
    return
  }
  if (-not $Apply) {
    Write-Host "Actualizacion disponible (solo chequeo): $installedVersion -> $($entry.version)"
    return
  }
  if (-not (Test-InUpdateWindow -Config $config)) {
    Trace-Update 'UPDATE_DEFERRED_OUTSIDE_WINDOW'
    return
  }

  Write-Host "Actualización encontrada: $installedVersion -> $($entry.version)"
  Apply-UpdateFromManifest -Entry $entry -BaseManifestUrl $ManifestUrl -ChannelName $Channel -InstalledVersion $installedVersion -Config $config
}

function Invoke-WithUpdateLock {
  param([scriptblock]$Body)
  Initialize-OtaRoot
  $lock = Enter-UpdateLock
  if (-not $lock) {
    Trace-Update 'Another updater run holds the lock; exiting.'
    return
  }
  try {
    if (Resume-PendingUpdate) {
      Trace-Update 'Rollback still deferred; no new update is checked in this run.'
      return
    }
    & $Body
  } finally {
    $lock.Dispose()
  }
}

function Ensure-UpdaterTask {
  if (Get-ScheduledTask -TaskName $UpdaterTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $UpdaterTaskName -Confirm:$false | Out-Null
  }

  $scriptPath = Join-Path $resolvedInstallRoot 'update-session-hub-scanner.ps1'
  if (-not (Test-Path $scriptPath)) {
    throw "No existe $scriptPath"
  }

  $powerShellExe = Resolve-PowerShellExecutable
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    ('"' + $scriptPath + '"'),
    '-Mode',
    'run',
    '-InstallRoot',
    ('"' + $resolvedInstallRoot + '"'),
    '-UpdaterTaskName',
    ('"' + $UpdaterTaskName + '"')
  ) -join ' '

  $action = New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
  $startupTrigger = New-ScheduledTaskTrigger -AtStartup
  # The task wakes every FastRetryMinutes so deferred installs/rollbacks retry
  # soon; the manifest itself is fetched only every update_interval_minutes
  # (Test-CheckDue).
  $intervalMinutes = [Math]::Max(5, [Math]::Min($FastRetryMinutes, [Math]::Max(15, $UpdateIntervalMinutes)))
  $repeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -Hidden -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

  Register-ScheduledTask -TaskName $UpdaterTaskName -Action $action -Trigger @($startupTrigger, $repeatTrigger) -Settings $settings -Principal $principal | Out-Null
  Trace-Update "Updater task registered: $UpdaterTaskName interval=$intervalMinutes"
  Write-Host "Updater task $UpdaterTaskName registrada."
}

function Start-UpdaterTask {
  Start-ScheduledTask -TaskName $UpdaterTaskName
  Write-Host "Updater task $UpdaterTaskName iniciada."
}

function Stop-UpdaterTask {
  Stop-ScheduledTask -TaskName $UpdaterTaskName -ErrorAction SilentlyContinue
  Write-Host "Updater task $UpdaterTaskName detenida."
}

function Show-UpdaterTaskStatus {
  $task = Get-ScheduledTask -TaskName $UpdaterTaskName -ErrorAction SilentlyContinue
  if (-not $task) {
    Write-Host "Updater task $UpdaterTaskName no existe."
    return
  }

  $info = Get-ScheduledTaskInfo -TaskName $UpdaterTaskName
  Write-Host "UpdaterTaskName: $UpdaterTaskName"
  Write-Host ("State: {0}" -f $task.State)
  Write-Host ("LastRunTime: {0}" -f $info.LastRunTime)
  Write-Host ("LastTaskResult: {0}" -f $info.LastTaskResult)
  Write-Host ("InstalledVersion: {0}" -f (Get-InstalledVersion))
  Write-Host ("PinnedReleaseKeys: {0}" -f @($PinnedReleaseKeys).Count)
  $journal = Read-JsonFile -Path $journalPath
  if ($journal) {
    Write-Host ("LastUpdate: id={0} phase={1} target={2} previous={3} defer_count={4} alert={5}" -f $journal.id, $journal.phase, $journal.target_version, $journal.previous_version, $journal.defer_count, $journal.defer_alert)
  }
  if (Test-Path $resolvedConfigPath) {
    $config = Read-BridgeConfig
    if ($config -and $config.update_manifest_url) {
      Write-Host ("Manifest: {0}" -f $config.update_manifest_url)
      Write-Host ("Channel: {0}" -f $config.update_channel)
    }
  }
}

function Remove-UpdaterTask {
  Unregister-ScheduledTask -TaskName $UpdaterTaskName -Confirm:$false
  Write-Host "Updater task $UpdaterTaskName eliminada."
}

# Diagnose BEFORE recovery, task mutation or draining; preserve sibling roots/tasks.
# The staged diagnostic below repeats the check immediately before activation.
if ($Mode -ne 'status-task') {
  $diagnostic = Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.ps1'
  if (-not (Test-Path -LiteralPath $diagnostic)) { throw 'DIAGNOSTIC_REQUIRED' }
  $report = Join-Path ([System.IO.Path]::GetTempPath()) ('scanner-ota-preflight-' + [guid]::NewGuid().ToString('N') + '.json')
  & (Resolve-PowerShellExecutable) -NoProfile -ExecutionPolicy Bypass -File $diagnostic -Context ota -TargetInstallRoot $resolvedInstallRoot -OutputPath $report | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "UPDATE_BLOCKED_BY_DIAGNOSTIC report=$report" }
}

switch ($Mode) {
  'run' {
    Invoke-WithUpdateLock { Invoke-UpdateCheck -Apply $true }
  }
  'check' {
    Invoke-WithUpdateLock { Invoke-UpdateCheck -Apply $false }
  }
  'recover' {
    Invoke-WithUpdateLock { }
  }
  'install-task' {
    Ensure-UpdaterTask
  }
  'start-task' {
    Start-UpdaterTask
  }
  'stop-task' {
    Stop-UpdaterTask
  }
  'status-task' {
    Show-UpdaterTaskStatus
  }
  'uninstall-task' {
    Remove-UpdaterTask
  }
}
