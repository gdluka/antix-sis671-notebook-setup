#!/usr/bin/env bash
set -Eeuo pipefail

restart_ui=false
configure_power=true
browser="min"
keep_firefox=false

usage() {
    cat <<'EOF'
Uso: ./reinstalar-notebook.sh [opciones]

Actualiza antiX, instala los extras y restaura la configuracion de esta notebook.
Debe ejecutarse como usuario normal, sin sudo.

Opciones:
  --browser min|brave Navegador predeterminado (default: min).
  --keep-firefox      Conserva Firefox y profile-sync-daemon instalados.
  --restart-ui       Aplica la pantalla inmediatamente (cierra la sesion grafica).
  --skip-power       No configura hibernacion ni bloquea la suspension.
  -h, --help         Muestra esta ayuda.
EOF
}

while (($#)); do
    case "$1" in
        --browser)
            [[ $# -ge 2 ]] || { echo 'Falta el valor de --browser.' >&2; exit 2; }
            browser="$2"
            shift 2
            continue
            ;;
        --keep-firefox) keep_firefox=true ;;
        --restart-ui) restart_ui=true ;;
        --configure-power) configure_power=true ;;
        --skip-power) configure_power=false ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Opcion desconocida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ $browser == "min" || $browser == "brave" ]] || {
    printf 'Navegador no soportado: %s (usa min o brave).\n' "$browser" >&2
    exit 2
}

if [[ ${EUID} -eq 0 ]]; then
    echo 'Ejecuta este instalador como usuario normal, sin sudo.' >&2
    exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for required in configurar_pantalla.sh configurar_arranque_visual.sh configurar_rofi.sh configurar_touchpad.sh configurar_navegador.sh configurar_audio.sh configurar_agente_impresion.sh configurar_netbird.sh configurar_wifi.sh; do
    [[ -x "$script_dir/$required" ]] || {
        echo "Falta el script ejecutable: $script_dir/$required" >&2
        exit 1
    }
done

echo '[1/11] Comprobando permisos administrativos...'
sudo -v

echo '[2/11] Actualizando repositorios y paquetes...'
sudo apt-get update
sudo apt-get upgrade -y

echo '[3/11] Instalando paquetes necesarios...'
sudo apt-get install -y \
    git \
    jq \
    bootlogd \
    console-common \
    pciutils \
    rofi \
    rsync \
    slimski \
    xcape \
    xinput \
    xserver-xorg-core \
    xserver-xorg-video-vesa \
    yad

echo '[4/11] Configurando aplicaciones del usuario...'
"$script_dir/configurar_rofi.sh" --skip-packages
"$script_dir/configurar_touchpad.sh"
browser_args=(--browser "$browser")
$keep_firefox && browser_args+=(--keep-firefox)
"$script_dir/configurar_navegador.sh" "${browser_args[@]}"

echo '[5/11] Estabilizando el audio del conector auxiliar...'
"$script_dir/configurar_audio.sh"

echo '[6/11] Evitando gestores DHCP duplicados...'
"$script_dir/configurar_wifi.sh"

echo '[7/11] Configurando el arranque de NetBird...'
if command -v netbird >/dev/null 2>&1; then
    "$script_dir/configurar_netbird.sh"
else
    echo 'NetBird aun no esta instalado; se omite su servicio runit.'
fi

echo '[8/11] Reforzando el inicio del agente de impresion...'
if [[ -x ${XDG_DATA_HOME:-${HOME}/.local/share}/ecommerce-print-agent/ecommerce-print-agent ]]; then
    "$script_dir/configurar_agente_impresion.sh"
else
    echo 'El agente aun no esta instalado; se omite su inicio automatico.'
fi

echo '[9/11] Aplicando el arreglo de pantalla despues de la actualizacion...'
screen_args=()
$restart_ui && screen_args+=(--restart-ui)
"$script_dir/configurar_pantalla.sh" "${screen_args[@]}"

echo '[10/11] Configurando GRUB y el arranque silencioso...'
"$script_dir/configurar_arranque_visual.sh"

echo '[11/11] Configurando energía e hibernación...'
if $configure_power; then
    power_script="$script_dir/setup-power-management.sh"
    [[ -x $power_script ]] || power_script="$script_dir/Descargas/setup-power-management.sh"
    [[ -x $power_script ]] || {
        echo "No se encontro $power_script" >&2
        exit 1
    }
    sudo "$power_script" apply --desktop-user "$USER" --browser "$browser" --yes
fi

echo
echo 'Reinstalacion y configuracion terminadas.'
if ! $restart_ui; then
    echo 'Reinicia el equipo cuando puedas para aplicar la configuracion grafica.'
fi
