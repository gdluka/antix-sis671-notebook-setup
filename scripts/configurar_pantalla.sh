#!/usr/bin/env bash
set -Eeuo pipefail

restart_ui=false
check_only=false
force=false
use_vesa=false

driver_repository='https://github.com/tiolennon/xf86-video-sis671.git'
driver_commit='08b3d81e55745c8829ccd1943c38050c68210830'
driver_module='/usr/lib/xorg/modules/drivers/sis671_drv.so'
xorg_config='/etc/X11/xorg.conf'

usage() {
    cat <<'EOF'
Uso: configurar_pantalla.sh [--check] [--restart-ui] [--force] [--vesa]

Compila e instala el controlador comunitario SiS 671 compatible con Xorg 21,
habilita aceleracion EXA 2D y configura el panel 1280x800 con un monitor VGA
1366x768 extendido a la derecha.

  --check       Solo comprueba la configuracion actual.
  --restart-ui  Reinicia Slimski al terminar (cierra la sesion grafica).
  --force       Aplica aunque no se detecte la GPU PCI 1039:6351.
  --vesa        Instala la configuracion de recuperacion VESA 1280x768.

El codigo del controlador se descarga desde su repositorio original y se fija
al commit que fue probado en Debian 13/antiX con Xorg 21.
EOF
}

while (($#)); do
    case "$1" in
        --check) check_only=true ;;
        --restart-ui) restart_ui=true ;;
        --force) force=true ;;
        --vesa) use_vesa=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Opcion desconocida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null || { echo 'Falta sudo.' >&2; exit 1; }
    sudo_cmd=(sudo)
fi

command -v lspci >/dev/null || {
    echo 'Falta lspci (paquete pciutils).' >&2
    exit 1
}

if ! lspci -n | grep -qi '1039:6351' && ! $force; then
    echo 'No se detecto la GPU SiS 771/671 (1039:6351).' >&2
    echo 'Usa --force solamente si confirmaste manualmente el hardware.' >&2
    exit 1
fi

if $check_only; then
    if $use_vesa; then
        grep -q 'Driver "vesa"' "$xorg_config" 2>/dev/null \
            && grep -q 'Modes "1280x768"' "$xorg_config" 2>/dev/null \
            && { echo 'OK: recuperacion VESA configurada a 1280x768.'; exit 0; }
        echo 'PENDIENTE: VESA 1280x768 no esta activo.'
    else
        [[ -r $driver_module ]] \
            && grep -q 'Driver "sis671"' "$xorg_config" 2>/dev/null \
            && grep -q 'Option "NoAccel" "false"' "$xorg_config" 2>/dev/null \
            && grep -q 'Identifier "SiS671DualHead"' "$xorg_config" 2>/dev/null \
            && grep -q 'Option "Xinerama" "true"' "$xorg_config" 2>/dev/null \
            && grep -q 'Modes "1280x800"' "$xorg_config" 2>/dev/null \
            && grep -q 'Modes "1366x768"' "$xorg_config" 2>/dev/null \
            && { echo 'OK: panel 1280x800 y VGA 1366x768 extendido estan configurados.'; exit 0; }
        echo 'PENDIENTE: falta el controlador SiS 671 moderno o la configuracion dual.'
    fi
    exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
config_tmp="$work_dir/xorg.conf"

if $use_vesa; then
    "${sudo_cmd[@]}" apt-get install -y xserver-xorg-core xserver-xorg-video-vesa slimski pciutils
    cat >"$config_tmp" <<'EOF'
# Configuracion de recuperacion para SiS 771/671.
Section "Device"
    Identifier "Device0"
    Driver "vesa"
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync 30-70
    VertRefresh 50-75
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1280x768" "1024x768" "800x600"
    EndSubSection
EndSection
EOF
else
    "${sudo_cmd[@]}" apt-get install -y \
        autoconf automake build-essential git libtool libx11-dev pciutils \
        pkg-config slimski xorg-dev xserver-xorg-core xutils-dev

    git clone --quiet "$driver_repository" "$work_dir/source"
    git -C "$work_dir/source" checkout --quiet --detach "$driver_commit"
    [[ $(git -C "$work_dir/source" rev-parse HEAD) == "$driver_commit" ]] || {
        echo 'No se pudo obtener el commit esperado del controlador.' >&2
        exit 1
    }

    (
        cd "$work_dir/source"
        ./configure --prefix=/usr --disable-static --disable-dri
        make -j"$(getconf _NPROCESSORS_ONLN)"
        make DESTDIR="$work_dir/stage" install
    )
    built_module=$(find "$work_dir/stage" -type f -name sis671_drv.so -print -quit)
    [[ -n $built_module && -s $built_module ]] || {
        echo 'La compilacion termino sin producir sis671_drv.so.' >&2
        exit 1
    }

    "${sudo_cmd[@]}" install -d -o root -g root -m 0755 "$(dirname "$driver_module")"
    if "${sudo_cmd[@]}" test -f "$driver_module"; then
        "${sudo_cmd[@]}" install -d -o root -g root -m 0700 /var/backups/notebook
        backup="/var/backups/notebook/sis671_drv.so.$(date +%Y%m%d-%H%M%S)"
        "${sudo_cmd[@]}" cp -a "$driver_module" "$backup"
        echo "Controlador anterior respaldado en $backup"
    fi
    "${sudo_cmd[@]}" install -o root -g root -m 0644 "$built_module" "$driver_module"

    cat >"$config_tmp" <<'EOF'
# SiS 771/671 con panel 1280x800 y VGA 1366x768 extendido.
Section "ServerLayout"
    Identifier "SiS671DualHead"
    Screen 0 "LaptopScreen" 0 0
    Screen 1 "VGAScreen" RightOf "LaptopScreen"
    Option "Clone" "off"
    Option "Xinerama" "true"
EndSection

Section "Device"
    Identifier "SiS671-LCD"
    Driver "sis671"
    BusID "PCI:1:0:0"
    Screen 0
    Option "ForceCRT1" "true"
    Option "ForceCRT2Type" "LCD"
    Option "EnableSiSCtrl" "true"
    Option "NoAccel" "false"
    Option "UseTiming1366" "no"
EndSection

Section "Device"
    Identifier "SiS671-VGA"
    Driver "sis671"
    BusID "PCI:1:0:0"
    Screen 1
    Option "ForceCRT1" "true"
    Option "ForceCRT2Type" "LCD"
    Option "ForceCRT1VGAAspect" "WIDE"
    Option "UseTiming1366" "true"
    Option "NoAccel" "false"
EndSection

Section "Monitor"
    Identifier "LaptopLCD"
    HorizSync 30-82
    VertRefresh 50-75
    Option "DPMS"
EndSection

Section "Monitor"
    Identifier "ExternalVGA"
    HorizSync 30-70
    VertRefresh 56-75
    Option "DPMS"
EndSection

Section "Screen"
    Identifier "LaptopScreen"
    Device "SiS671-LCD"
    Monitor "LaptopLCD"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1280x800" "1024x768" "800x600"
    EndSubSection
EndSection

Section "Screen"
    Identifier "VGAScreen"
    Device "SiS671-VGA"
    Monitor "ExternalVGA"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1366x768" "1024x768" "800x600"
    EndSubSection
EndSection
EOF
fi

if "${sudo_cmd[@]}" test -f "$xorg_config" && ! "${sudo_cmd[@]}" cmp -s "$config_tmp" "$xorg_config"; then
    "${sudo_cmd[@]}" install -d -o root -g root -m 0700 /var/backups/notebook
    backup="/var/backups/notebook/xorg.conf.$(date +%Y%m%d-%H%M%S)"
    "${sudo_cmd[@]}" cp -a "$xorg_config" "$backup"
    echo "Configuracion anterior respaldada en $backup"
fi
"${sudo_cmd[@]}" install -o root -g root -m 0644 "$config_tmp" "$xorg_config"

if $use_vesa; then
    echo 'Configuracion VESA 1280x768 instalada.'
else
    echo "Controlador SiS 671 $driver_commit y escritorio 1280x800 + 1366x768 instalados."
fi

if $restart_ui; then
    if command -v sv >/dev/null && [[ -e /etc/service/slimski ]]; then
        echo 'Reiniciando la interfaz grafica...'
        "${sudo_cmd[@]}" sv restart /etc/service/slimski
    else
        echo 'No se encontro el servicio runit de Slimski; reinicia el equipo.'
    fi
else
    echo 'El cambio se aplicara en el proximo arranque.'
fi
