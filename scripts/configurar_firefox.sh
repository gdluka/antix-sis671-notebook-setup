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
    sudo apt-get install -y firefox-esr sqlite3 webext-ublock-origin-firefox
fi

firefox_root="$HOME/.mozilla/firefox"
if [[ ! -d $firefox_root ]]; then
    echo 'Firefox aun no creo un perfil. Abre Firefox una vez y vuelve a ejecutar este script.' >&2
    exit 1
fi

# Lanzador protegido contra dobles clics mientras Firefox todavía arranca.
launcher_dir="$HOME/.local/bin"
launcher="$launcher_dir/firefox-wait"
mkdir -p "$launcher_dir"
cat >"$launcher" <<'EOF'
#!/usr/bin/env bash
set -u
real_firefox=/usr/lib/firefox-esr/firefox-esr
lock_file="/tmp/firefox-launch-${UID}.lock"
firefox_running() {
    pgrep -u "$UID" -x firefox-esr >/dev/null 2>&1 \
        || pgrep -u "$UID" -x firefox >/dev/null 2>&1
}
focus_or_forward() {
    if (($# == 0)); then
        wmctrl -xa firefox-esr.Firefox-esr >/dev/null 2>&1 || true
    else
        "$real_firefox" "$@" >/dev/null 2>&1 &
    fi
}
if firefox_running; then focus_or_forward "$@"; exit 0; fi
exec 9>"$lock_file"
if ! flock -n 9; then
    count=0
    while ! firefox_running && ((count < 50)); do sleep 0.2; count=$((count + 1)); done
    firefox_running && focus_or_forward "$@"
    exit 0
fi
spinner_pid=''
if command -v yad >/dev/null 2>&1 && [[ -n ${DISPLAY:-} ]]; then
    yad --progress --pulsate --auto-close --no-buttons --center --on-top \
        --width=330 --height=90 --title='Iniciando Firefox' \
        --text='<b>Iniciando Firefox…</b>' >/dev/null 2>&1 &
    spinner_pid=$!
fi
sleep 1.2
"$real_firefox" "$@" >/dev/null 2>&1 &
firefox_pid=$!
count=0
while ! firefox_running && ((count < 50)); do sleep 0.2; count=$((count + 1)); done
sleep 0.4
if [[ -n $spinner_pid ]]; then
    kill -KILL "$spinner_pid" >/dev/null 2>&1 || true
    wmctrl -c 'Iniciando Firefox' >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$launcher"

applications_dir="$HOME/.local/share/applications"
mkdir -p "$applications_dir"
if [[ -r /usr/share/applications/firefox-esr.desktop ]]; then
    sed "s#^Exec=/usr/lib/firefox-esr/firefox-esr#Exec=${launcher}#" \
        /usr/share/applications/firefox-esr.desktop \
        >"$applications_dir/firefox-esr.desktop"
fi

# -L incluye los perfiles que PSD mantiene como enlaces a la copia en RAM.
mapfile -d '' profiles < <(find -L "$firefox_root" -maxdepth 1 -type d \( -name '*.default' -o -name '*.default-*' -o -name '*.default-esr' \) -print0)
if ((${#profiles[@]} == 0)); then
    echo 'No se encontro ningun perfil de Firefox.' >&2
    exit 1
fi

begin='// >>> ajustes-notebook >>>'
end='// <<< ajustes-notebook <<<'
firefox_running=false
pgrep -x firefox-esr >/dev/null 2>&1 && firefox_running=true
pgrep -x firefox >/dev/null 2>&1 && firefox_running=true

for profile in "${profiles[@]}"; do
    prefs="$profile/user.js"
    [[ -f $prefs ]] && cp -a "$prefs" "${prefs}.backup-$(date +%Y%m%d-%H%M%S)"
    tmp_file=$(mktemp)
    if [[ -f $prefs ]]; then
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { skip=1; next }
            $0 == end { skip=0; next }
            !skip { print }
        ' "$prefs" >"$tmp_file"
    fi
    {
        cat "$tmp_file"
        echo "$begin"
        echo 'user_pref("browser.startup.page", 0);'
        echo 'user_pref("browser.startup.homepage", "about:blank");'
        echo 'user_pref("browser.sessionstore.resume_from_crash", true);'
        echo 'user_pref("browser.sessionstore.max_resumed_crashes", 10);'
        echo 'user_pref("browser.shell.checkDefaultBrowser", false);'
        echo 'user_pref("toolkit.telemetry.enabled", false);'
        echo 'user_pref("datareporting.healthreport.uploadEnabled", false);'
        echo 'user_pref("browser.newtabpage.activity-stream.telemetry", false);'
        echo 'user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);'
        echo 'user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);'
        echo 'user_pref("browser.newtabpage.activity-stream.showSponsored", false);'
        echo 'user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);'
        echo 'user_pref("extensions.pocket.enabled", false);'
        echo 'user_pref("browser.discovery.enabled", false);'
        echo 'user_pref("network.http.speculative-parallel-limit", 0);'
        echo 'user_pref("dom.ipc.processCount", 2);'
        echo 'user_pref("dom.ipc.processCount.webIsolated", 2);'
        echo 'user_pref("browser.tabs.unloadOnLowMemory", true);'
        # La SiS solo acelera 2D; WebGL usa llvmpipe. Evitar animaciones y GL por CPU.
        echo 'user_pref("general.smoothScroll", true);'
        echo 'user_pref("general.smoothScroll.mouseWheel.durationMinMS", 50);'
        echo 'user_pref("general.smoothScroll.mouseWheel.durationMaxMS", 100);'
        echo 'user_pref("general.smoothScroll.lines.durationMinMS", 40);'
        echo 'user_pref("general.smoothScroll.lines.durationMaxMS", 100);'
        echo 'user_pref("mousewheel.default.delta_multiplier_y", 80);'
        echo 'user_pref("toolkit.cosmeticAnimations.enabled", false);'
        echo 'user_pref("ui.prefersReducedMotion", 1);'
        echo 'user_pref("browser.tabs.animate", false);'
        echo 'user_pref("layers.acceleration.disabled", true);'
        echo 'user_pref("gfx.webrender.all", false);'
        echo 'user_pref("gfx.webrender.software", true);'
        echo 'user_pref("gfx.webrender.compositor", false);'
        echo 'user_pref("gfx.canvas.accelerated", false);'
        echo 'user_pref("media.hardware-video-decoding.enabled", false);'
        echo 'user_pref("media.ffmpeg.vaapi.enabled", false);'
        echo "$end"
    } >"$prefs"
    rm -f "$tmp_file"

    if ! $firefox_running; then
        while IFS= read -r -d '' database; do
            sqlite3 "$database" 'PRAGMA quick_check;' >/dev/null 2>&1 || true
            sqlite3 "$database" 'VACUUM;' >/dev/null 2>&1 || true
        done < <(find "$profile" -type f -name '*.sqlite' -print0)
    fi
done

echo "Firefox configurado en ${#profiles[@]} perfil(es)."
if $firefox_running; then
    echo 'Firefox estaba abierto: se omitio compactar sus bases de datos.'
fi
echo 'Los ajustes conservan las actualizaciones y protecciones de seguridad de Firefox.'
