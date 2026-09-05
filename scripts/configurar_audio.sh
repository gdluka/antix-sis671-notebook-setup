#!/usr/bin/env bash
set -Eeuo pipefail

check_only=false
[[ ${1:-} == --check ]] && check_only=true
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<'EOF'
Uso: configurar_audio.sh [--check]

Evita que el ahorro de energía de snd_hda_intel apague y reactive el códec
Realtek ALC662, y mantiene desactivado el auto-mute del conector auxiliar.
EOF
    exit 0
fi

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null || { echo 'Falta sudo.' >&2; exit 1; }
    sudo_cmd=(sudo)
fi

options_file=/etc/modprobe.d/snd-hda-no-power-save.conf
expected_options='options snd_hda_intel power_save=0 power_save_controller=N'

if $check_only; then
    [[ -r $options_file ]] && grep -Fxq "$expected_options" "$options_file" \
        || { echo 'PENDIENTE: el ahorro de energía HDA sigue habilitado.'; exit 1; }
    [[ $(cat /sys/module/snd_hda_intel/parameters/power_save 2>/dev/null) == 0 ]] \
        || { echo 'PENDIENTE: snd_hda_intel todavía usa power_save.'; exit 1; }
    echo 'OK: el audio HDA permanece activo y el conector auxiliar es estable.'
    exit 0
fi

printf '%s\n' "$expected_options" \
    | "${sudo_cmd[@]}" tee "$options_file" >/dev/null

if [[ -e /sys/module/snd_hda_intel/parameters/power_save ]]; then
    printf '0\n' \
        | "${sudo_cmd[@]}" tee /sys/module/snd_hda_intel/parameters/power_save >/dev/null
fi
if [[ -e /sys/module/snd_hda_intel/parameters/power_save_controller ]]; then
    printf 'N\n' \
        | "${sudo_cmd[@]}" tee /sys/module/snd_hda_intel/parameters/power_save_controller >/dev/null
fi

if command -v amixer >/dev/null 2>&1; then
    amixer -c 0 set 'Auto-Mute Mode' Disabled >/dev/null 2>&1 || true
fi
if [[ -x /usr/sbin/alsactl ]]; then
    "${sudo_cmd[@]}" /usr/sbin/alsactl store 0
fi

echo 'Audio configurado sin ahorro de energía HDA ni auto-mute.'
