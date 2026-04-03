[CmdletBinding()]
param(
  [string]$HostId = 'sucursal-1-caja-1',
  [string]$DisplayName = 'Scanner Caja 1',
  [string]$BaseUrl = 'https://devapp.dimensioncomercial.com.ar',
  [int]$Baud = 9600,
  [int]$PollSeconds = 1,
  [int]$TimeoutSeconds = 300
)

$root = (Get-Location).Path
$out = Join-Path $root 'bridge.log'
$err = Join-Path $root 'bridge.err'

function Get-SerialPorts() {
  Get-CimInstance Win32_SerialPort | Select-Object DeviceID,Name,Manufacturer,PNPDeviceID | ForEach-Object {
    [PSCustomObject]@{
      Path = $_.DeviceID
      Name = $_.Name
      Manufacturer = $_.Manufacturer
      PnpId = $_.PNPDeviceID
      IsBluetooth = ($_.PNPDeviceID -match 'BTHENUM' -or $_.Name -match 'Bluetooth' -or $_.Manufacturer -match 'Bluetooth')
    }
  }
}

function Format-PortList($ports) {
  $i = 1
  foreach ($p in $ports) {
    $flag = if ($p.IsBluetooth) { '[BT]' } else { '[USB]' }
    Write-Host ("  {0}) {1} {2} {3}" -f $i, $flag, $p.Path, $p.Name)
    $i += 1
  }
}

function Select-Port($ports) {
  while ($true) {
    if (-not $ports -or $ports.Count -eq 0) {
      return $null
    }

    if ($ports.Count -eq 1) {
      return $ports[0].Path
    }

    Format-PortList $ports
    $answer = Read-Host 'Ingresá número (1..n) o vacío para cancelar'
    if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
    $n = 0
    if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $ports.Count) {
      return $ports[$n - 1].Path
    }
    Write-Host 'Selección inválida.' -ForegroundColor Yellow
  }
}

$base = Get-SerialPorts
Write-Host '=== Listener de puertos serial (esperando lector) ==='
Write-Host ("Antes: {0} puertos visibles" -f $base.Count)
Format-PortList $base
Write-Host ''
Write-Host 'Conectá el lector ahora. Presioná Ctrl+C para cancelar.'

$start = Get-Date
$deadline = $start.AddSeconds($TimeoutSeconds)
$selectedPort = $null

while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds $PollSeconds
  $current = Get-SerialPorts

  $added = @()
  foreach ($port in $current) {
    if (-not ($base.Path -contains $port.Path)) {
      $added += $port
    }
  }

  if ($added.Count -gt 0) {
    $usbPorts = $added | Where-Object { -not $_.IsBluetooth }
    if ($usbPorts.Count -gt 0) {
      Write-Host "\nDetectado(s) puerto(s) nuevos no-BT:" -ForegroundColor Green
      Format-PortList $usbPorts
      $selectedPort = Select-Port $usbPorts
    } else {
      Write-Host "\nDetectado(s) puerto(s) nuevos pero solo Bluetooth:" -ForegroundColor Yellow
      Format-PortList $added
      $answer = Read-Host '¿Querés usar uno de estos? (y/N)'
      if ($answer -match '^(?i)y(es)?$') {
        $selectedPort = Select-Port $added
      } else {
        $selectedPort = $null
      }
    }

    if ($selectedPort) {
      break
    }
  }
}

if (-not $selectedPort) {
  Write-Host 'No apareció puerto serial utilizable en el tiempo esperado.' -ForegroundColor Red
  exit 1
}

Write-Host ("Usando puerto {0}" -f $selectedPort) -ForegroundColor Cyan

$env:SESSION_HUB_BASE_URL = $BaseUrl
$env:SESSION_HUB_SCANNER_HOST_ID = $HostId
$env:SESSION_HUB_SCANNER_DISPLAY_NAME = $DisplayName
$env:SESSION_HUB_SCANNER_INPUT_MODE = 'serial'
$env:SESSION_HUB_SCANNER_SERIAL_PORT = $selectedPort
$env:SESSION_HUB_SCANNER_SERIAL_BAUD_RATE = "$Baud"
$env:SESSION_HUB_SCANNER_SERIAL_INTERACTIVE = '0'
$env:SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN = '0'
$env:SESSION_HUB_SCANNER_SERIAL_WAIT_MS = '2000'

Write-Host "\nArrancando bridge. Verificá logs en $out y $err"
Write-Host 'Ctrl+C para detener.'
node bridge.js 2>&1 | Tee-Object -Append -FilePath $out

