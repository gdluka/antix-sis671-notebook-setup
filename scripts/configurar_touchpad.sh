#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 ]]; then
    echo 'Ejecuta este script como usuario normal, sin sudo.' >&2
    exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/notebook-touchpad-speed"
installed_script="$HOME/.local/bin/notebook-touchpad-speed"
startup_file="$HOME/.desktop-session/startup"
begin_marker='# BEGIN notebook-touchpad-speed'
end_marker='# END notebook-touchpad-speed'

[[ -f $source_script ]] || {
    echo "Falta $source_script" >&2
    exit 1
}
command -v xinput >/dev/null || {
    echo 'Falta xinput. Instala el paquete xinput.' >&2
    exit 1
}
command -v dbus-monitor >/dev/null || {
    echo 'Falta dbus-monitor.' >&2
    exit 1
}

install -D -m 0755 "$source_script" "$installed_script"
mkdir -p "$(dirname "$startup_file")"
touch "$startup_file"
backup="${startup_file}.backup-touchpad-$(date +%Y%m%d-%H%M%S)"
cp -a "$startup_file" "$backup"
startup_tmp=$(mktemp)
trap 'rm -f "$startup_tmp"' EXIT
awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    /xinput set-prop [0-9]+ "libinput Accel Speed"/ { next }
    !skip { print }
' "$startup_file" >"$startup_tmp"
{
    cat "$startup_tmp"
    printf '\n%s\n' "$begin_marker"
    echo '# Identifica el touchpad por nombre y restaura su velocidad al reanudar.'
    printf '%q --watch &\n' "$installed_script"
    echo "$end_marker"
} >"$startup_file"
chmod 0755 "$startup_file"

if [[ -n ${DISPLAY:-} ]]; then
    "$installed_script"
    "$installed_script" --watch >/tmp/notebook-touchpad-watch.log 2>&1 &
    echo 'Velocidad del touchpad aplicada en la sesión actual.'
else
    echo 'El ajuste se aplicará al iniciar la próxima sesión gráfica.'
fi
echo "Touchpad configurado. Copia de seguridad: $backup"
