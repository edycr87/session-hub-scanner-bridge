# Session Hub Scanner Bridge (Windows Host-Owned)

Objetivo:
- Mantener el bridge WS canónico.
- Leer scanners USB por COM de forma estable en modo daemon.
- Registrar claim/product con trazabilidad suficiente.
- Atar cada lector por ID para evitar choques entre múltiples dispositivos.
- Distribuir runtime self-contained y permitir auto-update desde un manifest central.

Canonical:
- `C:\gestor_produccion\backend\tools\session-hub-scanner-bridge`
- WS: `wss://<servidor>/session-hub/scanner`. La dirección del servidor se declara siempre (`--base-url` / `-BaseUrl`); el agente y el instalador no traen ninguna por defecto.

## Contrato del agente (versión 1.3.0)

Este apartado es el contrato del agente. Lo que sigue describe lo que el código hace; si el código y este texto difieren, se corrige uno de los dos en el mismo cambio.

### Identidad del puesto

- `host_id` = nombre de la PC (hostname) normalizado: minúsculas, sin tildes, caracteres fuera de `[a-z0-9-]` pasan a `-`, los `-` repetidos se colapsan, sin `-` al inicio ni al final, máximo 40 caracteres. `display_name` = hostname tal cual.
- Vale en toda instalación, nueva o reinstalación, y también en la PC que ya tenía una versión anterior. El instalador no pregunta el nombre. El runner lo vuelve a calcular en cada arranque: si se renombra la PC, el puesto cambia de nombre sin reinstalar.
- No hay ningún valor compartido por defecto: ni `host_id`, ni nombre visible, ni puerto, ni dirección del servidor. Si falta la dirección del servidor, o el hostname no da un nombre válido, el instalador y el agente fallan con un mensaje claro y no instalan ni arrancan.
- Conservar un `host_id` anterior es una decisión explícita: `-KeepHostId <valor>` en el instalador (`--keep-host-id` en el `.exe`). `-HostId <valor>` (o `--host-id`) también fija un nombre explícito. En ambos casos queda registrado en la configuración como `host_id_source = explicit`; sin eso el nombre sale siempre del hostname.
- El servidor no renombra ni borra filas: el puesto anterior queda fuera de línea con su historial y el vínculo del puesto anterior no migra (se vuelve a escanear el QR).
- Identificador de instalación: el agente genera una vez un identificador (`installation_id`, UUID) y lo guarda en `installation-id.json`; lo envía en `scanner.register`. Es un dato técnico, no una credencial. Si el servidor responde `scanner.registered` con `ok:false` y `error_code: SCANNER_HOST_ID_IN_USE` (otra instalación activa usa ese nombre), el agente informa el conflicto (estado `host_conflict`, visible en el ícono y en el log), cierra los lectores y NO reintenta: no hay bucle de reconexión. Si recibe `scanner.superseded` (la misma instalación abrió otra conexión) también deja de reconectar. Para salir del conflicto hay que resolver el nombre duplicado y reiniciar el agente.

### Detección del lector

- El lector se identifica por dispositivo, nunca por número de COM: `vendorId:productId` y, cuando el dispositivo lo informa, su número de serie. El `reader_id` que viaja al servidor es lógico y estable (`reader-1`, o el declarado) y no cambia con el puerto.
- Detección automática (cuando no se fija ningún puerto ni lector): cada 3 segundos (configurable) lista los puertos y considera candidato sólo un puerto USB real (con `vendorId`), sin Bluetooth. Un dispositivo que no cumple se ignora.
- Un candidato: lo abre y recuerda su identidad en `reader-identity.json` (`source: auto`).
- Más de un candidato y ninguno recordado: estado `ambiguous`. El agente no elige, no abre ninguno y no toma "el primero". El ícono avisa y ofrece el selector (ver abajo). Dos dispositivos con el mismo `vendorId:productId` y sin número de serie no se pueden distinguir: tampoco se elige ninguno.
- Con una identidad recordada o elegida: sólo se abre el puerto que coincide con ella. Si no está, el estado es `waiting` y se espera; nunca se toma otro dispositivo aunque sea el único. Si el lector aparece después del arranque, o desaparece y vuelve con otro número de COM (por ejemplo al pasar de teclado USB-HID a puerto serie USB-VCOM), el agente lo vuelve a abrir solo.
- Si el lector abierto desaparece de la lista de puertos, el agente cierra el puerto y vuelve a esperar.
- Fijarlo a mano: `-ReaderUsbId <vid:pid[/serie]>` en el instalador (se guarda como `reader_usb_id`), o `--reader-usb-id`; también la elección desde el ícono, o `run-session-hub-bridge.ps1 -Mode choose-reader -ReaderUsbId <vid:pid[/serie]>` (y `-Mode forget-reader`) con permisos de administrador. `-SerialPort`/`--serial-port` sigue existiendo como fijación explícita por número de COM y no se usa salvo que se declare. `--readers` (varios lectores) conserva su comportamiento.

### Más de un candidato: elegir

- Estado `ambiguous`: el ícono muestra el aviso "Hay más de un lector USB: elegí cuál es" y el menú "Elegir lector..." lista cada candidato con VID:PID, número de serie si lo hay y el puerto actual sólo como referencia.
- Al elegir, el ícono NO escribe la configuración: deja una solicitud en la carpeta `ui` (la única que los usuarios comunes pueden escribir) y el agente la valida contra los candidatos que ve en ese momento, guarda la elección por identidad en `reader-identity.json` (`source: user`) y abre ese dispositivo. Después de reiniciar recuerda la elección. "Olvidar lector" borra la identidad guardada.
- Si no se puede escribir en `ui` (instalación anterior sin esa carpeta), el ícono ofrece repetir la acción con elevación explícita (administrador). El mensaje de error nunca es un callejón sin salida: dice qué hacer.

### Qué se guarda y dónde (`C:\ProgramData\SessionHubScannerBridge`)

| Archivo | Quién lo escribe | Contenido | Acceso de usuarios comunes |
|---|---|---|---|
| `scanner-bridge-config.json` | instalador (administrador) | configuración, incluido el secreto si existe | sin acceso (sólo SYSTEM y Administradores) |
| `reader-identity.json` | agente (SYSTEM) | lector recordado o elegido (VID:PID, serie), no es secreto | lectura |
| `installation-id.json` | agente (SYSTEM) | identificador de instalación, no es secreto | lectura |
| `bridge-state.json` | agente (SYSTEM) | estado del puesto y del lector, candidatos | lectura |
| `ui\reader-choice.request.json` | ícono o administrador | solicitud de elegir u olvidar el lector | escritura (carpeta `ui`) |

`reader-identity.json` e `installation-id.json` no viajan en los paquetes y la actualización automática no los toca.

### Estado visible

- El ícono muestra: puesto (hostname), estado del lector (`waiting` esperando, `open` abierto, `failed` falló, `disconnected` desconectado, `ambiguous` ambiguo) o estado del puesto (`host_conflict` conflicto de nombre, `superseded` reemplazado por otra conexión de la misma instalación), y el puerto activo como referencia.
- El mismo estado viaja al servidor: en `scanner.register` y en cada `scanner.heartbeat`, dentro de `capabilities.readers` (lista con `reader_id`, `state`, `serial_port`, `vendor_id`, `product_id`, número de serie si lo hay y, si es ambiguo, los candidatos). El servidor no lo exige.

### Instalación y reinstalación

- El diagnóstico previo ya no bloquea una reinstalación porque cambien nombre de puesto, nombre visible o puerto: lo declara como migración intencional (aviso con valor viejo y nuevo). Un cambio de dirección del servidor sigue bloqueando. Un `bridge.js` instalado que no corresponde a ningún Source versionado sigue bloqueando (`UNKNOWN_BRIDGE_SOURCE`): no se acredita agregando su hash y `-AcknowledgeDiagnosticDrop` no lo desbloquea (sólo cubre claves de configuración que la reinstalación no conserva). El camino es manual y explícito: leer el informe del diagnóstico, hacer copia de respaldo y retirar a mano la instalación anterior (tareas y carpeta), o seguir el procedimiento que apruebe quien revisa; recién entonces se instala.
- En una reinstalación, si no se pasa `-BaseUrl`, se toma la dirección del servidor guardada en la configuración anterior (es la que ya usaba, no un valor por defecto); si no hay ninguna, el instalador falla.
- Esta versión no incluye claves, canales ni secretos en el paquete. El secreto compartido, si el servidor lo exige, se entrega aparte y se pasa en la instalación.

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
- `SESSION_HUB_SCANNER_HOST_ID` / `--host-id` (sin él: hostname normalizado)
- `SESSION_HUB_SCANNER_DISPLAY_NAME` / `--display-name` (sin él: hostname)
- `SESSION_HUB_SCANNER_INPUT_MODE` / `--input-mode` (`serial` o `stdin`, default `stdin`)
- `SESSION_HUB_SCANNER_SERIAL_PORT` / `--serial-port` (fijación explícita por COM; sin él, detección automática)
- `SESSION_HUB_SCANNER_READER_USB_ID` / `--reader-usb-id` (fija el lector por `vid:pid[/serie]`)
- `SESSION_HUB_SCANNER_AUTO_POLL_MS` / `--auto-poll-ms` (default 3000)
- `SESSION_HUB_SCANNER_IDENTITY_FILE` / `--identity-file`, `SESSION_HUB_SCANNER_INSTALLATION_FILE` / `--installation-file`, `SESSION_HUB_SCANNER_UI_DIR` / `--ui-dir`
- `SESSION_HUB_SCANNER_SERIAL_BAUD_RATE` / `--serial-baud-rate`
- `SESSION_HUB_SCANNER_SERIAL_WAIT_MS` / `--serial-wait-ms`
- `SESSION_HUB_SCANNER_SERIAL_FALLBACK_TO_STDIN` / `--serial-fallback`
- `SESSION_HUB_SCANNER_SERIAL_INTERACTIVE` / `--serial-interactive`
- `SESSION_HUB_SCANNER_DEVICE_ID` / `--scanner-device-id` / `--reader-id`
- `SESSION_HUB_SCANNER_HEARTBEAT_MS` / `--heartbeat-ms`
- `SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY` / `--symbology`
- `SESSION_HUB_SCANNER_SHARED_SECRET` / `--shared-secret`

## Identificar y fijar el lector

En el uso normal no hace falta hacer nada: el agente detecta el lector solo (ver "Detección del lector"). Para fijarlo a mano:

1. Con el agente en marcha, `bridge-state.json` lista los candidatos (`vendor_id`, `product_id`, `serial_number`, puerto) y el menú del ícono "Elegir lector..." permite elegir.
2. O declará el dispositivo en la instalación: `-ReaderUsbId 0c2e:0b61` (o `0c2e:0b61/NUMERODESERIE`).
3. `discover-session-hub-readers.ps1` queda sólo como ayuda histórica; no participa de la detección.

## Configuración mínima para un puesto

- `SESSION_HUB_BASE_URL=https://<servidor>` (obligatoria)
- `SESSION_HUB_SCANNER_INPUT_MODE=serial`
- `SESSION_HUB_SCANNER_SERIAL_BAUD_RATE=9600`
- `SESSION_HUB_SCANNER_HOST_ID` y `SESSION_HUB_SCANNER_DISPLAY_NAME`: sólo si se quiere un nombre distinto del hostname
- `SESSION_HUB_SCANNER_SERIAL_PORT` y `SESSION_HUB_SCANNER_DEVICE_ID`: sólo para fijar a mano; sin ellos se detecta automáticamente

## Ejecución directa (modo desarrollo)

```powershell
Set-Location C:\gestor_produccion\backend\tools\session-hub-scanner-bridge
$env:SESSION_HUB_BASE_URL="https://<servidor>"
$env:SESSION_HUB_SCANNER_INPUT_MODE="serial"
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
.\run-session-hub-bridge.ps1 -Mode install-task -BaseUrl "https://<servidor>"
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
.\install-session-hub-scanner.ps1 -BaseUrl "https://<servidor>"
```

Sin más parámetros: el nombre del puesto es el hostname de la PC y el lector se detecta solo. En una reinstalación que debe conservar el nombre anterior: `-KeepHostId <nombre-anterior>`.

Recomendado, con tray visible, autoarranque y updater:

```powershell
.\install-session-hub-scanner.ps1 -BaseUrl "https://<servidor>" -InstallTray true -StartTrayTask true -InstallUpdater true -StartUpdaterTask true -UpdateManifestUrl "https://tu-servidor/scanner-host/manifest.json" -UpdateChannel stable
```

## Tray icon (estado en barra de sistema)

La tray UI se ejecuta en una tarea de usuario y además instala un launcher en `Startup` para garantizar reaparición al iniciar sesión aunque Windows no levante bien la task interactiva.

Comandos:

```powershell
Set-Location C:\ProgramData\SessionHubScannerBridge
.\run-session-hub-bridge.ps1 -Mode install-tray-task -Root C:\ProgramData\SessionHubScannerBridge
.\run-session-hub-bridge.ps1 -Mode start-tray-task -Root C:\ProgramData\SessionHubScannerBridge -TrayTaskName SessionHubScannerBridgeTray -TaskName SessionHubScannerBridge
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
  --base-url https://<servidor> \
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

## Dos lectores USB en la misma PC y el mismo carrito

El bridge soporta un proceso, un `host_id` y un binding compartido con varios lectores seriales. Cada lector se declara con un `reader_id` estable y su identidad física (`serial_port` y/o `scanner_device_id`). Si un lector configurado no aparece, falla cerrado para ese lector y los demás continúan.

Identificá los dispositivos con `./discover-session-hub-readers.ps1` y conservá una sola instalación/task. Ejemplo:

```powershell
$readers = '[{"reader_id":"caja-izquierda","scanner_device_id":"USB-READER-LEFT","serial_baud_rate":9600},{"reader_id":"caja-derecha","scanner_device_id":"USB-READER-RIGHT","serial_baud_rate":9600}]'
.\install-session-hub-scanner.ps1 -BaseUrl "https://<servidor>" -ReadersJson $readers
```

El instalador persiste `readers_json` en `scanner-bridge-config.json`. El runner lo carga en cada arranque, por lo que el Scheduled Task único y las actualizaciones conservan la configuración. El instalador `.exe` acepta el mismo JSON con `--readers`.

`--shared-secret` / `SESSION_HUB_SCANNER_SHARED_SECRET` y `--symbology` / `SESSION_HUB_SCANNER_DEFAULT_SYMBOLOGY` conservan el contrato de un lector. El instalador persiste esos valores locales para que el runner los inyecte al proceso, sin escribir el secreto en los logs ni en el Scheduled Task.

Cada lector tiene su propio loop y buffer. Cada captura genera un `scan_id` criptográficamente único antes del WebSocket y envía `scan_id`, `reader_id` y `scanner_device_id` arriba, más `reader_id`, `scanner_device_id`, `serial_port`, origen y momento de captura en metadata. La cola de transporte se comparte por host y envía un scan por vez para preservar el carrito compartido.

El bridge sólo consume ACKs cuyo `scan_id` coincide exactamente. Un ACK sin ID se registra como incompatibilidad y no confirma ningún scan. Tras timeout, desconexión o `MOBILE_CLIENT_NOT_CONNECTED`, `PRESUPUESTADOR_OWNER_NOT_CONNECTED` o `CONTROL_STOCK_CLIENT_NOT_CONNECTED`, reintenta el mismo ID y la misma atribución. El overflow registra `BRIDGE_QUEUE_LIMIT_EXCEEDED`; no hay reimpresión automática ni escrituras de negocio locales.

La configuración legacy de un lector con `-SerialPort`/`-ReaderDeviceId` sigue funcionando. Con `ReadersJson`, las fuentes configuradas nunca caen a stdin ni seleccionan un COM diferente.

### Límite actual de cierre E2E

Este paquete produce IDs estables y atribución por lector, pero no demuestra idempotencia durable del carrito por sí solo. El cierre E2E requiere que el backend persista y deduplique por `(mobile_session_id, scan_id)`; `reader_id` es auditoría y nunca una partición de dedupe. Hasta que ese consumidor esté aplicado y probado en DEV, dos lectores representan una superficie bridge/transport validada, no una garantía de no doble suma del carrito. HID que no aparece como COM continúa como modo físico pendiente de descubrimiento y adaptador real.

## Troubleshooting

- `serial.reader.failed`: con lector fijado, confirmar COM e identidad exacta (queda fail-closed); en detección automática, el agente reintenta solo en cada ciclo.
- Estado `ambiguous`: hay más de un lector USB; elegir desde el ícono o desenchufar el que no se use.
- Estado `host_conflict`: otra instalación usa el mismo nombre de puesto; resolver el nombre duplicado y reiniciar el agente.
- Estado `waiting`: no hay lector USB (o el recordado no está conectado); si el lector está en modo teclado, escanear el código de configuración que lo pasa a puerto serie.
- `scanner.ack.unsupported_missing_scan_id`: backend anterior al ACK contractual; no habrá falso ACK.
- La bandeja muestra el último scan/puerto y los logs siguen en `bridge.log` y `bridge.err`.
