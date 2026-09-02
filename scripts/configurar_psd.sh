#!/usr/bin/env bash
set -Eeuo pipefail

desktop_user="${SUDO_USER:-$USER}"
install_packages=true

while (($#)); do
    case "$1" in
        --user)
            [[ $# -ge 2 ]] || { echo 'Falta el valor de --user.' >&2; exit 2; }
            desktop_user="$2"
            shift 2
            ;;
        --skip-packages) install_packages=false; shift ;;
        -h|--help)
            echo 'Uso: configurar_psd.sh [--user USUARIO] [--skip-packages]'
            exit 0
            ;;
        *) echo "Opcion desconocida: $1" >&2; exit 2 ;;
    esac
done

id "$desktop_user" >/dev/null 2>&1 || {
    echo "No existe el usuario $desktop_user." >&2
    exit 1
}
user_home=$(getent passwd "$desktop_user" | cut -d: -f6)
user_group=$(id -gn "$desktop_user")
service_name="psd-${desktop_user}"
service_dir="/etc/sv/${service_name}"
worker="/usr/local/libexec/${service_name}"

if $install_packages; then
    sudo apt-get update
    sudo apt-get install -y profile-sync-daemon rsync
fi

sudo install -d -o "$desktop_user" -g "$user_group" -m 0700 "$user_home/.config/psd"
config_tmp=$(mktemp)
worker_tmp=$(mktemp)
run_tmp=$(mktemp)
trap 'rm -f "$config_tmp" "$worker_tmp" "$run_tmp"' EXIT

cat >"$config_tmp" <<'EOF'
# Configuracion de PSD para Firefox en antiX/runit.
BROWSERS=(firefox)
USE_OVERLAYFS="no"
USE_SUSPSYNC="no"
USE_BACKUPS="yes"
BACKUP_LIMIT=3
EOF
sudo install -o "$desktop_user" -g "$user_group" -m 0600 \
    "$config_tmp" "$user_home/.config/psd/psd.conf"

cat >"$worker_tmp" <<'EOF'
#!/bin/sh
set -eu
export LAUNCHED_BY_SYSTEMD=1
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -un)"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
mkdir -p "$HOME/.config/psd"
exec >>"$HOME/.config/psd/runit.log" 2>&1

cleanup() {
    /usr/bin/profile-sync-daemon unsync || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

# PSD no puede iniciar mientras Firefox esta abierto. Esperar sin forzarlo.
while pgrep -x firefox >/dev/null 2>&1 || pgrep -x firefox-esr >/dev/null 2>&1; do
    sleep 15 & wait $! || true
done

/usr/bin/profile-sync-daemon startup
/usr/bin/profile-sync-daemon resync
while :; do
    sleep 3600 & wait $! || true
    /usr/bin/profile-sync-daemon resync || true
done
EOF

cat >"$run_tmp" <<EOF
#!/bin/sh
exec 2>&1
export HOME="$user_home"
exec chpst -u "$desktop_user:$user_group" "$worker"
EOF

sudo install -d -o root -g root -m 0755 /usr/local/libexec "$service_dir"
sudo install -o root -g root -m 0755 "$worker_tmp" "$worker"
sudo install -o root -g root -m 0755 "$run_tmp" "$service_dir/run"
sudo ln -sfn "$service_dir" "/etc/service/$service_name"

# runsvdir puede tardar unos segundos en detectar un servicio nuevo.
for _ in {1..20}; do
    sudo test -e "$service_dir/supervise/ok" && break
    sleep 0.25
done
sudo test -e "$service_dir/supervise/ok" || {
    echo "runit no detecto el servicio $service_name." >&2
    exit 1
}
sudo sv restart "/etc/service/$service_name"
sleep 1
sudo sv status "/etc/service/$service_name"

echo 'PSD quedo administrado por runit y sincronizara Firefox cada hora.'
echo "Registro: $user_home/.config/psd/runit.log"
