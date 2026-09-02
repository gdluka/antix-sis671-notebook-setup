#!/usr/bin/env bash
set -Eeuo pipefail

install_packages=true
[[ ${1:-} == --skip-packages ]] && install_packages=false

if [[ ${EUID} -eq 0 ]]; then
    echo "Ejecuta este script como usuario normal, sin sudo." >&2
    exit 1
fi

if $install_packages; then
    sudo apt-get update
    sudo apt-get install -y rofi xcape
fi

icewm_dir="$HOME/.icewm"
keys_file="$icewm_dir/keys"
begin_marker='# >>> rofi-notebook >>>'
end_marker='# <<< rofi-notebook <<<'
mkdir -p "$icewm_dir"

if [[ ! -f $keys_file ]]; then
    if [[ -f /etc/X11/icewm/keys ]]; then
        cp /etc/X11/icewm/keys "$keys_file"
    elif [[ -f /usr/share/icewm/keys ]]; then
        cp /usr/share/icewm/keys "$keys_file"
    else
        : >"$keys_file"
    fi
fi

backup="${keys_file}.backup-$(date +%Y%m%d-%H%M%S)"
cp -a "$keys_file" "$backup"
tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    $0 == "key \"Super\" rofi -show drun -show-icons" { next }
    !skip { print }
' "$keys_file" >"$tmp_file"

{
    cat "$tmp_file"
    printf '\n%s\n' "$begin_marker"
    echo '# Lanzador y explorador (Super es la tecla Windows)'
    echo 'key "Super+space" rofi -show drun -show-icons'
    echo 'key "Super+r" rofi -show drun -show-icons'
    echo 'key "Super+e" desktop-defaults-run -fm'
    echo "$end_marker"
} >"$keys_file"

# IceWM no interpreta de forma fiable una tecla modificadora pulsada sola.
# xcape convierte un toque breve de Windows en Super+Espacio, pero conserva
# combinaciones como Windows+E.
startup_file="$HOME/.desktop-session/startup"
startup_begin='# BEGIN notebook-rofi-xcape'
startup_end='# END notebook-rofi-xcape'
mkdir -p "$(dirname "$startup_file")"
touch "$startup_file"
startup_tmp=$(mktemp)
awk -v begin="$startup_begin" -v end="$startup_end" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
' "$startup_file" >"$startup_tmp"
{
    cat "$startup_tmp"
    printf '\n%s\n' "$startup_begin"
    echo '# Un toque de Windows abre Rofi; las combinaciones siguen disponibles.'
    echo 'pkill -x xcape >/dev/null 2>&1 || true'
    echo "xcape -e 'Super_L=Super_L|space' &"
    echo "$startup_end"
} >"$startup_file"
chmod 0755 "$startup_file"
rm -f "$startup_tmp"

echo "Rofi configurado. Copia de seguridad: $backup"
if pgrep -x icewm >/dev/null 2>&1; then
    echo 'Reinicia IceWM o la sesión para aplicar los atajos.'
fi
