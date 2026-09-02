# antiX SiS 671 notebook setup

Scripts reproducibles para recuperar y optimizar una notebook antigua con
antiX/Debian 13, Xorg 21, runit y video SiS 771/671 (`1039:6351`).

La configuracion fue probada en una Founder M672+968 con panel 1280x800. El
controlador 2D se compila desde
[`tiolennon/xf86-video-sis671`](https://github.com/tiolennon/xf86-video-sis671)
en el commit exacto que funciono durante las pruebas.

## Que configura

- `apt update` y `apt upgrade`.
- Controlador SiS 671 moderno con aceleracion EXA 2D y modo 1280x800 a 60 Hz.
- Opcion de recuperacion VESA 1280x768.
- GRUB oculto con espera de un segundo, arranque silencioso y animacion de
  consola compatible con esta GPU.
- Firefox ESR optimizado para hardware limitado, uBlock Origin, PSD en RAM y
  un lanzador que evita instancias duplicadas.
- Hibernacion mediante swapfile, suspension deshabilitada y recuperacion de
  Firefox, Slimski y Wi-Fi al reanudar.
- Rofi con `Win`, `Win+Espacio` o `Win+R`, y explorador con `Win+E`.

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
- `scripts/setup-power-management.sh`: swap, resume e hibernacion.
- `config/xorg.conf`: referencia de la configuracion SiS validada.

## Licencia

Copyright (C) 2026 Guillermo De Luca.

Este proyecto se distribuye bajo la licencia
[GNU GPL v3 o posterior](LICENSE). Puedes usarlo, estudiarlo, modificarlo y
redistribuirlo bajo los mismos términos. Los componentes de terceros conservan
sus propias licencias y no se redistribuyen en este repositorio.
