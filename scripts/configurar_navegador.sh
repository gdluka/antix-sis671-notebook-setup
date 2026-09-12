#!/usr/bin/env bash
set -Eeuo pipefail

browser="min"
remove_firefox="true"

usage() {
    cat <<'EOF'
Uso: ./configurar_navegador.sh [opciones]

Instala y configura el navegador liviano de la notebook.

Opciones:
  --browser min|brave  Navegador predeterminado (default: min).
  --keep-firefox       No desinstala Firefox ni profile-sync-daemon.
  -h, --help           Muestra esta ayuda.

La desinstalacion de Firefox conserva los perfiles de ~/.mozilla.
EOF
}

while (($#)); do
    case "$1" in
        --browser)
            [[ $# -ge 2 ]] || { echo 'Falta el valor de --browser.' >&2; exit 2; }
            browser="$2"
            shift 2
            ;;
        --keep-firefox)
            remove_firefox="false"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Opcion desconocida: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $browser == "min" || $browser == "brave" ]] || {
    printf 'Navegador no soportado: %s (usa min o brave).\n' "$browser" >&2
    exit 2
}
[[ ${EUID} -ne 0 ]] || {
    echo 'Ejecuta este script como usuario normal, sin sudo.' >&2
    exit 1
}

install_min() {
    command -v min >/dev/null 2>&1 && return
    [[ $(dpkg --print-architecture) == "amd64" ]] || {
        echo 'El paquete oficial fijado de Min solo esta disponible para amd64.' >&2
        exit 1
    }

    local version="1.35.6"
    local expected_sha256="6979ecb43cc996fa41de20ebf788741cb1562c3ffedb53620fee3081167f242d"
    local temp_dir package
    temp_dir=$(mktemp -d)
    package="$temp_dir/min-${version}-amd64.deb"
    trap '[[ ! -e $package ]] || unlink "$package"; rmdir "$temp_dir" 2>/dev/null || true' RETURN
    curl --proto '=https' --tlsv1.2 -fL \
        "https://github.com/minbrowser/min/releases/download/v${version}/min-${version}-amd64.deb" \
        -o "$package"
    printf '%s  %s\n' "$expected_sha256" "$package" | sha256sum --check --status || {
        echo 'La firma SHA-256 del paquete de Min no coincide.' >&2
        exit 1
    }
    sudo apt-get install -y "$package"
    unlink "$package"
    rmdir "$temp_dir"
    trap - RETURN
}

install_brave() {
    command -v brave-browser >/dev/null 2>&1 && return
    sudo curl --proto '=https' --tlsv1.2 -fsSLo \
        /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    sudo curl --proto '=https' --tlsv1.2 -fsSLo \
        /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
    sudo apt-get update
    sudo apt-get install -y brave-browser
}

remove_existing_firefox() {
    [[ $remove_firefox == "true" ]] || return

    local service_link="/etc/service/psd-${USER}"
    if [[ -e $service_link || -L $service_link ]]; then
        sudo sv down "$service_link" >/dev/null 2>&1 || true
        sudo unlink "$service_link"
    fi

    local -a installed=()
    local package
    for package in firefox-esr firefox webext-ublock-origin-firefox profile-sync-daemon; do
        dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii' \
            && installed+=("$package")
    done
    if ((${#installed[@]})); then
        printf 'Desinstalando paquetes reemplazados: %s\n' "${installed[*]}"
        sudo apt-get purge -y "${installed[@]}"
    fi
    echo 'Los perfiles existentes de ~/.mozilla se conservaron.'
}

sudo -v
sudo apt-get install -y ca-certificates curl xdg-utils
case "$browser" in
    min)
        install_min
        browser_binary="min"
        browser_label="Min"
        desktop_candidates=(
            /usr/share/applications/min.desktop
            /usr/share/applications/Min.desktop
            "$HOME/.local/share/applications/min.desktop"
        )
        ;;
    brave)
        install_brave
        browser_binary="brave-browser"
        browser_label="Brave"
        desktop_candidates=(
            /usr/share/applications/brave-browser.desktop
            "$HOME/.local/share/applications/brave-browser.desktop"
        )
        ;;
esac

remove_existing_firefox

browser_path=$(command -v "$browser_binary" || true)
[[ -n $browser_path && -x $browser_path ]] || {
    printf '%s no quedo instalado correctamente.\n' "$browser_label" >&2
    exit 1
}

desktop_name=""
for candidate in "${desktop_candidates[@]}"; do
    if [[ -r $candidate ]]; then
        desktop_name=$(basename "$candidate")
        break
    fi
done

if [[ -n $desktop_name ]]; then
    xdg-settings set default-web-browser "$desktop_name" || true
    xdg-mime default "$desktop_name" x-scheme-handler/http
    xdg-mime default "$desktop_name" x-scheme-handler/https
    xdg-mime default "$desktop_name" text/html
else
    printf 'Aviso: no se encontro el archivo .desktop de %s.\n' "$browser_label" >&2
fi

toolbar="$HOME/.icewm/toolbar"
mkdir -p "$(dirname "$toolbar")"
touch "$toolbar"
toolbar_backup=$(mktemp "${toolbar}.backup-XXXXXX")
cp -p "$toolbar" "$toolbar_backup"
toolbar_tmp=$(mktemp)
trap '[[ ! -e $toolbar_tmp ]] || unlink "$toolbar_tmp"' EXIT
awk -v command="$browser_binary" '
    BEGIN { replaced=0 }
    tolower($0) ~ /buscador web/ {
        if (!replaced) printf "prog \"Buscador web\" web-browser %s\n", command
        replaced=1
        next
    }
    { print }
    END {
        if (!replaced) printf "prog \"Buscador web\" web-browser %s\n", command
    }
' "$toolbar" >"$toolbar_tmp"
install -m 0644 "$toolbar_tmp" "$toolbar"
unlink "$toolbar_tmp"
trap - EXIT

printf '%s quedo como navegador predeterminado: %s\n' "$browser_label" "$browser_path"
printf 'El boton «Buscador web» de IceWM abrira %s al recargar la barra.\n' "$browser_label"
