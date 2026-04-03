param(
  [ValidateSet('run','check','install-task','start-task','stop-task','status-task','uninstall-task')]
  [string]$Mode = 'run',
  [string]$InstallRoot = 'C:\ProgramData\SessionHubScannerBridge',
  [string]$ConfigPath = '',
  [string]$UpdaterTaskName = 'SessionHubScannerBridgeUpdater',
  [string]$ManifestUrl = '',
  [string]$Channel = '',
  [int]$UpdateIntervalMinutes = 240
)

$ErrorActionPreference = 'Stop'

$resolvedInstallRoot = if (Test-Path $InstallRoot) { (Resolve-Path $InstallRoot).Path } else { $InstallRoot }
$resolvedConfigPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $resolvedInstallRoot 'scanner-bridge-config.json' }
$updateLog = Join-Path $resolvedInstallRoot 'update.log'
$runnerScript = Join-Path $resolvedInstallRoot 'run-session-hub-bridge.ps1'

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

function Convert-VersionValue {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return [Version]'0.0.0'
  }

  try {
    return [Version]$Value
  } catch {
    $normalized = ($Value -replace '[^0-9\.]', '')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      return [Version]'0.0.0'
    }
    try {
      return [Version]$normalized
    } catch {
      return [Version]'0.0.0'
    }
  }
}

function Get-InstalledVersion {
  $versionFile = Join-Path $resolvedInstallRoot 'installed-version.txt'
  if (Test-Path $versionFile) {
    return (Get-Content -Path $versionFile -Raw).Trim()
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

function Resolve-ManifestEntry {
  param(
    [Parameter(Mandatory = $true)]$ManifestObject,
    [Parameter(Mandatory = $true)][string]$DesiredChannel
  )

  if ($ManifestObject.channels) {
    $entry = $ManifestObject.channels.$DesiredChannel
    if ($entry) {
      return $entry
    }
  }

  return $ManifestObject
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

function Update-InstalledConfigVersion {
  param([Parameter(Mandatory = $true)][string]$Version)

  $config = Read-BridgeConfig
  if ($config) {
    $config.version = $Version
    $config.updated_at = (Get-Date).ToString('o')
    Set-Content -Path $resolvedConfigPath -Value ($config | ConvertTo-Json -Depth 6) -Encoding UTF8
  }

  Set-Content -Path (Join-Path $resolvedInstallRoot 'installed-version.txt') -Value $Version -Encoding ASCII
}

function Apply-UpdateFromManifest {
  param(
    [Parameter(Mandatory = $true)]$Entry,
    [Parameter(Mandatory = $true)][string]$BaseManifestUrl
  )

  $packageUrlCandidate = if ($Entry.package_url) { [string]$Entry.package_url } elseif ($Entry.url) { [string]$Entry.url } else { $null }
  if (-not $packageUrlCandidate) {
    throw 'El manifest no contiene package_url ni url.'
  }

  $packageUrl = Resolve-DownloadUrl -BaseUrl $BaseManifestUrl -CandidateUrl $packageUrlCandidate
  $tempRoot = Join-Path $env:TEMP ("session-hub-scanner-update-" + [guid]::NewGuid().ToString('N'))
  $zipPath = Join-Path $tempRoot 'package.zip'
  $extractRoot = Join-Path $tempRoot 'extract'

  try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

    Trace-Update "Downloading update package from $packageUrl"
    Invoke-WebRequest -Uri $packageUrl -OutFile $zipPath -UseBasicParsing

    if ($Entry.sha256) {
      $actualHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
      $expectedHash = ([string]$Entry.sha256).ToLowerInvariant()
      if ($actualHash -ne $expectedHash) {
        throw "SHA256 inválido. Esperado=$expectedHash Actual=$actualHash"
      }
    }

    Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

    $packageRoot = Join-Path $extractRoot 'session-hub-scanner-bridge'
    if (-not (Test-Path $packageRoot)) {
      $dirs = Get-ChildItem -Path $extractRoot -Directory
      if ($dirs.Count -eq 1) {
        $packageRoot = $dirs[0].FullName
      } else {
        $packageRoot = $extractRoot
      }
    }

    Trace-Update "Applying update package from $packageRoot"
    Invoke-BridgeRunner -RunnerMode 'stop-tray-task'
    Invoke-BridgeRunner -RunnerMode 'stop-task'

    Get-ChildItem -Path $packageRoot -Force | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $resolvedInstallRoot -Recurse -Force
    }

    Update-InstalledConfigVersion -Version ([string]$Entry.version)
    Invoke-BridgeRunner -RunnerMode 'start-task'

    $startupLauncher = Join-Path ([Environment]::GetFolderPath('Startup')) 'SessionHubScannerBridgeTray.vbs'
    if ([Environment]::UserInteractive -and (Test-Path $startupLauncher)) {
      & wscript.exe $startupLauncher
      Trace-Update 'Tray relaunch requested via Startup launcher.'
    }

    Trace-Update "Update applied successfully. Version=$($Entry.version)"
  } finally {
    if (Test-Path $tempRoot) {
      Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-UpdateCheck {
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

  Trace-Update "Checking updates. Manifest=$ManifestUrl Channel=$Channel"
  $manifest = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing
  $entry = Resolve-ManifestEntry -ManifestObject $manifest -DesiredChannel $Channel

  if (-not $entry -or -not $entry.version) {
    throw 'El manifest no contiene una versión válida.'
  }

  $installedVersion = Get-InstalledVersion
  $current = Convert-VersionValue -Value $installedVersion
  $available = Convert-VersionValue -Value ([string]$entry.version)

  Trace-Update "Installed=$installedVersion Available=$($entry.version)"

  if ($available -le $current) {
    Write-Host "Sin actualizaciones. Instalado=$installedVersion"
    return
  }

  Write-Host "Actualización encontrada: $installedVersion -> $($entry.version)"
  Apply-UpdateFromManifest -Entry $entry -BaseManifestUrl $ManifestUrl
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
  $intervalMinutes = [Math]::Max(15, $UpdateIntervalMinutes)
  $repeatTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes $intervalMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -Hidden
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

switch ($Mode) {
  'run' {
    Invoke-UpdateCheck
  }
  'check' {
    Invoke-UpdateCheck
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
