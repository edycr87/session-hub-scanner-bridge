# Session Hub Scanner Bridge (Windows Host-Owned)

Objetivo:
- Mantener el bridge WS canónico.
- Leer scanners USB por COM de forma estable en modo daemon.
- Registrar claim/product con trazabilidad suficiente.
- Atar cada lector por ID para evitar choques entre múltiples dispositivos.
- Distribuir runtime self-contained y permitir auto-update desde un manifest central.

Canonical:
- `C:\gestor_produccion\backend\tools\session-hub-scanner-bridge`
- WS: `wss://devapp.dimensioncomercial.com.ar/session-hub/scanner`

## Requisitos

Para ejecutar en una PC cliente instalada:
- no hace falta Node.js del sistema si el paquete fue generado con runtime portable.

Para construir paquete o instalador desde el repositorio:
- Node.js 18+ en Windows
- dependencias resueltas en la carpeta canónica

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
npm ci
```

## Variables y parámetros soportados

- `SESSION_HUB_BASE_URL` / `--base-url`
- `SESSION_HUB_SCANNER_HOST_ID` / `--host-id`
- `SESSION_HUB_SCANNER_DISPLAY_NAME` / `--display-name`
- `SESSION_HUB_SCANNER_INPUT_MODE` / `--input-mode` (`serial` o `stdin`, default `stdin`)
- `SESSION_HUB_SCANNER_SERIAL_PORT` / `--serial-port`
- `SESSION_HUB_SCANNER_SERIAL_BAUD_RATE` / `--serial-baud-rate`
- `SESSION_HUB_SCANNER_SERIAL_WAIT_MS` / `--serial-wait-ms`
- `SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN` / `--serial-fallback`
- `SESSION_HUB_SCANNER_SERIAL_INTERACTIVE` / `--serial-interactive`
- `SESSION_HUB_SCANNER_DEVICE_ID` / `--scanner-device-id` / `--reader-id`
- `SESSION_HUB_SCANNER_HEARTBEAT_MS` / `--heartbeat-ms`
- `SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY` / `--symbology`
- `SESSION_HUB_SCANNER_SHARED_SECRET` / `--shared-secret`

## Identificar y fijar cada lector por `reader_id`

Para evitar choques con varios lectores instalados:

1. Descubrí los puertos disponibles con ID de dispositivo:

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
.\discover-session-hub-readers.ps1
```

2. Copiá el `device_id` que te interesa y usalo:
- env var: `SESSION_HUB_SCANNER_DEVICE_ID=...`
- o parámetro: `--scanner-device-id ...`

## Configuración objetivo para el host

- `SESSION_HUB_SCANNER_INPUT_MODE=serial`
- `SESSION_HUB_SCANNER_SERIAL_PORT=COM6`
- `SESSION_HUB_SCANNER_SERIAL_BAUD_RATE=9600`
- `SESSION_HUB_BASE_URL=https://devapp.dimensioncomercial.com.ar`
- `SESSION_HUB_SCANNER_HOST_ID=sucursal-1-caja-1`
- `SESSION_HUB_SCANNER_DISPLAY_NAME=Scanner Caja 1`
- `SESSION_HUB_SCANNER_DEVICE_ID=<id-del-lector>` opcional pero recomendado

## Ejecución directa (modo desarrollo)

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
$env:SESSION_HUB_BASE_URL="https://devapp.dimensioncomercial.com.ar"
$env:SESSION_HUB_SCANNER_HOST_ID="sucursal-1-caja-1"
$env:SESSION_HUB_SCANNER_DISPLAY_NAME="Scanner Caja 1"
$env:SESSION_HUB_SCANNER_INPUT_MODE="serial"
$env:SESSION_HUB_SCANNER_SERIAL_PORT="COM6"
$env:SESSION_HUB_SCANNER_DEVICE_ID="USB\\VID_0A5F&PID_8000\\0123456789"
node bridge.js
```

## Logging esperado (serial)

Eventos clave:
- `bridge.status`: `starting`, `serial.port.discovered`, `serial.port.matched_by_device_id`, `serial.input.active`, `serial.port.open`, `scanner.registered`, `scanner.ack`, `reconnecting`, `serial.port.wait`, `serial.port.failed`, `binding.bound`, `binding.updated`, `binding.released`
- `bridge.serial`: `serial.parse` con `raw_line`, `line`, `raw_length`, `normalized_length`
- `bridge.scan`: `scan.outbound` con `scan_id`, `type`, `value`, `raw_value`, `scanner_device_id`
- `bridge.message`: eventos WS recibidos (`session_hub.hello`, `scanner.registered`, `scanner.ack`, etc)
- `bridge.error`: errores de puerto, WS o ack fallidos

## Validación de claim + producto

1. Claim:
- escanear QR de claim
- debe verse `serial.parse` y `serial.scan`
- debe verse `scan.outbound` con `type="claim"`
- debe verse `scanner.ack` con `kind="claim"` y `ok:true` si aplica
- debe verse `binding.bound` con `owner_mobile_session_id` seteado

2. Producto:
- escanear producto real
- debe verse `serial.parse` y `serial.scan`
- debe verse `scan.outbound` con `type="product"`
- debe verse `scanner.ack` del scan cuando haya respuesta del backend

3. Si no hay resolución de producto, igual queda evidencia:
- `scan.outbound` con `raw_value` y `value` enviados al WS

## Runner y Scheduled Task (daemon)

Script: `run-session-hub-bridge.ps1`

```powershell
# Desde C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
.\run-session-hub-bridge.ps1 -Mode install-task -ReaderDeviceId "USB\\VID_0A5F&PID_8000\\0123456789"
.\run-session-hub-bridge.ps1 -Mode start-task
.\run-session-hub-bridge.ps1 -Mode status-task
.\run-session-hub-bridge.ps1 -Mode tail-logs -TailLines 300
.\run-session-hub-bridge.ps1 -Mode stop-task
.\run-session-hub-bridge.ps1 -Mode uninstall-task
```

## Paquetes de instalación

Build zip offline:

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
.\build-session-hub-scanner-package.ps1 -Version 1.0.0 -DestinationPath "C:\tmp\session-hub-scanner-bridge.zip" -Overwrite
```

Ese zip incluye:
- `node.exe` portable
- `node_modules`
- `update-session-hub-scanner.ps1`
- `package-version.txt`

No depende de Node instalado en el host destino.

Install en máquina destino:

```powershell
Expand-Archive -Path "C:\tmp\session-hub-scanner-bridge.zip" -DestinationPath "C:\tmp\session-hub-scanner-bridge-package" -Force
Set-Location C:\tmp\session-hub-scanner-bridge-package\session-hub-scanner-bridge
.\install-session-hub-scanner.ps1 -HostId "sucursal-1-caja-1" -DisplayName "Scanner Caja 1" -SerialPort "COM6" -ReaderDeviceId "USB\\VID_0A5F&PID_8000\\0123456789"
```

Recomendado, con tray visible, autoarranque y updater:

```powershell
.\install-session-hub-scanner.ps1 -HostId "sucursal-1-caja-1" -DisplayName "Scanner Caja 1" -SerialPort "COM6" -ReaderDeviceId "USB\\VID_0A5F&PID_8000\\0123456789" -InstallTray true -StartTrayTask true -InstallUpdater true -StartUpdaterTask true -UpdateManifestUrl "https://tu-servidor/scanner-host/manifest.json" -UpdateChannel stable
```

## Tray icon (estado en barra de sistema)

La tray UI se ejecuta en una tarea de usuario y además instala un launcher en `Startup` para garantizar reaparición al iniciar sesión aunque Windows no levante bien la task interactiva.

Comandos:

```powershell
Set-Location C:\ProgramData\SessionHubScannerBridge
.\run-session-hub-bridge.ps1 -Mode install-tray-task -Root C:\ProgramData\SessionHubScannerBridge
.\run-session-hub-bridge.ps1 -Mode start-tray-task -Root C:\ProgramData\SessionHubScannerBridge -TrayTaskName SessionHubScannerBridgeTray -TaskName SessionHubScannerBridge -HostId sucursal-1-caja-1
.\run-session-hub-bridge.ps1 -Mode status-tray-task -TrayTaskName SessionHubScannerBridgeTray
```

Logs:
- Tray: `C:\ProgramData\SessionHubScannerBridge\tray.log`
- Bridge: `C:\ProgramData\SessionHubScannerBridge\bridge.log`
- Updater: `C:\ProgramData\SessionHubScannerBridge\update.log`
- Startup launcher: `C:\Users\<usuario>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\SessionHubScannerBridgeTray.vbs`

## Actualizaciones automáticas

Script:
- `update-session-hub-scanner.ps1`

Task:
- `SessionHubScannerBridgeUpdater`

Instalación manual del updater:

```powershell
Set-Location C:\ProgramData\SessionHubScannerBridge
.\update-session-hub-scanner.ps1 -Mode install-task -InstallRoot C:\ProgramData\SessionHubScannerBridge -ManifestUrl https://tu-servidor/scanner-host/manifest.json -Channel stable
.\update-session-hub-scanner.ps1 -Mode start-task -InstallRoot C:\ProgramData\SessionHubScannerBridge
.\update-session-hub-scanner.ps1 -Mode status-task -InstallRoot C:\ProgramData\SessionHubScannerBridge
```

Chequeo manual:

```powershell
Set-Location C:\ProgramData\SessionHubScannerBridge
.\update-session-hub-scanner.ps1 -Mode check -InstallRoot C:\ProgramData\SessionHubScannerBridge
```

Manifest esperado del servidor:

```json
{
  "channels": {
    "stable": {
      "version": "1.0.1",
      "package_url": "https://tu-servidor/scanner-host/releases/1.0.1/session-hub-scanner-bridge.zip",
      "sha256": "HEX_SHA256_DEL_ZIP",
      "notes": "fix serial reconnection"
    }
  }
}
```

Flujo:
- el cliente lee `scanner-bridge-config.json`
- compara `installed-version.txt` contra el manifest remoto
- si hay versión nueva:
- descarga el zip
- valida `sha256` si existe
- frena bridge y tray
- reemplaza payload instalado
- actualiza versión
- vuelve a iniciar el bridge

## Paquete de instalación .exe

Build:

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
.\build-session-hub-scanner-installer-exe.ps1 -Overwrite
```

Esto genera:
- `C:\tmp\SessionHubScannerBridgeInstaller\SessionHubScannerBridgeInstaller.exe`
- `C:\tmp\SessionHubScannerBridgeInstaller\payload\` con runtime portable y scripts

Uso:

```powershell
& 'C:\tmp\SessionHubScannerBridgeInstaller\SessionHubScannerBridgeInstaller.exe' \
  --host-id sucursal-1-caja-1 \
  --display-name "Scanner Caja 1" \
  --serial-port COM6 \
  --base-url https://devapp.dimensioncomercial.com.ar \
  --manifest-url https://tu-servidor/scanner-host/manifest.json \
  --update-channel stable \
  --task-name SessionHubScannerBridge \
  --install-root C:\ProgramData\SessionHubScannerBridge \
  --install-tray true \
  --start-tray-task true \
  --install-updater true \
  --start-updater-task true
```

Notas:
- el instalador genera o actualiza `C:\ProgramData\SessionHubScannerBridge`
- copia `node.exe` portable y `node_modules`, sin requerir Node instalado
- si no te interesa levantar tasks al instante, pasá `--start-task false`, `--start-tray-task false` o `--start-updater-task false`

## Múltiples lectores en la misma PC

```powershell
.\install-session-hub-scanner.ps1 -HostId "sucursal-1-caja-1" -SerialPort "COM6" -ReaderDeviceId "USB\\VID_...\\001" -TaskName "SessionHubScannerBridge_Caja1"
.\install-session-hub-scanner.ps1 -HostId "sucursal-2-caja-2" -SerialPort "COM7" -ReaderDeviceId "USB\\VID_...\\002" -TaskName "SessionHubScannerBridge_Caja2"
```

## Troubleshooting

- `Opening COM6: Unknown error code 121` o puerto inaccesible:
- recrear el puerto desconectando y reconectando el lector
- verificar que no haya otro proceso usando el COM
- confirmar modo USB Virtual COM Port en el lector

- No hay cambios de `binding` tras claim:
- revisar `bridge.err` y `bridge.log` por `session_hub.error`
- confirmar token válido y no usado

- El tray no aparece:
- revisar `tray.log`
- revisar iconos ocultos de Windows
- ejecutar `wscript.exe` sobre el launcher de Startup si hace falta
