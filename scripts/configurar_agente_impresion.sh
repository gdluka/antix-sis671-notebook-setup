#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 ]]; then
    echo 'Ejecuta este script como usuario normal, sin sudo.' >&2
    exit 1
fi

app_url="${ECOMMERCE_APP_URL:-https://app.invisibleweb.com.ar}"
agent_binary="${XDG_DATA_HOME:-${HOME}/.local/share}/ecommerce-print-agent/ecommerce-print-agent"
startup_file="$HOME/.desktop-session/startup"
begin_marker='# BEGIN notebook-ecommerce-print-agent'
end_marker='# END notebook-ecommerce-print-agent'

if [[ ! -x $agent_binary ]]; then
    echo "El agente todavía no está instalado en $agent_binary." >&2
    echo 'Descargalo e instalalo desde Ecommerce antes de ejecutar este script.' >&2
    exit 1
fi

mkdir -p "$(dirname "$startup_file")"
touch "$startup_file"
backup="${startup_file}.backup-agent-$(date +%Y%m%d-%H%M%S)"
cp -a "$startup_file" "$backup"
startup_tmp=$(mktemp)
trap 'rm -f "$startup_tmp"' EXIT

awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
' "$startup_file" >"$startup_tmp"

quoted_binary=$(printf '%q' "$agent_binary")
quoted_url=$(printf '%q' "$app_url")
quoted_log=$(printf '%q' "$(dirname "$agent_binary")/agent.log")
{
    cat "$startup_tmp"
    printf '\n%s\n' "$begin_marker"
    echo '# IceWM de antiX no siempre procesa ~/.config/autostart de forma fiable.'
    echo '# Iniciar una sola instancia; el agente también levanta su VPN embebida.'
    printf 'if ! pgrep -u "$(id -u)" -f %q >/dev/null 2>&1; then\n' "^${agent_binary}([[:space:]]|$)"
    printf '    setsid env ECOMMERCE_APP_URL=%s %s </dev/null >>%s 2>&1 &\n' \
        "$quoted_url" "$quoted_binary" "$quoted_log"
    echo 'fi'
    echo "$end_marker"
} >"$startup_file"
chmod 0755 "$startup_file"

if [[ -n ${DISPLAY:-} ]] \
    && ! pgrep -u "$(id -u)" -f "^${agent_binary}([[:space:]]|$)" >/dev/null 2>&1; then
    setsid env ECOMMERCE_APP_URL="$app_url" \
        "$agent_binary" </dev/null >>"$(dirname "$agent_binary")/agent.log" 2>&1 &
fi

echo 'Inicio del agente reforzado para IceWM/antiX.'
echo "Copia de seguridad: $backup"
