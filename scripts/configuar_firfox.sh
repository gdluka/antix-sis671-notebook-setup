#!/usr/bin/env bash
# Compatibilidad con el nombre antiguo que tenia errores de escritura.
set -Eeuo pipefail
exec "$(dirname "$0")/configurar_firefox.sh" "$@"
