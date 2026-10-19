param(
  [string]$SourceRoot = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$DestinationPath = 'C:\tmp\session-hub-scanner-bridge.zip',
  [string]$Version = '',
  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SourceRoot)) {
  throw "No existe SourceRoot: $SourceRoot"
}

$source = (Resolve-Path $SourceRoot).Path
# OTA: the package version is the one the updater verifies against the signed
# manifest (package-version.txt). It must equal package.json and be strict
# MAJOR.MINOR.PATCH so the updater can order versions and block downgrades.
$packageJsonVersion = [string]((Get-Content -Path (Join-Path $source 'package.json') -Raw | ConvertFrom-Json).version)
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = $packageJsonVersion
}
if ($Version -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$') {
  throw "Version invalida para OTA: $Version (usar MAJOR.MINOR.PATCH)"
}
if ($Version -ne $packageJsonVersion) {
  throw "Version $Version no coincide con package.json ($packageJsonVersion). Actualizar package.json primero."
}
$nodePath = (Get-Command node -ErrorAction Stop).Source
$outputFile = (Resolve-Path (Split-Path $DestinationPath)).Path + '\' + (Split-Path $DestinationPath -Leaf)
$packageRoot = Join-Path $env:TEMP ("session-hub-scanner-bridge-" + [guid]::NewGuid().ToString("N"))
$stagingRoot = Join-Path $packageRoot 'session-hub-scanner-bridge'
$versionFile = Join-Path $stagingRoot 'package-version.txt'

if (Test-Path $DestinationPath -PathType Leaf) {
  if (-not $Overwrite) {
    throw "El archivo destino ya existe: $DestinationPath. Usa -Overwrite para reemplazarlo."
  }
  Remove-Item $DestinationPath -Force
}

try {
  New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

  $items = @(
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
    'diagnose-session-hub-scanner.ps1',
    'diagnose-session-hub-scanner.js'
  )

  foreach ($item in $items) {
    $from = Join-Path $source $item
    if (-not (Test-Path $from)) {
      throw "Archivo obligatorio faltante en paquete: $from"
    }
    Copy-Item -Path $from -Destination $stagingRoot -Force
  }

  $nodeModules = Join-Path $source 'node_modules'
  if (-not (Test-Path $nodeModules)) {
    throw "Falta node_modules en $nodeModules. Ejecuta npm ci antes de empaquetar."
  }

  Copy-Item -Path $nodeModules -Destination $stagingRoot -Recurse -Force
  Copy-Item -Path $nodePath -Destination (Join-Path $stagingRoot 'node.exe') -Force

  [System.IO.File]::WriteAllText($versionFile, $Version, (New-Object System.Text.UTF8Encoding($false)))

  $protectedNames = @('scanner-bridge-config.json', 'installed-version.txt', 'bridge-state.json', 'update-drain.request', 'update-status.json', 'update.lock', '.ota', 'bridge.log', 'bridge.err', 'runner.log', 'tray.log', 'update.log')
  foreach ($protected in $protectedNames) {
    if (Test-Path -LiteralPath (Join-Path $stagingRoot $protected)) {
      throw "El paquete no puede contener $protected (config/estado local de la PC)."
    }
  }

  if (Test-Path (Split-Path $DestinationPath -Parent)) {
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $outputFile -Force
    Write-Host "Paquete generado: $outputFile"
    Write-Host "Version: $Version"
    return
  }

  throw "No existe ruta destino: $(Split-Path $DestinationPath -Parent)"
} finally {
  if (Test-Path $packageRoot) {
    Remove-Item $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
