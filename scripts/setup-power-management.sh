#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-audit}"
if [[ $# -gt 0 ]]; then shift; fi

desktop_user=""
swap_file="/swap/swap"
swap_size_gib="5"
assume_yes="false"
hibernate_on_lid="true"
audit_failures=0
reboot_required="false"

usage() {
  cat <<'EOF'
Uso:
  setup-power-management.sh audit [opciones]
  sudo setup-power-management.sh apply [opciones]

Acciones:
  audit   Inspecciona suspensión, hibernación, swap y resume sin modificar.
  apply   Desactiva suspensión, habilita hibernación y configura resume.

Opciones:
  --desktop-user USUARIO   Usuario del entorno gráfico. Por defecto usa
                           SUDO_USER o el propietario de este script.
  --swap-file RUTA         Swapfile que se crea si no hay swap activo
                           (default: /swap/swap).
  --swap-size-gib N        Tamaño del swapfile nuevo (default: 5 GiB).
  --hibernate-on-lid       Hiberna al cerrar la tapa (predeterminado).
  --no-hibernate-on-lid    Deja la tapa sin acción automática.
  --yes                    Aplica sin pedir confirmación.
  -h, --help               Muestra esta ayuda.

Después de cambiar el disco o reinstalar antiX:
  sudo ./setup-power-management.sh apply --desktop-user "$USER"

El script nunca prueba la hibernación automáticamente.
EOF
}

pass() { printf '✓ %s\n' "$*"; }
info() { printf 'ℹ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; audit_failures=$((audit_failures + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop-user)
      [[ $# -ge 2 ]] || die "Falta el valor de --desktop-user."
      desktop_user="$2"
      shift 2
      ;;
    --swap-file)
      [[ $# -ge 2 ]] || die "Falta el valor de --swap-file."
      swap_file="$2"
      shift 2
      ;;
    --swap-size-gib)
      [[ $# -ge 2 ]] || die "Falta el valor de --swap-size-gib."
      swap_size_gib="$2"
      shift 2
      ;;
    --yes)
      assume_yes="true"
      shift
      ;;
    --hibernate-on-lid)
      hibernate_on_lid="true"
      shift
      ;;
    --no-hibernate-on-lid)
      hibernate_on_lid="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Opción desconocida: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${action}" == "-h" || "${action}" == "--help" ]]; then
  usage
  exit 0
fi

[[ "${action}" == "audit" || "${action}" == "apply" ]] \
  || { printf 'Acción desconocida: %s\n' "${action}" >&2; usage >&2; exit 2; }
[[ "${swap_file}" == /* && "${swap_file}" != "/" ]] \
  || die "Ruta de swap insegura: ${swap_file}"
[[ "${swap_size_gib}" =~ ^[0-9]+$ ]] \
  || die "--swap-size-gib debe ser un entero."
(( 10#${swap_size_gib} >= 1 && 10#${swap_size_gib} <= 64 )) \
  || die "--swap-size-gib debe estar entre 1 y 64."

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

detect_desktop_user() {
  if [[ -n "${desktop_user}" ]]; then
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    desktop_user="${SUDO_USER}"
    return
  fi
  desktop_user="$(stat -c '%U' "$0" 2>/dev/null || true)"
  [[ "${desktop_user}" != "root" ]] || desktop_user=""
}

validate_desktop_user() {
  detect_desktop_user
  [[ "${desktop_user}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] \
    || die "No se pudo determinar un usuario gráfico válido. Usá --desktop-user."
  id "${desktop_user}" >/dev/null 2>&1 \
    || die "El usuario ${desktop_user} no existe."
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "La acción apply requiere root. Usá sudo."
}

confirm_apply() {
  [[ "${assume_yes}" == "true" ]] && return
  [[ -t 0 ]] || die "apply requiere una terminal interactiva o --yes."
  printf '\nSe desactivará suspensión a RAM y el evento de tapa.\n'
  printf 'Se habilitará hibernación y se actualizarán GRUB/initramfs.\n'
  printf 'No se hibernará ni reiniciará automáticamente.\n'
  printf 'Escribí APLICAR para continuar: '
  local response
  read -r response
  [[ "${response}" == "APLICAR" ]] || die "Configuración cancelada."
}

active_swap_record() {
  swapon --show=NAME,TYPE,SIZE --bytes --noheadings --raw 2>/dev/null \
    | sort -k3,3nr \
    | head -1
}

ensure_swap() {
  local record
  record="$(active_swap_record || true)"
  if [[ -n "${record}" ]]; then
    pass "Swap activo detectado: $(awk '{print $1}' <<< "${record}")"
    return
  fi

  [[ ! -e "${swap_file}" ]] \
    || die "${swap_file} existe, pero no está activo. Revisalo antes de continuar."
  local swap_parent
  swap_parent="$(dirname "${swap_file}")"
  install -d -m 0700 "${swap_parent}"
  info "Creando swapfile de ${swap_size_gib} GiB en ${swap_file}."
  fallocate -l "${swap_size_gib}G" "${swap_file}"
  chmod 0600 "${swap_file}"
  mkswap "${swap_file}"
  swapon "${swap_file}"

  if ! awk -v path="${swap_file}" \
    '$1 == path && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
    printf '%s swap swap defaults 0 0\n' "${swap_file}" >> /etc/fstab
  fi
  pass "Swapfile creado y agregado a /etc/fstab."
}

verify_swap_capacity() {
  local record swap_bytes memory_bytes
  record="$(active_swap_record)"
  swap_bytes="$(awk '{print $3}' <<< "${record}")"
  memory_bytes="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))"
  if (( swap_bytes < memory_bytes )); then
    die "El swap activo es menor que la RAM. Se necesitan al menos ${memory_bytes} bytes."
  fi
  pass "Capacidad de swap suficiente para la RAM visible."
}

calculate_resume() {
  local record swap_name swap_type
  record="$(active_swap_record)"
  swap_name="$(awk '{print $1}' <<< "${record}")"
  swap_type="$(awk '{print $2}' <<< "${record}")"

  resume_offset=""
  if [[ "${swap_type}" == "partition" ]]; then
    local swap_uuid
    swap_uuid="$(blkid -s UUID -o value "${swap_name}")"
    [[ -n "${swap_uuid}" ]] || die "No se obtuvo el UUID de ${swap_name}."
    resume_spec="UUID=${swap_uuid}"
    resume_description="partición ${swap_name}"
    return
  fi

  [[ "${swap_type}" == "file" ]] \
    || die "Tipo de swap no soportado para hibernación: ${swap_type}"
  swap_name="$(readlink -f "${swap_name}")"
  local filesystem_type filesystem_uuid physical_block fs_block_size page_size
  filesystem_type="$(findmnt -no FSTYPE -T "${swap_name}")"
  filesystem_uuid="$(findmnt -no UUID -T "${swap_name}")"
  [[ "${filesystem_type}" == "ext4" ]] \
    || die "El cálculo automático de resume_offset sólo soporta swapfile sobre ext4; detectado ${filesystem_type}."
  [[ -n "${filesystem_uuid}" ]] \
    || die "No se obtuvo el UUID del filesystem que contiene ${swap_name}."

  physical_block="$(filefrag -v "${swap_name}" 2>/dev/null \
    | awk '$1 == "0:" { value=$4; sub(/\.\..*/, "", value); print value; exit }')"
  [[ "${physical_block}" =~ ^[0-9]+$ ]] \
    || die "No se pudo calcular el primer bloque físico de ${swap_name}."
  fs_block_size="$(stat -f -c '%S' "${swap_name}")"
  page_size="$(getconf PAGESIZE)"
  (( (physical_block * fs_block_size) % page_size == 0 )) \
    || die "El offset del swapfile no es divisible por el tamaño de página."

  resume_offset="$(( physical_block * fs_block_size / page_size ))"
  resume_spec="UUID=${filesystem_uuid}"
  resume_description="swapfile ${swap_name} sobre ${filesystem_type}"
}

write_resume_configuration() {
  calculate_resume
  install -d -m 0755 /etc/initramfs-tools/conf.d
  local resume_temp
  resume_temp="$(mktemp /etc/initramfs-tools/conf.d/resume.XXXXXX)"
  printf 'RESUME=%s\n' "${resume_spec}" > "${resume_temp}"
  chmod 0644 "${resume_temp}"
  mv "${resume_temp}" /etc/initramfs-tools/conf.d/resume

  local grub_file current_line current_value token
  local -a current_tokens=() filtered_tokens=()
  grub_file="/etc/default/grub"
  [[ -r "${grub_file}" ]] || die "No existe ${grub_file}."
  current_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${grub_file}" | tail -1 || true)"
  current_value="${current_line#*=}"
  current_value="${current_value#\"}"
  current_value="${current_value%\"}"
  read -r -a current_tokens <<< "${current_value}"
  for token in "${current_tokens[@]}"; do
    case "${token}" in
      resume=*|resume_offset=*) ;;
      *) filtered_tokens+=("${token}") ;;
    esac
  done
  filtered_tokens+=("resume=${resume_spec}")
  [[ -z "${resume_offset}" ]] \
    || filtered_tokens+=("resume_offset=${resume_offset}")

  local replacement grub_temp
  replacement="GRUB_CMDLINE_LINUX_DEFAULT=\"${filtered_tokens[*]}\""
  grub_temp="$(mktemp /etc/default/grub.XXXXXX)"
  awk -v replacement="${replacement}" '
    BEGIN { replaced=0 }
    /^GRUB_CMDLINE_LINUX_DEFAULT=/ { print replacement; replaced=1; next }
    { print }
    END { if (!replaced) print replacement }
  ' "${grub_file}" > "${grub_temp}"
  chmod --reference="${grub_file}" "${grub_temp}"
  chown --reference="${grub_file}" "${grub_temp}"
  mv "${grub_temp}" "${grub_file}"

  info "Actualizando initramfs y GRUB para ${resume_description}."
  update-initramfs -u -k all
  update-grub
  pass "Resume configurado: ${resume_spec}${resume_offset:+ offset=${resume_offset}}"

  if [[ " $(cat /proc/cmdline) " != *" resume=${resume_spec} "* ]]; then
    reboot_required="true"
  elif [[ -n "${resume_offset}" \
    && " $(cat /proc/cmdline) " != *" resume_offset=${resume_offset} "* ]]; then
    reboot_required="true"
  fi
}

ensure_diversion() {
  local target="$1"
  local diverted="${target}.suspend-enabled"
  [[ -e "${target}" || -e "${diverted}" ]] \
    || die "No existe el archivo requerido: ${target}"
  if dpkg-divert --list "${target}" 2>/dev/null | grep -Fq "${diverted}"; then
    return
  fi
  dpkg-divert --quiet --local --rename --add --divert "${diverted}" "${target}"
}

install_from_diverted() {
  local generated_file="$1"
  local target="$2"
  local mode="$3"
  chmod "${mode}" "${generated_file}"
  chown root:root "${generated_file}"
  mv "${generated_file}" "${target}"
}

disable_acpi_event() {
  local target="$1"
  [[ -e "${target}" ]] || return
  ensure_diversion "${target}"
  local source_file="${target}.suspend-enabled"
  local generated_file
  generated_file="$(mktemp "${target}.XXXXXX")"
  sed -E 's#^action=.*#action=/bin/true#' "${source_file}" > "${generated_file}"
  grep -q '^action=/bin/true$' "${generated_file}" \
    || die "No se pudo neutralizar ${target}."
  install_from_diverted "${generated_file}" "${target}" 0644
}

configure_lid_hibernate() {
  local event_file handler event_temp handler_temp elogind_temp
  event_file="/etc/acpi/events/lidbtn"
  handler="/etc/acpi/notebook-lid-hibernate.sh"
  ensure_diversion "${event_file}"

  event_temp="$(mktemp "${event_file}.XXXXXX")"
  cat > "${event_temp}" <<'EOF'
# Hibernar solamente cuando la tapa queda realmente cerrada.
event=button[ /]lid
action=/etc/acpi/notebook-lid-hibernate.sh
EOF
  install_from_diverted "${event_temp}" "${event_file}" 0644

  handler_temp="$(mktemp "${handler}.XXXXXX")"
  cat > "${handler_temp}" <<'EOF'
#!/bin/sh
set -u

# acpid también emite un evento al abrir. En ese caso no hacer nada.
grep -qis 'closed' /proc/acpi/button/lid/*/state 2>/dev/null || exit 0

# Algunos firmware emiten el mismo evento dos veces.
install -d -m 0755 /run/lock
exec 9>/run/lock/notebook-lid-hibernate.lock
flock -n 9 || exit 0

logger -t notebook-lid "Tapa cerrada: iniciando hibernación."
exec /usr/sbin/pm-hibernate
EOF
  install_from_diverted "${handler_temp}" "${handler}" 0755

  # acpid es el único encargado de la tapa; evita una suspensión simultánea.
  install -d -m 0755 /etc/elogind/logind.conf.d
  elogind_temp="$(mktemp /etc/elogind/logind.conf.d/90-notebook-lid.XXXXXX)"
  cat > "${elogind_temp}" <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
  chmod 0644 "${elogind_temp}"
  mv "${elogind_temp}" /etc/elogind/logind.conf.d/90-notebook-lid.conf
}

configure_acpi() {
  if [[ "${hibernate_on_lid}" == "true" ]]; then
    configure_lid_hibernate
  else
    disable_acpi_event /etc/acpi/events/lidbtn
    rm -f /etc/acpi/notebook-lid-hibernate.sh \
      /etc/elogind/logind.conf.d/90-notebook-lid.conf
  fi
  disable_acpi_event /etc/acpi/events/sleepbtn
  disable_acpi_event /etc/acpi/events/sony-sleep
  if command -v sv >/dev/null 2>&1 && [[ -e /etc/service/acpid ]]; then
    sv restart /etc/service/acpid
  elif [[ -x /etc/init.d/acpid ]]; then
    /etc/init.d/acpid restart
  else
    die "No se encontró cómo reiniciar acpid."
  fi
  if [[ "${hibernate_on_lid}" == "true" ]]; then
    pass "Cierre de tapa configurado para hibernar; suspensión neutralizada."
  else
    pass "Tapa y botones de suspensión a RAM neutralizados."
  fi
}

configure_desktop_menu() {
  local gui_file backend_file gui_source backend_source generated_file
  gui_file="/usr/local/lib/desktop-session/desktop-session-exit.py"
  backend_file="/usr/local/bin/desktop-session-exit"
  ensure_diversion "${gui_file}"
  ensure_diversion "${backend_file}"
  gui_source="${gui_file}.suspend-enabled"
  backend_source="${backend_file}.suspend-enabled"

  generated_file="$(mktemp "${gui_file}.XXXXXX")"
  sed \
    -e 's/^        #self\.build_button("system-hibernate"/        self.build_button("system-hibernate"/' \
    -e 's/^        self\.build_button("system-suspend"/        #self.build_button("system-suspend"/' \
    "${gui_source}" > "${generated_file}"
  grep -q '^        self.build_button("system-hibernate"' "${generated_file}" \
    || die "No se pudo habilitar Hibernate en ${gui_file}."
  if grep -q '^        self.build_button("system-suspend"' "${generated_file}"; then
    die "No se pudo ocultar Suspend en ${gui_file}."
  fi
  install_from_diverted "${generated_file}" "${gui_file}" 0755

  generated_file="$(mktemp "${backend_file}.XXXXXX")"
  sed \
    -e "s/OPTION\[5\]='-S | S | --suspend'/OPTION[5]='--suspend-disabled'/" \
    -e "s/TXT\[5\]='Set the machine into suspend'/TXT[5]='Suspend to RAM is disabled'/" \
    -e '/^[[:space:]]*sudo pm-suspend[[:space:]]*$/c\            printf '\''Suspend to RAM is disabled on this machine.\\n'\'' >&2\n            return 1' \
    "${backend_source}" > "${generated_file}"
  if grep -q 'sudo pm-suspend' "${generated_file}"; then
    die "No se pudo bloquear pm-suspend en ${backend_file}."
  fi
  install_from_diverted "${generated_file}" "${backend_file}" 0755
  pass "Menú de IceWM configurado con Hibernate y sin Suspend."
}

configure_pm_utils() {
  install -d -m 0755 /etc/pm/config.d
  local pm_temp
  pm_temp="$(mktemp /etc/pm/config.d/10-hibernate-only.XXXXXX)"
  cat > "${pm_temp}" <<'EOF'
# Configuración local: usar apagado completo al escribir la imagen.
HIBERNATE_MODE="shutdown"
HIBERNATE_RESUME_POST_VIDEO="no"
# Esta SiS puede perder la pantalla al cambiar de VT o restaurar el modo de video.
ADD_PARAMETERS="--quirk-none --quirk-no-chvt"
EOF
  chmod 0644 "${pm_temp}"
  mv "${pm_temp}" /etc/pm/config.d/10-hibernate-only
  pass "pm-utils configurado para hibernación por apagado."
}

configure_hibernate_session_guard() {
  validate_desktop_user
  install -d -m 0755 /etc/pm/sleep.d

  local hook_temp startup_file startup_temp
  hook_temp="$(mktemp /etc/pm/sleep.d/00-session-guard.XXXXXX)"
  cat > "${hook_temp}" <<EOF
#!/bin/sh
# Cierra X antes de hibernar y recupera la red al volver.
desktop_user="${desktop_user}"
marker_dir="/var/lib/notebook-session-guard/\${desktop_user}"
firefox_marker="\${marker_dir}/restore-firefox"
display_marker="/tmp/restart-slimski-after-hibernate"
log_file="/var/log/hibernate-session-guard.log"
log() { printf '%s %s\\n' "\$(date '+%F %T')" "\$*" >>"\${log_file}"; }
firefox_running() {
  pgrep -u "\${desktop_user}" -x firefox-esr >/dev/null 2>&1 \\
    || pgrep -u "\${desktop_user}" -x firefox >/dev/null 2>&1
}
case "\${1:-}" in
  hibernate)
    log "Preparando la sesión antes de hibernar."
    install -d -o "\${desktop_user}" -g "\${desktop_user}" -m 0700 "\${marker_dir}"
    if firefox_running; then
      : >"\${firefox_marker}"
      chown "\${desktop_user}:\${desktop_user}" "\${firefox_marker}"
      main_pid="\$(pgrep -u "\${desktop_user}" -o -x firefox-esr 2>/dev/null \\
        || pgrep -u "\${desktop_user}" -o -x firefox 2>/dev/null || true)"
      if [ -n "\${main_pid}" ]; then
        kill -TERM "\${main_pid}" 2>/dev/null || true
        count=0
        while firefox_running && [ "\${count}" -lt 20 ]; do
          sleep 1
          count=\$((count + 1))
        done
      fi
      log "Firefox cerrado; se solicitará restaurar sus pestañas al volver."
    else
      rm -f "\${firefox_marker}"
    fi
    if [ -e /etc/service/psd-${desktop_user} ]; then
      sv restart /etc/service/psd-${desktop_user} >/dev/null 2>&1 || true
    fi
    sync
    if sv status /etc/service/slimski 2>/dev/null | grep -q '^run:'; then
      : >"\${display_marker}"
      sv down /etc/service/slimski >/dev/null 2>&1 || true
      if [ -x /usr/local/bin/notebook-console-animation ]; then
        /usr/local/bin/notebook-console-animation hibernate /dev/tty1
      fi
      log "Interfaz gráfica detenida de forma controlada."
    else
      rm -f "\${display_marker}"
    fi
    ;;
  thaw)
    if [ -e /etc/service/connman ]; then
      sv restart /etc/service/connman >/dev/null 2>&1 || true
    elif [ -x /etc/init.d/connman ]; then
      /etc/init.d/connman restart >/dev/null 2>&1 || true
    fi
    count=0
    while ! ip -4 address show dev wlan0 2>/dev/null | grep -q 'inet ' \\
      && [ "\${count}" -lt 15 ]; do
      sleep 1
      count=\$((count + 1))
    done
    if ip -4 address show dev wlan0 2>/dev/null | grep -q 'inet '; then
      log "Red Wi-Fi recuperada después de reanudar."
    else
      log "Aviso: Wi-Fi no obtuvo dirección tras 15 segundos."
    fi
    if [ -f "\${display_marker}" ]; then
      rm -f "\${display_marker}"
      sv up /etc/service/slimski >/dev/null 2>&1 || true
      log "Interfaz gráfica reiniciada después de reanudar."
    fi
    ;;
esac
exit 0
EOF
  chmod 0755 "${hook_temp}"
  mv "${hook_temp}" /etc/pm/sleep.d/00-session-guard

  startup_file="$(getent passwd "${desktop_user}" | cut -d: -f6)/.desktop-session/startup"
  install -d -m 0755 -o "${desktop_user}" -g "${desktop_user}" "$(dirname "${startup_file}")"
  touch "${startup_file}"
  chown "${desktop_user}:${desktop_user}" "${startup_file}"
  chmod 0755 "${startup_file}"
  startup_temp="$(mktemp "${startup_file}.XXXXXX")"
  awk '
    $0 == "# BEGIN notebook-hibernate-firefox" { skip=1; next }
    $0 == "# END notebook-hibernate-firefox" { skip=0; next }
    !skip { print }
  ' "${startup_file}" >"${startup_temp}"
  cat >>"${startup_temp}" <<'EOF'

# BEGIN notebook-hibernate-firefox
# Esta marca persiste incluso si el firmware hace un arranque limpio.
hibernate_firefox_marker="/var/lib/notebook-session-guard/$(id -un)/restore-firefox"
if [ -f "$hibernate_firefox_marker" ]; then
    rm -f "$hibernate_firefox_marker"
    (sleep 6 && "$HOME/.local/bin/firefox-wait" --restore-last-session) &
fi
# END notebook-hibernate-firefox
EOF
  chown "${desktop_user}:${desktop_user}" "${startup_temp}"
  chmod 0755 "${startup_temp}"
  mv "${startup_temp}" "${startup_file}"
  pass "Sesión gráfica protegida y Firefox configurado para restaurarse."
}

disable_suspend_command() {
  local target="$1"
  [[ -e "${target}" ]] || return
  ensure_diversion "${target}"
  local generated_file
  generated_file="$(mktemp "${target}.XXXXXX")"
  cat > "${generated_file}" <<'EOF'
#!/bin/sh
printf 'Suspend to RAM is disabled on this machine; use pm-hibernate.\n' >&2
exit 1
EOF
  install_from_diverted "${generated_file}" "${target}" 0755
}

disable_suspend_commands() {
  disable_suspend_command /usr/sbin/pm-suspend
  disable_suspend_command /usr/sbin/pm-suspend-hybrid
  pass "Comandos pm-suspend bloqueados."
}

configure_hibernate_sudo() {
  validate_desktop_user
  command -v visudo >/dev/null 2>&1 || die "Falta visudo."
  local sudoers_file sudoers_temp
  sudoers_file="/etc/sudoers.d/90-${desktop_user}-hibernate"
  sudoers_temp="$(mktemp /etc/sudoers.d/90-hibernate.XXXXXX)"
  printf '%s ALL=(root) NOPASSWD: /usr/sbin/pm-hibernate\n' "${desktop_user}" \
    > "${sudoers_temp}"
  chmod 0440 "${sudoers_temp}"
  visudo -cf "${sudoers_temp}" >/dev/null
  mv "${sudoers_temp}" "${sudoers_file}"
  pass "${desktop_user} puede hibernar desde el menú sin contraseña."
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  local -a missing_commands=()
  local required_command
  for required_command in acpid pm-hibernate pm-is-supported filefrag \
    swapon mkswap findmnt update-initramfs update-grub dpkg-divert visudo; do
    command -v "${required_command}" >/dev/null 2>&1 \
      || missing_commands+=("${required_command}")
  done
  if (( ${#missing_commands[@]} == 0 )); then
    pass "Dependencias presentes."
    return
  fi
  info "Instalando dependencias faltantes: ${missing_commands[*]}"
  apt-get update
  apt-get install --yes --no-install-recommends \
    acpid pm-utils e2fsprogs util-linux initramfs-tools grub-common sudo
}

audit_power() {
  audit_failures=0
  detect_desktop_user
  info "Usuario gráfico: ${desktop_user:-no determinado}"

  if grep -qw disk /sys/power/state 2>/dev/null; then
    pass "El kernel soporta hibernación."
  else
    fail "El kernel no anuncia hibernación en /sys/power/state."
  fi
  if command -v pm-is-supported >/dev/null 2>&1 && pm-is-supported --hibernate; then
    pass "pm-utils reconoce hibernación."
  else
    fail "pm-utils no reconoce hibernación."
  fi

  local record swap_name swap_bytes memory_bytes
  record="$(active_swap_record || true)"
  if [[ -z "${record}" ]]; then
    fail "No hay swap activo."
  else
    swap_name="$(awk '{print $1}' <<< "${record}")"
    swap_bytes="$(awk '{print $3}' <<< "${record}")"
    memory_bytes="$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))"
    info "Swap activo: ${swap_name} ($((swap_bytes / 1024 / 1024)) MiB)"
    (( swap_bytes >= memory_bytes )) \
      && pass "Swap suficiente para la RAM visible." \
      || fail "El swap es menor que la RAM visible."
  fi

  if [[ -r /etc/acpi/events/lidbtn ]] \
    && grep -q '^action=/etc/acpi/notebook-lid-hibernate.sh$' /etc/acpi/events/lidbtn \
    && [[ -x /etc/acpi/notebook-lid-hibernate.sh ]]; then
    pass "Cierre de tapa configurado para hibernar."
  elif [[ -r /etc/acpi/events/lidbtn ]] \
    && grep -q '^action=/bin/true$' /etc/acpi/events/lidbtn; then
    pass "Cierre de tapa sin acción automática."
  else
    fail "El comportamiento de la tapa no está configurado."
  fi
  if [[ -r /etc/acpi/events/sleepbtn ]] \
    && grep -q '^action=/bin/true$' /etc/acpi/events/sleepbtn; then
    pass "Botón de suspensión neutralizado."
  else
    fail "El botón de suspensión todavía está activo."
  fi

  local gui_file backend_file
  gui_file="/usr/local/lib/desktop-session/desktop-session-exit.py"
  backend_file="/usr/local/bin/desktop-session-exit"
  if [[ -r "${gui_file}" ]] \
    && grep -q '^        self.build_button("system-hibernate"' "${gui_file}" \
    && ! grep -q '^        self.build_button("system-suspend"' "${gui_file}"; then
    pass "Menú gráfico: Hibernate visible y Suspend oculto."
  else
    fail "El menú gráfico todavía no tiene la configuración solicitada."
  fi
  if [[ -r "${backend_file}" ]] && ! grep -q 'sudo pm-suspend' "${backend_file}"; then
    pass "Comando de suspensión del menú bloqueado."
  else
    fail "El backend del menú todavía permite pm-suspend."
  fi
  if [[ -x /usr/sbin/pm-suspend ]] \
    && grep -q 'Suspend to RAM is disabled' /usr/sbin/pm-suspend; then
    pass "pm-suspend bloqueado a nivel del sistema."
  else
    fail "pm-suspend todavía no está bloqueado."
  fi

  if [[ -r /etc/initramfs-tools/conf.d/resume ]]; then
    pass "Configuración initramfs de resume presente."
    sed 's/^/  /' /etc/initramfs-tools/conf.d/resume
  else
    fail "Falta /etc/initramfs-tools/conf.d/resume."
  fi
  if grep -q 'resume=' /proc/cmdline; then
    pass "El kernel arrancó con resume configurado."
  else
    warn "El kernel actual todavía no tiene resume; será necesario reiniciar."
  fi

  if (( audit_failures > 0 )); then
    printf 'Auditoría finalizada con %d problema(s).\n' "${audit_failures}" >&2
    return 1
  fi
  pass "Configuración de energía verificada."
}

if [[ "${action}" == "audit" ]]; then
  audit_power
  exit
fi

require_root
validate_desktop_user
confirm_apply
install_dependencies
ensure_swap
verify_swap_capacity
configure_pm_utils
configure_hibernate_session_guard
disable_suspend_commands
configure_acpi
configure_desktop_menu
configure_hibernate_sudo
write_resume_configuration

printf '\n'
audit_power
printf '\n'
if [[ "${reboot_required}" == "true" ]]; then
  warn "Reiniciá una vez antes de probar Hibernate para activar el nuevo resume."
else
  pass "El kernel actual ya usa el UUID y offset calculados."
fi
warn "La hibernación no se probó automáticamente. Guardá tu trabajo antes de probarla."
