#!/usr/bin/env bash
set -Eeuo pipefail

check_only=false
[[ ${1:-} == --check ]] && check_only=true
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<'EOF'
Uso: configurar_arranque_visual.sh [--check]

Oculta el menu de GRUB (queda accesible con Esc), fija una espera de 1 segundo
y configura un arranque silencioso compatible con la GPU SiS. Muestra una
animacion de texto durante el arranque y el apagado. No reinicia.
EOF
    exit 0
fi

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    sudo_cmd=(sudo)
fi

fragment=/etc/default/grub.d/99-notebook-visual.cfg

if $check_only; then
    if "${sudo_cmd[@]}" test -r "$fragment" \
        && "${sudo_cmd[@]}" grep -q '^GRUB_TIMEOUT=1$' "$fragment" \
        && "${sudo_cmd[@]}" grep -q 'quiet loglevel=3' "$fragment" \
        && "${sudo_cmd[@]}" grep -q 'nomodeset' "$fragment" \
        && "${sudo_cmd[@]}" grep -q '^GRUB_GFXPAYLOAD_LINUX=text$' "$fragment"; then
        echo 'OK: GRUB espera 1 segundo y el arranque silencioso esta configurado.'
        exit 0
    fi
    echo 'PENDIENTE: falta configurar el arranque visual.'
    exit 1
fi

# Plymouth deja un framebuffer activo que interfiere con esta GPU SiS.
# Restaurar los componentes nativos de antiX y retirar Plymouth si existe.
if dpkg-query -W -f='${db:Status-Abbrev}' plymouth 2>/dev/null | grep -q '^ii'; then
    "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive \
        apt-get purge -y plymouth plymouth-label plymouth-themes
fi
"${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y bootlogd console-common

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT
cat >"$tmp_file" <<'EOF'
# Configuracion de arranque para la notebook Founder/SiS.
# Esc durante el arranque muestra el menu de GRUB.
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=1
GRUB_GFXMODE=1024x768
GRUB_GFXPAYLOAD_LINUX=text

# Conservar parametros existentes (resume, selinux, etc.) y reducir mensajes.
for notebook_parameter in quiet loglevel=3 vt.global_cursor_default=0 nomodeset; do
    case " ${GRUB_CMDLINE_LINUX_DEFAULT:-} " in
        *" ${notebook_parameter} "*) ;;
        *) GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT:-} ${notebook_parameter}" ;;
    esac
done
EOF

"${sudo_cmd[@]}" install -d -o root -g root -m 0755 /etc/default/grub.d
if "${sudo_cmd[@]}" test -f "$fragment" && ! "${sudo_cmd[@]}" cmp -s "$tmp_file" "$fragment"; then
    backup="${fragment}.backup-$(date +%Y%m%d-%H%M%S)"
    "${sudo_cmd[@]}" cp -a "$fragment" "$backup"
    echo "Copia de seguridad: $backup"
fi
"${sudo_cmd[@]}" install -o root -g root -m 0644 "$tmp_file" "$fragment"

"${sudo_cmd[@]}" update-grub

# Plymouth deja el framebuffer activo y puede impedir que SiS controle la GPU. Esta
# alternativa usa solamente la consola VGA de texto y es segura.
console_animation=$(mktemp)
cat >"$console_animation" <<'EOF'
#!/bin/sh
mode="${1:-boot}"
tty="${2:-/dev/tty1}"
[ -w "$tty" ] || exit 0
pid_file="/run/notebook-console-animation-${mode}.pid"
if [ -r "$pid_file" ]; then
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -z "$old_pid" ] || ! kill -0 "$old_pid" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" >"$pid_file"
cleanup() {
    rm -f "$pid_file"
    printf '\033[?25h' >"$tty"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

case "$mode" in
    shutdown) title='APAGANDO NOTEBOOK'; final='EQUIPO APAGADO' ;;
    hibernate) title='GUARDANDO SESION'; final='SESION GUARDADA' ;;
    *) title='INICIANDO NOTEBOOK'; final='ESCRITORIO LISTO' ;;
esac

draw_frame() {
    step="$1"
    case $((step % 11)) in
        0) bar='[                    ]' ;; 1) bar='[##                  ]' ;;
        2) bar='[####                ]' ;; 3) bar='[######              ]' ;;
        4) bar='[########            ]' ;; 5) bar='[##########          ]' ;;
        6) bar='[############        ]' ;; 7) bar='[##############      ]' ;;
        8) bar='[################    ]' ;; 9) bar='[##################  ]' ;;
        *) bar='[####################]' ;;
    esac
    case $((step % 4)) in
        0) spinner='|' ;; 1) spinner='/' ;; 2) spinner='-' ;; *) spinner='\\' ;;
    esac
    printf '\033[2J\033[H\n\n\n\033[1;36m          %s\033[0m\n\n              [%s]\n\n          %s\n' \
        "$title" "$spinner" "$bar" >"$tty"
}

printf '\033[?25l' >"$tty"
step=0
case "$mode" in
    boot)
        # Seguir hasta que Xorg tome la pantalla, con un límite de seguridad.
        while ! pgrep -x Xorg >/dev/null 2>&1 && [ "$step" -lt 750 ]; do
            draw_frame "$step"
            step=$((step + 1))
            sleep 0.08
        done
        ;;
    shutdown)
        # El corte de energía finaliza este proceso junto con el sistema.
        while :; do
            draw_frame "$step"
            step=$((step + 1))
            sleep 0.08
        done
        ;;
    *)
        while [ "$step" -lt 11 ]; do
            draw_frame "$step"
            step=$((step + 1))
            sleep 0.08
        done
        ;;
esac
printf '\033[H\n\n\n\033[1;32m          %s\033[0m\n\n               [OK]\n\033[?25h' \
    "$final" >"$tty"
sleep 0.18
EOF
"${sudo_cmd[@]}" install -m 0755 "$console_animation" /usr/local/bin/notebook-console-animation

patch_runit_stage() {
    stage_file="$1"
    mode="$2"
    stage_name="${stage_file##*/}"
    clean_file=$(mktemp)
    block_file=$(mktemp)
    output_file=$(mktemp)

    "${sudo_cmd[@]}" awk '
        $0 == "# BEGIN notebook-console-animation" { skip=1; next }
        $0 == "# END notebook-console-animation" { skip=0; next }
        !skip { print }
    ' "$stage_file" >"$clean_file"

    cat >"$block_file" <<EOF
# BEGIN notebook-console-animation
# El spinner escribe en tty1; la salida técnica queda en /run hasta reiniciar.
if [ -x /usr/local/bin/notebook-console-animation ]; then
    /usr/local/bin/notebook-console-animation ${mode} /dev/tty1 </dev/null >/dev/null 2>&1 &
    if : >>/run/notebook-runit-stage${stage_name}.log 2>/dev/null; then
        exec >>/run/notebook-runit-stage${stage_name}.log 2>&1
    else
        exec >/dev/null 2>&1
    fi
fi
# END notebook-console-animation
EOF

    awk -v block_file="$block_file" '
        { print }
        $0 == "export PATH" {
            while ((getline line < block_file) > 0) print line
            close(block_file)
        }
    ' "$clean_file" >"$output_file"

    if ! "${sudo_cmd[@]}" cmp -s "$output_file" "$stage_file"; then
        "${sudo_cmd[@]}" cp -a "$stage_file" \
            "${stage_file}.before-notebook-animation-$(date +%Y%m%d-%H%M%S)"
        "${sudo_cmd[@]}" install -m 0755 "$output_file" "$stage_file"
    fi
    rm -f "$clean_file" "$block_file" "$output_file"
}

patch_runit_stage /etc/runit/1 boot
patch_runit_stage /etc/runit/3 shutdown

# Retirar los hooks anteriores: ahora se inicia antes de cualquier mensaje.
"${sudo_cmd[@]}" rm -f \
    /etc/runit/boot-run/S04z-notebook-animation.stage1.sh \
    /etc/runit/boot-run/S99z-notebook-animation.stage1.sh \
    /etc/runit/shutdown-run/K05-notebook-animation.stage3.sh \
    /etc/runit/shutdown-run/K46-notebook-animation.stage3.sh
rm -f "$console_animation"

echo 'Arranque silencioso configurado. Se aplicara en el proximo reinicio.'
echo 'Pulsa Esc durante el arranque para mostrar el menu de GRUB.'
echo 'Animacion de consola para inicio y apagado configurada.'
