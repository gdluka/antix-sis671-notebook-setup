#!/usr/bin/env bash
set -Eeuo pipefail

check_only=false
[[ ${1:-} == --check ]] && check_only=true
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    cat <<'EOF'
Uso: configurar_netbird.sh [--check]

Registra el cliente NetBird ya instalado y vinculado como servicio runit de
antiX. No instala NetBird, no ejecuta el login y no copia su identidad.
EOF
    exit 0
fi

if [[ ${EUID} -eq 0 ]]; then
    sudo_cmd=()
else
    command -v sudo >/dev/null || { echo 'Falta sudo.' >&2; exit 1; }
    sudo_cmd=(sudo)
fi

netbird_binary=$(command -v netbird || true)
[[ -n $netbird_binary && -x $netbird_binary ]] || {
    echo 'NetBird no está instalado.' >&2
    exit 1
}

service_dir=/etc/sv/netbird
active_service=/etc/service/netbird
run_script="$service_dir/run"
config_file=/var/lib/netbird/default.json

if $check_only; then
    [[ -x $run_script && -L $active_service ]] \
        && "${sudo_cmd[@]}" sv status "$active_service" \
        && "${sudo_cmd[@]}" "$netbird_binary" status --check ready \
        && { echo 'OK: NetBird inicia con runit y está conectado.'; exit 0; }
    echo 'PENDIENTE: NetBird no está activo mediante runit.'
    exit 1
fi

"${sudo_cmd[@]}" test -s "$config_file" || {
    echo "Falta la identidad vinculada en $config_file." >&2
    echo 'Ejecutá netbird up antes de configurar el arranque automático.' >&2
    exit 1
}

run_tmp=$(mktemp)
trap 'rm -f "$run_tmp"' EXIT
cat >"$run_tmp" <<EOF
#!/bin/sh
exec 2>&1
exec $netbird_binary service run \\
    --config $config_file \\
    --daemon-addr unix:///var/run/netbird.sock \\
    --log-file /var/log/netbird/client.log
EOF

# Puede existir un daemon iniciado manualmente por `netbird service start` o
# una definición runit incompleta. Detener ambos antes de reemplazar el runner
# evita que dos procesos compitan por el mismo socket.
if "${sudo_cmd[@]}" test -e "$active_service" \
    || "${sudo_cmd[@]}" test -L "$active_service"; then
    "${sudo_cmd[@]}" sv down "$active_service" >/dev/null 2>&1 || true
fi
"${sudo_cmd[@]}" "$netbird_binary" service stop >/dev/null 2>&1 || true

"${sudo_cmd[@]}" install -d -o root -g root -m 0755 "$service_dir"
"${sudo_cmd[@]}" install -d -o root -g root -m 0750 /var/log/netbird
"${sudo_cmd[@]}" install -o root -g root -m 0755 "$run_tmp" "$run_script"
"${sudo_cmd[@]}" ln -sfn "$service_dir" "$active_service"

for _ in {1..20}; do
    "${sudo_cmd[@]}" test -e "$service_dir/supervise/ok" && break
    sleep 0.25
done
"${sudo_cmd[@]}" test -e "$service_dir/supervise/ok" || {
    echo 'runit no detectó el servicio NetBird.' >&2
    exit 1
}

"${sudo_cmd[@]}" sv up "$active_service"
for _ in {1..20}; do
    "${sudo_cmd[@]}" "$netbird_binary" status --check ready >/dev/null 2>&1 && break
    sleep 0.5
done
"${sudo_cmd[@]}" sv status "$active_service"
"${sudo_cmd[@]}" "$netbird_binary" status --check ready
echo 'NetBird quedó configurado para iniciar automáticamente mediante runit.'
