param(
  [string]$Root = 'C:\gestor_produccion\backend\tools\session-hub-scanner-bridge'
)

$ErrorActionPreference = 'Stop'

$node = (Get-Command node -ErrorAction Stop).Source
$bridgeRoot = (Resolve-Path $Root).Path
$script = Join-Path $bridgeRoot 'readers-list.js'

$js = @'
const serial = require('serialport');

(async () => {
  try {
    const ports = await serial.list();
    const items = (ports || []).map((port) => {
      const candidate = port || {};
      const path = candidate.path || candidate.comName || '';
      const manufacturer = candidate.manufacturer || '';
      const serialNumber = candidate.serialNumber || '';
      const pnpId = candidate.pnpId || '';
      const vendorId = candidate.vendorId || '';
      const productId = candidate.productId || '';
      const deviceId = [serialNumber, pnpId, `${vendorId}:${productId}`]
        .filter((value) => value && `${value}`.trim())
        .map((value) => `${value}`.trim())
        .find(Boolean) || path;

      return {
        path,
        manufacturer,
        serial_number: serialNumber,
        pnp_id: pnpId,
        usb_id: `${vendorId}:${productId}`.replace(/^:|:$/g, ''),
        device_id: deviceId,
        description: candidate.friendlyName || candidate.description || ''
      };
    }).filter((item) => item.path);

    console.log(JSON.stringify({ items }, null, 2));
  } catch (err) {
    console.error(err && err.message ? err.message : String(err));
    process.exit(1);
  }
})();
'@

try {
  Set-Content -Path $script -Value $js -Encoding UTF8
  $json = & $node $script | Out-String
  $data = $json | ConvertFrom-Json
  if (-not $data -or -not $data.items) {
    throw "No se pudo obtener items seriales."
  }

  if ($data.items.Count -eq 0) {
    Write-Host 'No se detectaron puertos seriales.'
    return
  }

  Write-Host 'Lectores serial detectados:'
  $index = 1
  foreach ($item in $data.items) {
    $desc = $item.description
    if (-not $desc) { $desc = '(sin descripcion)' }
    Write-Host ("  [{0}] {1}" -f $index, $item.path)
    Write-Host ("      device_id: {0}" -f $item.device_id)
    Write-Host ("      usb_id: {0} | serial_number: {1} | pnp_id: {2}" -f $item.usb_id, $item.serial_number, $item.pnp_id)
    Write-Host ("      description: {0}" -f $desc)
    $index += 1
  }
} finally {
  if (Test-Path $script) {
    Remove-Item $script -Force -ErrorAction SilentlyContinue
  }
}
