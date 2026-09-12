#!/usr/bin/env bash
set -Eeuo pipefail

check_only=false
[[ ${1:-} == --check ]] && check_only=true
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<'EOF'
Uso: configurar_wifi.sh [--check]

Deja ConnMan como único gestor de red. Si dhcpcd también está supervisado por
runit, lo detiene y crea su archivo "down" para evitar dos concesiones DHCP en
la misma interfaz Wi-Fi.
EOF
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Demasiados argumentos.' >&2; exit 2; }

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null || { echo 'Falta sudo.' >&2; exit 1; }
    sudo_cmd=(sudo)
fi

connman_active=/etc/service/connman
dhcpcd_active=/etc/service/dhcpcd
[[ -e $connman_active || -L $connman_active ]] || {
    echo 'ConnMan no está registrado en runit; no se modifica dhcpcd.' >&2
    exit 1
}

if $check_only; then
    "${sudo_cmd[@]}" sv status "$connman_active" | grep -q '^run:' || {
        echo 'PENDIENTE: ConnMan no está ejecutándose.' >&2
        exit 1
    }
    if [[ -e $dhcpcd_active || -L $dhcpcd_active ]]; then
        dhcpcd_service=$(readlink -f "$dhcpcd_active")
        [[ -f $dhcpcd_service/down ]] || {
            echo 'PENDIENTE: dhcpcd todavía puede iniciar junto con ConnMan.' >&2
            exit 1
        }
        "${sudo_cmd[@]}" sv status "$dhcpcd_active" | grep -q '^down:' || {
            echo 'PENDIENTE: dhcpcd todavía está ejecutándose.' >&2
            exit 1
        }
    fi
    echo 'OK: ConnMan es el único gestor de red activo.'
    exit 0
fi

if [[ -e $dhcpcd_active || -L $dhcpcd_active ]]; then
    dhcpcd_service=$(readlink -f "$dhcpcd_active")
    case "$dhcpcd_service" in
        /etc/sv/dhcpcd|/etc/runit/sv/dhcpcd) ;;
        *)
            echo "Ruta de servicio dhcpcd no reconocida: $dhcpcd_service" >&2
            exit 1
            ;;
    esac
    "${sudo_cmd[@]}" touch "$dhcpcd_service/down"
    "${sudo_cmd[@]}" sv down "$dhcpcd_active"
fi

"${sudo_cmd[@]}" sv restart "$connman_active"
"${sudo_cmd[@]}" sv status "$connman_active"
if [[ -e $dhcpcd_active || -L $dhcpcd_active ]]; then
    "${sudo_cmd[@]}" sv status "$dhcpcd_active"
fi
echo 'ConnMan quedó como único gestor de red.'
