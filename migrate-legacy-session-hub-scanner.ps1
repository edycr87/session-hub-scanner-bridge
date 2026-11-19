param(
  # Folder the new installer writes to (the same value passed to the installer).
  [string]$InstallRoot = "$env:ProgramData\SessionHubScannerBridge",
  # Station id of THIS PC (hostname normalized). Empty: computed here.
  [string]$StationId = '',
  # Server address given to the installer. Empty: proposed from the old folders
  # when they all agree (it is not secret). The shared secret is never read.
  [string]$BaseUrl = '',
  # -KeepHostId/-HostId of the installer: refused when it is the station name of
  # another PC found in an old folder.
  [string]$KeepHostId = '',
  [string[]]$ExtraRoots = @(),
  # Startup folders to look at. Empty: the same ones the diagnostic reads.
  [string[]]$StartupDirs = @(),
  # Where the migration folder (backup + receipt) is created. Empty: ProgramData.
  [string]$BackupParent = '',
  # Explicit consent (scripts, hidden installer window). Without it: plan, then
  # the word ARCHIVAR typed by a person, or exit 4 without touching anything.
  [switch]$ArchiveLegacy,
  # Print the plan and stop (exit 0). Changes nothing.
  [switch]$PlanOnly,
  # Undo a migration from its recibo.json (see below).
  [string]$Rollback = '',
  # Rollback only: also re-enable the tasks of a folder that belonged to ANOTHER
  # station. Reviving that name can displace the real station on the server.
  [switch]$AllowOtherStationIdentity
)

# ASSISTED MIGRATION of an earlier Session Hub Scanner installation.
#
# It NEVER deletes. It sets aside: scheduled tasks are exported to XML and
# disabled; processes are stopped only when their executable or command line
# is under an old folder (never by process name or station name); a Startup
# launcher is moved; each old folder is renamed '<name>.respaldo-YYYYMMDD'
# (never overwriting: -2, -3, ...). A recibo.json is written step by step into a
# folder only SYSTEM and Administrators can read (the task XML can hold secrets).
# The station name of an old folder is never copied to the new installation.
#
# Exit codes: 0 ok / plan; 3 not Administrator; 4 no consent (nothing touched);
# 5 refused before touching anything; 6 a step failed (see the rollback line).

$ErrorActionPreference = 'Stop'
$ReceiptSchema = 'session-hub-scanner-legacy-archive/v1'

function Assert-Administrator {
  $isAdmin = $false
  try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    $isAdmin = $false
  }
  if (-not $isAdmin) {
    Write-Host 'NOT_ADMIN: la migracion necesita permisos de Administrador. Abri PowerShell con "Ejecutar como administrador" y repeti el comando. No se toco nada.'
    exit 3
  }
}
Assert-Administrator

# Same rules as the installer and bridge.js (parity is tested).
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

# Same attribution as the diagnostic (-Root/-InstallRoot, or a folder holding one
# of the agent scripts).
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

function Get-NormPath {
  param([string]$Path)
  return ([string]$Path).Trim().Replace('/', '\').TrimEnd('\').ToLowerInvariant()
}

function Write-Utf8File {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FileSha256 {
  param([string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# Never overwrite or merge: '<name>.<tag>-YYYYMMDD', then -2, -3, ...
function Get-FreeArchiveName {
  param([string]$Path, [string]$Tag)
  $parent = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  $base = '{0}.{1}-{2}' -f $leaf, $Tag, (Get-Date).ToString('yyyyMMdd')
  $candidate = $base
  $n = 2
  while (Test-Path -LiteralPath (Join-Path $parent $candidate)) {
    $candidate = '{0}-{1}' -f $base, $n
    $n += 1
  }
  return $candidate
}

# Process attribution is by PATH only. The executable under an old folder, a
# command line that names an agent script inside it, or -Root/-InstallRoot of an
# agent host process. Never by process name, station name or --host-id: an editor
# or Explorer that merely has the folder open is not matched.
function Test-ProcessUnderRoot {
  param($Process, [string]$RootPath)
  $needle = ((Get-NormPath $RootPath) + '\')
  $exe = Get-NormPath ([string]$Process.ExecutablePath)
  if ($exe -and $exe.StartsWith($needle)) { return $true }
  $line = ([string]$Process.CommandLine).Replace('"', '').ToLowerInvariant()
  if (-not $line) { return $false }
  if ($line.StartsWith($needle)) { return $true }
  foreach ($script in @('bridge.js', 'run-session-hub-bridge.ps1', 'tray-session-hub-bridge.ps1', 'update-session-hub-scanner.ps1', 'session-hub-scanner-bridge.exe')) {
    if ($line.Contains($needle + $script)) { return $true }
  }
  $hostNames = @('powershell.exe', 'pwsh.exe', 'node.exe', 'wscript.exe', 'cscript.exe')
  if ($hostNames -contains ([string]$Process.Name).ToLowerInvariant()) {
    $rootToken = (Get-NormPath $RootPath)
    if ($line -match ('(?:^|\s)-(?:root|installroot)\s+' + [regex]::Escape($rootToken) + '(?:\\)?(?:\s|$)')) { return $true }
  }
  return $false
}

function Get-ProcessesUnderRoots {
  param([string[]]$Roots)
  $found = @()
  foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    if ([int]$proc.ProcessId -eq $PID) { continue }
    foreach ($rootPath in $Roots) {
      if (Test-ProcessUnderRoot -Process $proc -RootPath $rootPath) {
        $found += [pscustomobject]@{ Pid = [int]$proc.ProcessId; Exe = [string]$proc.ExecutablePath; Root = $rootPath }
        break
      }
    }
  }
  return $found
}

function Stop-ProcessesUnderRoots {
  param([string[]]$Roots, $Receipt)
  $targets = @(Get-ProcessesUnderRoots -Roots $Roots)
  foreach ($item in $targets) {
    $entry = [ordered]@{ pid = $item.Pid; exe = $item.Exe; root = $item.Root; stopped = $false }
    try {
      Stop-Process -Id $item.Pid -Force -ErrorAction Stop
      Wait-Process -Id $item.Pid -Timeout 10 -ErrorAction SilentlyContinue
    } catch {
      # it may have exited by itself; verified below
    }
    $entry.stopped = -not (Get-Process -Id $item.Pid -ErrorAction SilentlyContinue)
    if ($null -ne $Receipt) { $Receipt.processes += $entry }
  }
  return @(Get-ProcessesUnderRoots -Roots $Roots)
}

function Get-DefaultStartupDirs {
  $dirs = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
  foreach ($profileStartup in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' })) { $dirs += $profileStartup }
  return @($dirs | Where-Object { $_ } | Select-Object -Unique)
}

# 'move' when the launcher starts an old folder (or something outside every known
# folder), 'keep' otherwise. No recognizable path at all: kept and reported.
function Get-LauncherDecision {
  param([string]$Content, [string]$Target, [bool]$TargetArchived)
  $text = $Content.Replace('""', '"')
  $hint = Get-RootHint -Text $text
  if ($hint) {
    if ((Get-NormPath $hint) -ne (Get-NormPath $Target) -or $TargetArchived) { return @{ Action = 'move'; Reason = 'root' } }
    return @{ Action = 'keep'; Reason = 'target' }
  }
  if ($text -match '[A-Za-z]:\\') {
    $needle = ((Get-NormPath $Target) + '\')
    if ($text.ToLowerInvariant().Replace('"', '').Contains($needle) -and -not $TargetArchived) { return @{ Action = 'keep'; Reason = 'target' } }
    return @{ Action = 'move'; Reason = 'outside-known-roots' }
  }
  return @{ Action = 'keep'; Reason = 'unattributable' }
}

function Get-SafeFileName {
  param([string]$Name)
  return ([regex]::Replace($Name, '[^A-Za-z0-9_.-]+', '_'))
}

function Save-Receipt {
  param($Receipt, [string]$Path)
  Write-Utf8File -Path $Path -Text ($Receipt | ConvertTo-Json -Depth 8)
}

function Add-Step {
  param($Receipt, [string]$Path, [int]$N, [string]$Intent)
  $step = [ordered]@{ n = $N; intent = $Intent; status = 'intent'; error = $null }
  $Receipt.steps += $step
  Save-Receipt -Receipt $Receipt -Path $Path
  return $step
}

function Complete-Step {
  param($Receipt, [string]$Path, $Step, [string]$ErrorText)
  if ($ErrorText) { $Step.status = 'error'; $Step.error = $ErrorText } else { $Step.status = 'done' }
  Save-Receipt -Receipt $Receipt -Path $Path
}

function Protect-MigrationFolder {
  param([string]$Path)
  # Well-known SIDs (SYSTEM, Administrators), inherited by what is created inside.
  & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "No se pudo restringir el acceso a la carpeta de respaldo (icacls codigo $LASTEXITCODE). Se detiene: los XML de tareas pueden traer secretos."
  }
}

function Get-NodePath {
  $node = Join-Path $PSScriptRoot 'node.exe'
  if (-not (Test-Path -LiteralPath $node)) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
  return $node
}

# Collects with the read-only diagnostic and decides with the same evaluator the
# installer trusts (the plan is a pure function of the redacted facts).
function Get-MigrationPlan {
  param([string]$Target, [string]$Station)
  $diagnostic = Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.ps1'
  $evaluator = Join-Path $PSScriptRoot 'diagnose-session-hub-scanner.js'
  $node = Get-NodePath
  if (-not (Test-Path -LiteralPath $diagnostic) -or -not (Test-Path -LiteralPath $evaluator) -or -not $node) {
    throw 'Falta el diagnostico (diagnose-session-hub-scanner.ps1/.js) o node.exe en el paquete; no se migra (falla cerrado).'
  }
  $factsFile = Join-Path ([System.IO.Path]::GetTempPath()) ('session-hub-migration-facts-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    $collectArgs = @{ Context = 'report'; TargetInstallRoot = $Target; FactsOnlyPath = $factsFile }
    if (@($ExtraRoots).Count -gt 0) { $collectArgs.ExtraRoots = $ExtraRoots }
    & $diagnostic @collectArgs | Out-Null
    $json = & $node $evaluator '--facts' $factsFile '--migration-plan' $Station
    if ($LASTEXITCODE -ne 0) { throw "El evaluador fallo (codigo $LASTEXITCODE)." }
    return (($json -join "`n") | ConvertFrom-Json)
  } finally {
    try { [System.IO.File]::Delete($factsFile) } catch { }
  }
}

function Exit-WithResult {
  param([int]$Code, $Result)
  if ($Result) { Write-Output $Result }
  exit $Code
}

# ---------------------------------------------------------------- ROLLBACK ---
if ($Rollback) {
  if (-not (Test-Path -LiteralPath $Rollback -PathType Leaf)) { Write-Host "No existe el recibo: $Rollback"; exit 5 }
  $receipt = (([System.IO.File]::ReadAllText($Rollback)).TrimStart([char]0xFEFF)) | ConvertFrom-Json
  if ($receipt.schema -ne $ReceiptSchema) { Write-Host "El recibo no tiene el formato esperado ($ReceiptSchema)."; exit 5 }
  $backupDir = Split-Path -Parent (Resolve-Path -LiteralPath $Rollback).Path
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
  $log = New-Object System.Collections.Generic.List[string]
  $failed = $false

  # Refuse before touching anything: every archived folder must be where the receipt says.
  foreach ($root in @($receipt.roots)) {
    if (-not $root.archived_to) { continue }
    if (-not (Test-Path -LiteralPath $root.archived_to)) { Write-Host "No se encuentra la carpeta archivada: $($root.archived_to). No se deshace nada."; exit 5 }
  }

  try {
    # 1. A new installation in an original folder is set aside first (exported, stopped, renamed), never deleted.
    $newDir = Join-Path $backupDir 'nuevo'
    foreach ($root in @($receipt.roots)) {
      if (-not $root.archived_to -or -not (Test-Path -LiteralPath $root.original)) { continue }
      Write-Host "Hay algo en $($root.original) (instalacion nueva): se aparta antes de volver."
      if (-not (Test-Path -LiteralPath $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
      $needle = (Get-NormPath $root.original)
      $i = 0
      foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'SessionHubScanner*' })) {
        $actionText = (@($task.Actions | ForEach-Object { [string]$_.Arguments + ' ' + [string]$_.Execute }) -join ' ').Replace('"', '').ToLowerInvariant()
        if (-not $actionText.Contains($needle)) { continue }
        $i += 1
        $xml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
        [System.IO.File]::WriteAllText((Join-Path $newDir ('{0}-{1}.xml' -f $i, (Get-SafeFileName $task.TaskName))), $xml, [System.Text.Encoding]::Unicode)
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
        Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        $log.Add("Tarea nueva exportada y desactivada: $($task.TaskName)")
      }
      $still = @(Stop-ProcessesUnderRoots -Roots @($root.original) -Receipt $null)
      if ($still.Count -gt 0) { throw "Sigue en marcha un programa de la instalacion nueva ($($still[0].Pid)). No se renombra nada." }
      foreach ($dir in (Get-DefaultStartupDirs) + @($StartupDirs)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter 'SessionHubScanner*' -ErrorAction SilentlyContinue)) {
          $hint = Get-RootHint -Text ([System.IO.File]::ReadAllText($file.FullName).Replace('""', '"'))
          if ($hint -and (Get-NormPath $hint) -eq $needle) {
            $dest = Join-Path (Join-Path $newDir 'startup') ('{0}-{1}' -f $stamp, $file.Name)
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Move-Item -LiteralPath $file.FullName -Destination $dest
            $log.Add("Acceso de inicio nuevo movido a $dest")
          }
        }
      }
      $newName = Get-FreeArchiveName -Path $root.original -Tag 'nuevo'
      Rename-Item -LiteralPath $root.original -NewName $newName
      $log.Add("Instalacion nueva renombrada a $(Join-Path (Split-Path -Parent $root.original) $newName)")
    }

    # 2. Archived folders go back to their original names (never over something that exists).
    foreach ($root in @($receipt.roots)) {
      if (-not $root.archived_to) { continue }
      if (Test-Path -LiteralPath $root.original) { throw "Todavia existe $($root.original); no se pisa. Renombrela o muevala y repita." }
      Rename-Item -LiteralPath $root.archived_to -NewName (Split-Path -Leaf $root.original)
      $log.Add("Carpeta restaurada: $($root.original)")
    }

    # 3. Tasks come back from the saved XML (-Force replaces a task of the same name); NOTHING is started.
    foreach ($task in @($receipt.tasks)) {
      if (-not $task.xml) { continue }
      $xmlPath = Join-Path $backupDir $task.xml
      if (-not (Test-Path -LiteralPath $xmlPath)) { throw "Falta el XML de la tarea $($task.name): $xmlPath" }
      Register-ScheduledTask -TaskName $task.name -TaskPath $task.path -Xml ([System.IO.File]::ReadAllText($xmlPath)) -Force | Out-Null
      $keepDisabled = ([string]$task.state_before -eq 'Disabled') -or ($task.other_station -eq $true -and -not $AllowOtherStationIdentity)
      if ($keepDisabled) {
        Disable-ScheduledTask -TaskName $task.name -TaskPath $task.path | Out-Null
        if ($task.other_station -eq $true -and -not $AllowOtherStationIdentity) {
          $log.Add("Tarea restaurada y DESACTIVADA (pertenece a otro puesto): $($task.name)")
        } else {
          $log.Add("Tarea restaurada (estaba desactivada): $($task.name)")
        }
      } else {
        $log.Add("Tarea restaurada: $($task.name)")
      }
    }

    # 4. Startup launchers go back to where they were.
    foreach ($item in @($receipt.startup)) {
      if (-not $item.to -or -not (Test-Path -LiteralPath $item.to)) { continue }
      if (Test-Path -LiteralPath $item.from) { throw "Ya existe $($item.from); no se pisa. Muevalo y repita." }
      Move-Item -LiteralPath $item.to -Destination $item.from
      $log.Add("Acceso de inicio restaurado: $($item.from)")
    }
  } catch {
    $failed = $true
    $log.Add("ERROR: $($_.Exception.Message)")
  }

  foreach ($line in $log) { Write-Host $line }
  # Appended to the receipt so the rollback leaves its own trace.
  try {
    $text = [System.IO.File]::ReadAllText($Rollback)
    $obj = ($text.TrimStart([char]0xFEFF)) | ConvertFrom-Json
    $entry = [ordered]@{ at_utc = (Get-Date).ToUniversalTime().ToString('o'); failed = $failed; allow_other_station_identity = [bool]$AllowOtherStationIdentity; log = @($log) }
    $existing = @()
    if ($obj.PSObject.Properties['rollbacks']) { $existing = @($obj.rollbacks) }
    $obj | Add-Member -NotePropertyName rollbacks -NotePropertyValue (@($existing) + @([pscustomobject]$entry)) -Force
    Write-Utf8File -Path $Rollback -Text ($obj | ConvertTo-Json -Depth 8)
  } catch {
    Write-Host "No se pudo anotar el rollback en el recibo: $($_.Exception.Message)"
  }
  if ($failed) { Write-Host 'El rollback se detuvo. Lo hecho esta arriba; no se borro nada.'; exit 6 }
  Write-Host 'Rollback terminado. NO se arranco nada. Para arrancar un agente restaurado: .\run-session-hub-bridge.ps1 -Mode start-task -Root <carpeta>'
  Write-Host 'Las tareas de una carpeta con nombre de OTRO puesto quedaron desactivadas a proposito.'
  exit 0
}

# --------------------------------------------------------------- MIGRATION ---
if ([string]::IsNullOrWhiteSpace($StationId)) { $StationId = ConvertTo-StationId -Name (Get-StationName) }
if ([string]::IsNullOrWhiteSpace($StationId)) { Write-Host 'No se pudo derivar el nombre del puesto del hostname; no se migra.'; exit 5 }

$plan = Get-MigrationPlan -Target $InstallRoot -Station $StationId
$planRoots = @($plan.roots)
$planTasks = @($plan.tasks)
$oldRootPaths = @($planRoots | ForEach-Object { [string]$_.path })
$targetArchived = [bool]$plan.target_archived

# The package must not live inside a folder about to be renamed.
foreach ($rootPath in $oldRootPaths) {
  if (((Get-NormPath $PSScriptRoot) + '\').StartsWith((Get-NormPath $rootPath) + '\')) {
    Write-Host "Este paquete esta dentro de una carpeta que se archivaria ($rootPath). Copielo a otra carpeta y repita. No se toco nada."
    exit 5
  }
}

$liveProcesses = @(Get-ProcessesUnderRoots -Roots $oldRootPaths)
$startupList = @()
if ($oldRootPaths.Count -gt 0 -or $planTasks.Count -gt 0) {
  $dirs = if (@($StartupDirs).Count -gt 0) { @($StartupDirs) } else { Get-DefaultStartupDirs }
  foreach ($dir in $dirs) {
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter 'SessionHubScanner*' -ErrorAction SilentlyContinue)) {
      $decision = Get-LauncherDecision -Content ([System.IO.File]::ReadAllText($file.FullName)) -Target $InstallRoot -TargetArchived $targetArchived
      $startupList += [pscustomobject]@{ Path = $file.FullName; Action = $decision.Action; Reason = $decision.Reason }
    }
  }
}
$startupMove = @($startupList | Where-Object { $_.Action -eq 'move' })

Write-Host ''
Write-Host '=== Migracion de una instalacion anterior del lector ==='
if ($planRoots.Count -eq 0 -and $planTasks.Count -eq 0 -and $liveProcesses.Count -eq 0 -and $startupMove.Count -eq 0) {
  if (@($plan.blockers_other).Count -gt 0 -or @($plan.unattributed).Count -gt 0) {
    foreach ($item in @($plan.blockers_other)) { Write-Host ("  NO SE PUEDE ARCHIVAR: {0} {1}" -f $item.code, $item.detail) }
    foreach ($item in @($plan.unattributed)) { Write-Host ("  NO SE PUEDE ATRIBUIR A UNA CARPETA: {0} {1}{2}" -f $item.kind, $item.name, $item.pid) }
    Write-Host 'No se toco nada.'
    exit 5
  }
  Write-Host 'No encontre una instalacion anterior para archivar. No se toco nada.'
  Exit-WithResult -Code 0 -Result ([pscustomobject]@{ Archived = 0; Receipt = ''; BaseUrl = ''; ForeignHostIds = @() })
}

Write-Host 'Encontre una instalacion anterior del lector en esta PC:'
foreach ($root in $planRoots) {
  $versions = if (@($root.versions).Count -gt 0) { (@($root.versions) -join ' / ') } else { 'sin version' }
  $source = if ($root.source) { "origen verificado: $($root.source)" } else { 'sin origen verificable' }
  $station = if ($root.host_id) { ", nombre de puesto '$($root.host_id)'" } else { '' }
  Write-Host ("  - carpeta {0} (version {1}; {2}{3})" -f $root.path, $versions, $source, $station)
  if ($root.other_station) {
    Write-Host ("    ATENCION: el nombre de puesto '{0}' no es el de esta PC ('{1}'). No se va a usar." -f $root.host_id, $StationId)
  }
}
foreach ($task in $planTasks) { Write-Host ("  - tarea programada {0} (estado: {1})" -f $task.name, $task.state) }
foreach ($proc in $liveProcesses) { Write-Host ("  - programa en marcha PID {0} que corre desde {1}" -f $proc.Pid, $proc.Root) }
foreach ($item in $startupMove) { Write-Host ("  - acceso de inicio {0} ({1})" -f $item.Path, $item.Reason) }
foreach ($item in @($startupList | Where-Object { $_.Action -ne 'move' -and $_.Reason -eq 'unattributable' })) {
  Write-Host ("  (aviso) no se pudo atribuir a ninguna carpeta y NO se mueve: {0}" -f $item.Path)
}
Write-Host 'Voy a: guardar copia de las tareas, desactivarlas, detener esos programas, mover el acceso de inicio y renombrar las carpetas con "respaldo-FECHA". No borro nada.'

# Refusals: nothing has been touched yet.
$refused = $false
foreach ($item in @($plan.blockers_other)) { Write-Host ("NO SE PUEDE ARCHIVAR: {0} {1}" -f $item.code, $item.detail); $refused = $true }
foreach ($item in @($plan.unattributed)) { Write-Host ("NO SE PUEDE ATRIBUIR A UNA CARPETA (no se adivina): {0} {1}{2}" -f $item.kind, $item.name, $item.pid); $refused = $true }
foreach ($item in @($plan.refusals)) { Write-Host ("NO SE PUEDE: {0} {1}" -f $item.code, $item.detail); $refused = $true }
if (-not [string]::IsNullOrWhiteSpace($KeepHostId)) {
  foreach ($foreign in @($plan.foreign_host_ids)) {
    if ($foreign.ToLowerInvariant() -eq $KeepHostId.Trim().ToLowerInvariant()) {
      Write-Host "El nombre '$KeepHostId' pertenece a otro puesto segun la carpeta vieja; no se reutiliza. Quite -KeepHostId/-HostId."
      $refused = $true
    }
  }
}
$proposedBaseUrl = ''
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  $urls = @($plan.base_urls)
  if ($urls.Count -eq 1) { $proposedBaseUrl = [string]$urls[0]; Write-Host "Direccion del servidor que usaba la instalacion anterior (no es secreta): $proposedBaseUrl" }
  elseif ($urls.Count -gt 1) { Write-Host ("Las carpetas viejas tienen direcciones distintas: {0}. Indique cual con -BaseUrl." -f ($urls -join ', ')); $refused = $true }
}
if ($refused) { Write-Host 'No se toco nada.'; exit 5 }

if ($PlanOnly) {
  Write-Host 'Solo plan (-PlanOnly): no se cambio nada.'
  Exit-WithResult -Code 0 -Result ([pscustomobject]@{ Archived = 0; Receipt = ''; BaseUrl = $proposedBaseUrl; ForeignHostIds = @($plan.foreign_host_ids) })
}

$mode = 'flag'
if (-not $ArchiveLegacy) {
  $mode = 'confirm'
  $interactive = $false
  try { $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { $interactive = $false }
  if (-not $interactive) {
    Write-Host 'Falta confirmacion: repita con -ArchiveLegacy para aceptar el plan. No se toco nada.'
    exit 4
  }
  $answer = Read-Host 'Escriba ARCHIVAR (en mayusculas) para continuar; cualquier otra cosa cancela'
  if ($answer -cne 'ARCHIVAR') { Write-Host 'Cancelado. No se toco nada.'; exit 4 }
}

# 1. Migration folder outside every root, restricted ACL, BEFORE anything else.
if ([string]::IsNullOrWhiteSpace($BackupParent)) { $BackupParent = $env:ProgramData }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss')
$backupDir = Join-Path $BackupParent ('SessionHubScannerBridge.migracion-' + $stamp)
$suffix = 2
while (Test-Path -LiteralPath $backupDir) { $backupDir = Join-Path $BackupParent ('SessionHubScannerBridge.migracion-{0}-{1}' -f $stamp, $suffix); $suffix += 1 }
foreach ($rootPath in $oldRootPaths) {
  if ((Get-NormPath $backupDir).StartsWith((Get-NormPath $rootPath) + '\')) { Write-Host 'La carpeta de respaldo quedaria dentro de una carpeta a archivar; use -BackupParent. No se toco nada.'; exit 5 }
}
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Protect-MigrationFolder -Path $backupDir
$receiptPath = Join-Path $backupDir 'recibo.json'
$packageVersion = ''
try { $packageVersion = [string]((([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'package.json'))).TrimStart([char]0xFEFF) | ConvertFrom-Json).version) } catch { $packageVersion = '' }

$receipt = [ordered]@{
  schema = $ReceiptSchema
  created_utc = (Get-Date).ToUniversalTime().ToString('o')
  computer_name = (Get-StationName)
  package_version = $packageVersion
  admin = $true
  mode = $mode
  station_id = $StationId
  roots = @()
  tasks = @()
  processes = @()
  startup = @()
  steps = @()
}
foreach ($root in $planRoots) {
  $receipt.roots += [ordered]@{
    original = [string]$root.path
    archived_to = $null
    bridge_sha256 = $root.bridge_sha256
    versions = @($root.versions)
    host_id = [string]$root.host_id
    other_station = [bool]$root.other_station
    base_url = [string]$root.base_url
  }
}
Save-Receipt -Receipt $receipt -Path $receiptPath
Write-Host "Carpeta de migracion (acceso restringido): $backupDir"

$rollbackLine = ".\migrate-legacy-session-hub-scanner.ps1 -Rollback `"$receiptPath`""
$current = $null
try {
  # 2. Export every task BEFORE touching it (the XML may hold secrets: restricted folder).
  $step = Add-Step -Receipt $receipt -Path $receiptPath -N 2 -Intent 'exportar tareas a XML'
  $tasksDir = Join-Path $backupDir 'tareas'
  if ($planTasks.Count -gt 0) { New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null }
  $index = 0
  foreach ($task in $planTasks) {
    $index += 1
    $xmlName = 'tareas\{0}-{1}.xml' -f $index, (Get-SafeFileName ([string]$task.name))
    $xml = Export-ScheduledTask -TaskName $task.name -TaskPath $task.path
    [System.IO.File]::WriteAllText((Join-Path $backupDir $xmlName), $xml, [System.Text.Encoding]::Unicode)
    $receipt.tasks += [ordered]@{ name = [string]$task.name; path = [string]$task.path; state_before = [string]$task.state; root_hint = [string]$task.root_hint; other_station = [bool]$task.other_station; xml = $xmlName }
  }
  Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $null

  # 3. Disable first, then stop: a disabled task cannot revive the process.
  $step = Add-Step -Receipt $receipt -Path $receiptPath -N 3 -Intent 'desactivar y detener tareas'
  foreach ($task in $planTasks) {
    Disable-ScheduledTask -TaskName $task.name -TaskPath $task.path | Out-Null
    try { Stop-ScheduledTask -TaskName $task.name -TaskPath $task.path -ErrorAction Stop } catch { }
  }
  Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $null

  # 4. Stop processes living under an old folder, by path only; renaming waits for them to be gone.
  $step = Add-Step -Receipt $receipt -Path $receiptPath -N 4 -Intent 'detener programas de carpetas viejas (por ruta)'
  $remaining = @(Stop-ProcessesUnderRoots -Roots $oldRootPaths -Receipt $receipt)
  if ($remaining.Count -gt 0) {
    throw ("Sigue en marcha el programa PID {0} ({1}). No se renombra ninguna carpeta." -f $remaining[0].Pid, $remaining[0].Root)
  }
  Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $null

  # 5. Move (never copy or delete) the old Startup launchers.
  $step = Add-Step -Receipt $receipt -Path $receiptPath -N 5 -Intent 'mover accesos de inicio'
  $startupDir = Join-Path $backupDir 'startup'
  $k = 0
  foreach ($item in $startupMove) {
    $k += 1
    if (-not (Test-Path -LiteralPath $item.Path)) { continue }
    New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
    $hash = Get-FileSha256 -Path $item.Path
    $dest = Join-Path $startupDir ('{0}-{1}' -f $k, (Split-Path -Leaf $item.Path))
    Move-Item -LiteralPath $item.Path -Destination $dest
    $receipt.startup += [ordered]@{ from = $item.Path; to = $dest; sha256 = $hash; reason = $item.Reason }
  }
  Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $null

  # 6. Rename the folders (no -Force, never over an existing name).
  $step = Add-Step -Receipt $receipt -Path $receiptPath -N 6 -Intent 'renombrar carpetas viejas'
  foreach ($entry in $receipt.roots) {
    if (-not (Test-Path -LiteralPath $entry.original)) { continue }
    $newName = Get-FreeArchiveName -Path $entry.original -Tag 'respaldo'
    Rename-Item -LiteralPath $entry.original -NewName $newName
    $entry.archived_to = Join-Path (Split-Path -Parent $entry.original) $newName
    Save-Receipt -Receipt $receipt -Path $receiptPath
    Write-Host ("Carpeta archivada: {0} -> {1}" -f $entry.original, $entry.archived_to)
  }
  Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $null
} catch {
  $message = $_.Exception.Message
  if ($null -ne $step) { Complete-Step -Receipt $receipt -Path $receiptPath -Step $step -ErrorText $message }
  Write-Host "ERROR en la migracion: $message"
  Write-Host "Recibo (lo que se hizo hasta aca): $receiptPath"
  Write-Host "Para volver atras: $rollbackLine"
  exit 6
}

$final = Add-Step -Receipt $receipt -Path $receiptPath -N 7 -Intent 'recibo final'
Complete-Step -Receipt $receipt -Path $receiptPath -Step $final -ErrorText $null
Write-Host ''
Write-Host "Migracion terminada. Recibo: $receiptPath"
Write-Host "Para volver atras: $rollbackLine"
Exit-WithResult -Code 0 -Result ([pscustomobject]@{ Archived = @($receipt.roots | Where-Object { $_.archived_to }).Count; Receipt = $receiptPath; BaseUrl = $proposedBaseUrl; ForeignHostIds = @($plan.foreign_host_ids) })
