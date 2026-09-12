# antiX SiS 671 notebook setup

Scripts reproducibles para recuperar y optimizar una notebook antigua con
antiX/Debian 13, Xorg 21, runit y video SiS 771/671 (`1039:6351`).

La configuracion fue probada en una Founder M672+968 con panel 1280x800. El
controlador 2D se compila desde
[`tiolennon/xf86-video-sis671`](https://github.com/tiolennon/xf86-video-sis671)
en el commit exacto que funciono durante las pruebas.

## Que configura

- `apt update` y `apt upgrade`.
- Controlador SiS 671 moderno con aceleracion EXA 2D, panel 1280x800 y
  deteccion opcional de VGA mediante `MergedFB auto` al iniciar Xorg.
  La extension con monitor y la conexion/desconexion en caliente quedan
  pendientes de validar; no se fuerza una segunda pantalla ausente.
- Opcion de recuperacion VESA 1280x768.
- GRUB oculto con espera de un segundo, arranque silencioso y animacion de
  consola compatible con esta GPU.
- Firefox ESR optimizado para hardware limitado, uBlock Origin, PSD en RAM y
  un lanzador que evita instancias duplicadas.
- Hibernacion mediante swapfile, suspension deshabilitada y recuperacion de
  Firefox, Slimski y Wi-Fi al reanudar.
- Hibernacion automatica al cerrar la tapa, con proteccion contra eventos
  duplicados (`--no-hibernate-on-lid` permite desactivarla).
- Rofi con `Win`, `Win+Espacio` o `Win+R`, y explorador con `Win+E`.
- `jq` para inspeccionar respuestas JSON durante diagnósticos y smoke tests.
- Audio HDA sin suspensión automática del códec y con auto-mute desactivado,
  para estabilizar el conector auxiliar de esta notebook.
- Touchpad Elantech con velocidad `0.6`, identificado por nombre y restaurado
  automáticamente después de salir de hibernación.
- Inicio reforzado del agente de impresión bajo IceWM. El ajuste complementa el
  archivo XDG del instalador y evita que la VPN embebida quede desconectada
  después de reiniciar.
- Servicio runit para el cliente NetBird oficial ya instalado y vinculado. La
  identidad permanece exclusivamente en `/var/lib/netbird/default.json`.

## Instalacion

Despues de instalar antiX/Debian, clona el repositorio y ejecuta el instalador
como usuario normal, sin `sudo`:

```bash
git clone https://github.com/gdluka/antix-sis671-notebook-setup.git
cd antix-sis671-notebook-setup/scripts
chmod +x *.sh
./reinstalar-notebook.sh
```

El script solicita permisos administrativos cuando los necesita. No reinicia
automaticamente. Al terminar, reinicia para aplicar GRUB y Xorg.

Opciones utiles:

```bash
# Aplicar Xorg inmediatamente; cierra la sesion grafica.
./reinstalar-notebook.sh --restart-ui

# Omitir la configuracion de hibernacion.
./reinstalar-notebook.sh --skip-power

# Comprobar el controlador SiS sin modificar nada.
./configurar_pantalla.sh --check

# Cambiar solo la configuracion, sin recompilar el controlador instalado.
# --restart-ui cierra las aplicaciones; guardar el trabajo primero.
./configurar_pantalla.sh --config-only --restart-ui

# Recuperar la interfaz con VESA si el controlador SiS deja de funcionar.
./configurar_pantalla.sh --vesa

# Auditar la configuracion de energia.
./setup-power-management.sh audit
```

## Advertencias

- Los scripts estan orientados al hardware PCI `1039:6351`; el instalador de
  pantalla se detiene si no lo detecta.
- No se incluye el codigo del controlador de terceros: se descarga del
  repositorio original y se fija al commit probado.
- La hibernacion cierra Xorg de forma controlada debido a las limitaciones de
  esta GPU. Firefox restaura su sesion, pero otras aplicaciones graficas pueden
  no recuperar ventanas abiertas.
- Se crean respaldos en `/var/backups/notebook` antes de reemplazar archivos
  sensibles.

## Archivos

- `scripts/reinstalar-notebook.sh`: instalacion completa.
- `scripts/configurar_pantalla.sh`: SiS moderno o recuperacion VESA.
- `scripts/configurar_arranque_visual.sh`: GRUB y animacion de consola.
- `scripts/configurar_firefox.sh`: preferencias y lanzador protegido.
- `scripts/configurar_psd.sh`: sincronizacion del perfil de Firefox con runit.
- `scripts/configurar_rofi.sh`: atajos de IceWM y Rofi.
- `scripts/configurar_touchpad.sh`: velocidad del touchpad y restauración al reanudar.
- `scripts/notebook-touchpad-speed`: ajuste y observador de reanudación del touchpad.
- `scripts/configurar_agente_impresion.sh`: inicio confiable del agente y su VPN
  embebida en la sesión de IceWM (requiere que el agente ya esté instalado).
- `scripts/configurar_netbird.sh`: arranque automático del NetBird oficial bajo
  runit, sin incluir ni modificar credenciales.
- `scripts/configurar_audio.sh`: evita los cortes por ahorro de energía del
  códec Realtek y conserva el ajuste ALSA.
- `scripts/setup-power-management.sh`: swap, resume e hibernacion.
- `config/xorg-auto.conf`: configuracion predeterminada con VGA opcional.
- `config/xorg.conf`: referencia anterior dual-head; fuerza dos pantallas y
  puede dejar ventanas fuera del panel cuando no hay monitor externo.

## Verificacion de pantallas (2026-09-12)

En la notebook Deposito, sin monitor externo, se aplico la configuracion
`MergedFB auto` y se reinicio Slimski mediante **runit**. Xorg informo
`No CRT1/VGA detected` y desactivo MergedFB; `xdpyinfo` y `xrandr` mostraron
un escritorio de **1280x800**, sin espacio reservado para VGA. El Wi-Fi y
el acceso SSH siguieron disponibles. El primer intento con el script SysV
de Slimski fallo; en antiX con runit usar `sv restart /etc/service/slimski`,
como hace el instalador, sin mezclar ambos gestores.

No se comprobo extension con VGA conectado ni hotplug. `MergedFB auto` no
debe interpretarse como garantia de autodeteccion en caliente. Tampoco se
probaron en esta sesion hibernacion/reanudacion, audio, touchpad o impresion.
El instalador conserva respaldo de Xorg en `/var/backups/notebook`.

## Hibernacion: bloqueo de consola (2026-09-12)

Se observo `pm-hibernate` detenido en `vt_waitactive -> vt_move_to_console ->
pm_prepare_console`: el escritorio terminaba, pero el equipo no se apagaba.
Intentar interrumpir ese proceso no recupero el equipo y fue necesario cortar
la alimentacion. No se debe matar un intento bloqueado y suponer que aborto.

La nueva preparacion detiene Slimski con runit, espera a Xorg, deja la consola
en modo texto y verifica que **tty63** (la consola usada por Linux para hibernar)
este activa antes de permitir que pm-utils escriba en `/sys/power/state`.
Rechaza modificar la consola con X activo y cancela si vence el plazo de
preparacion. Esto no garantiza que otras etapas de hibernacion no puedan fallar.
La recuperacion solicita iniciar el escritorio antes de recuperar Wi-Fi.

Para actualizar solamente este flujo, sin tocar swap, GRUB ni el evento de tapa:

```bash
sudo ./scripts/setup-power-management.sh guard-only --desktop-user deposito
```

En Deposito la tapa queda sin accion (`config/lidbtn-disabled`). Tras validar un
ciclo manual se reactivo y probo el disparador por tapa: guardo la imagen, pero
el usuario no pudo encender con el boton hasta retirar la bateria. Al volver
se conservo el mismo `boot_id` y terminaron los hooks `thaw`: la imagen si se
recupero. Se desactivo nuevamente el disparador por seguridad. Sigue pendiente
diagnosticar por que el boton no responde; no se considera resuelto el ciclo
de uso completo ni se ha confirmado una causa de hardware o firmware.
El helper y el hook anteriores se respaldan en `/var/backups/notebook/hibernate-guard.*`.
La prueba sin hibernar del 2026-09-12 paso en Deposito: preparacion con salida
0, tty63 activa en VT_AUTO/KD_TEXT, recuperacion con salida 0, escritorio en
tty7 y Wi-Fi/SSH disponibles. La prueba real posterior tambien paso: el usuario
confirmo el apagado y encendio con el boton; se conservo el mismo `boot_id`,
pm-utils termino los hooks `thaw`, Slimski volvio a ejecutarse y se recuperaron
Wi-Fi y SSH. Esto valida un ciclo de hibernacion/reanudacion, no conserva las
aplicaciones graficas ni prueba aun varios ciclos o el disparo por tapa.
Las pruebas unitarias no hibernan ni modifican consolas:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

## Licencia

Copyright (C) 2026 Guillermo De Luca.

Este proyecto se distribuye bajo la licencia
[GNU GPL v3 o posterior](LICENSE). Puedes usarlo, estudiarlo, modificarlo y
redistribuirlo bajo los mismos términos. Los componentes de terceros conservan
sus propias licencias y no se redistribuyen en este repositorio.
