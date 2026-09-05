#!/usr/bin/env bash
set -Eeuo pipefail

restart_ui=false
configure_power=true

usage() {
    cat <<'EOF'
Uso: ./reinstalar-notebook.sh [opciones]

Actualiza antiX, instala los extras y restaura la configuracion de esta notebook.
Debe ejecutarse como usuario normal, sin sudo.

Opciones:
  --restart-ui       Aplica la pantalla inmediatamente (cierra la sesion grafica).
  --skip-power       No configura hibernacion ni bloquea la suspension.
  -h, --help         Muestra esta ayuda.
EOF
}

while (($#)); do
    case "$1" in
        --restart-ui) restart_ui=true ;;
        --configure-power) configure_power=true ;;
        --skip-power) configure_power=false ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Opcion desconocida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -eq 0 ]]; then
    echo 'Ejecuta este instalador como usuario normal, sin sudo.' >&2
    exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for required in configurar_pantalla.sh configurar_arranque_visual.sh configurar_rofi.sh configurar_touchpad.sh configurar_firefox.sh configurar_psd.sh configurar_audio.sh configurar_agente_impresion.sh configurar_netbird.sh; do
    [[ -x "$script_dir/$required" ]] || {
        echo "Falta el script ejecutable: $script_dir/$required" >&2
        exit 1
    }
done

echo '[1/10] Comprobando permisos administrativos...'
sudo -v

echo '[2/10] Actualizando repositorios y paquetes...'
sudo apt-get update
sudo apt-get upgrade -y

echo '[3/10] Instalando paquetes necesarios...'
sudo apt-get install -y \
    firefox-esr \
    git \
    jq \
    bootlogd \
    console-common \
    pciutils \
    profile-sync-daemon \
    rofi \
    rsync \
    slimski \
    sqlite3 \
    webext-ublock-origin-firefox \
    xcape \
    xinput \
    xserver-xorg-core \
    xserver-xorg-video-vesa \
    yad

echo '[4/10] Configurando aplicaciones del usuario...'
"$script_dir/configurar_rofi.sh" --skip-packages
"$script_dir/configurar_touchpad.sh"
if [[ -d $HOME/.mozilla/firefox ]]; then
    "$script_dir/configurar_firefox.sh" --skip-packages
else
    echo 'Firefox se configurara despues de abrirlo por primera vez.'
fi
"$script_dir/configurar_psd.sh" --skip-packages --user "$USER"

echo '[5/10] Estabilizando el audio del conector auxiliar...'
"$script_dir/configurar_audio.sh"

echo '[6/10] Configurando el arranque de NetBird...'
if command -v netbird >/dev/null 2>&1; then
    "$script_dir/configurar_netbird.sh"
else
    echo 'NetBird aun no esta instalado; se omite su servicio runit.'
fi

echo '[7/10] Reforzando el inicio del agente de impresion...'
if [[ -x ${XDG_DATA_HOME:-${HOME}/.local/share}/ecommerce-print-agent/ecommerce-print-agent ]]; then
    "$script_dir/configurar_agente_impresion.sh"
else
    echo 'El agente aun no esta instalado; se omite su inicio automatico.'
fi

echo '[8/10] Aplicando el arreglo de pantalla despues de la actualizacion...'
screen_args=()
$restart_ui && screen_args+=(--restart-ui)
"$script_dir/configurar_pantalla.sh" "${screen_args[@]}"

echo '[9/10] Configurando GRUB y el arranque silencioso...'
"$script_dir/configurar_arranque_visual.sh"

echo '[10/10] Configurando energía e hibernación...'
if $configure_power; then
    power_script="$script_dir/setup-power-management.sh"
    [[ -x $power_script ]] || power_script="$script_dir/Descargas/setup-power-management.sh"
    [[ -x $power_script ]] || {
        echo "No se encontro $power_script" >&2
        exit 1
    }
    sudo "$power_script" apply --desktop-user "$USER" --yes
fi

echo
echo 'Reinstalacion y configuracion terminadas.'
if ! $restart_ui; then
    echo 'Reinicia el equipo cuando puedas para aplicar la configuracion grafica.'
fi
