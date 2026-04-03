param(
  [string]$SourceRoot = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge',
  [string]$OutputDir = 'C:\tmp\SessionHubScannerBridgeInstaller',
  [string]$InstallerExeName = 'SessionHubScannerBridgeInstaller.exe',
  [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SourceRoot)) {
  throw "No existe SourceRoot: $SourceRoot"
}

$source = (Resolve-Path $SourceRoot).Path
$nodePath = (Get-Command node -ErrorAction Stop).Source
$root = New-Item -ItemType Directory -Path $OutputDir -Force | Select-Object -ExpandProperty FullName
$payload = Join-Path $root 'payload'
if (Test-Path $payload) {
  Remove-Item $payload -Recurse -Force
}
New-Item -ItemType Directory -Path $payload | Out-Null

$installerExe = Join-Path $root $InstallerExeName

if (Test-Path $installerExe) {
  if (-not $Overwrite) {
    throw "El archivo destino ya existe: $installerExe. Use -Overwrite."
  }
  Remove-Item $installerExe -Force
}

Copy-Item -Path (Join-Path $source 'install-session-hub-scanner.ps1') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'run-session-hub-bridge.ps1') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'update-session-hub-scanner.ps1') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'discover-session-hub-readers.ps1') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'README.md') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'tray-session-hub-bridge.ps1') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'package.json') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'package-lock.json') -Destination $payload -Force
Copy-Item -Path (Join-Path $source 'bridge.js') -Destination $payload -Force
Copy-Item -Path $nodePath -Destination (Join-Path $payload 'node.exe') -Force

$nodeModules = Join-Path $source 'node_modules'
if (-not (Test-Path $nodeModules)) {
  throw "Falta node_modules en $nodeModules. Ejecuta npm ci antes de construir el instalador."
}
Copy-Item -Path $nodeModules -Destination $payload -Recurse -Force

$packageVersion = (Get-Content -Path (Join-Path $source 'package.json') -Raw | ConvertFrom-Json).version
Set-Content -Path (Join-Path $payload 'package-version.txt') -Value $packageVersion -Encoding ASCII

$launcher = Join-Path $source 'installer-launcher.js'
Copy-Item -Path $launcher -Destination $payload -Force

Write-Host "Empaquetando installer.exe..."
npx --yes pkg (Join-Path $source 'installer-launcher.js') --targets node18-win-x64 --output $installerExe
if (-not (Test-Path $installerExe)) {
  throw "No se pudo generar $installerExe"
}

Write-Host "Instalador generado:"
Write-Host ("  Ejecutable: {0}" -f $installerExe)
Write-Host ("  Payload  : {0}" -f $payload)
Write-Host ("  Version  : {0}" -f $packageVersion)
Write-Host "Uso sugerido:"
Write-Host "  $installerExe --host-id sucursal-1-caja-1 --serial-port COM6 --display-name 'Scanner Caja 1' --base-url https://devapp.dimensioncomercial.com.ar --manifest-url https://tu-servidor/scanner-host/manifest.json"
