#!/usr/bin/env bash

set -euo pipefail

SYSTEM_ROOT="${VPSSETUP_ROOT:-}"
INSTALL_DIR="${SYSTEM_ROOT%/}/opt/vpssetup"
BIN_PATH="${SYSTEM_ROOT%/}/usr/local/bin/vpssetup"
REPO="${VPSSETUP_REPO:-goswoo/vpssetup}"
RAW_BASE_URL="${VPSSETUP_RAW_BASE_URL:-https://raw.githubusercontent.com/${REPO}/main}"
CACHE_TOKEN="$(date +%s)-${RANDOM}"
LIBRARIES=(
    colors utils state backup system firewall fail2ban ssh modules update status
    manager tui
)

die() {
    printf 'VPSSetup installer: %s\n' "$*" >&2
    exit 1
}

download_file() {
    local url="$1"
    local destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=3 -O "$destination" "$url"
    else
        die "нужен curl или wget"
    fi
}

download_source() {
    local relative="$1"
    local destination="$2"
    local url="$RAW_BASE_URL/$relative"
    if [[ "$url" == http://* || "$url" == https://* ]]; then
        url="${url}?v=${CACHE_TOKEN}"
    fi
    download_file "$url" "$destination"
}

if [[ "${VPSSETUP_TEST_MODE:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    die "запустите от root: sudo bash install.sh"
fi

source_os_release="${SYSTEM_ROOT%/}/etc/os-release"
[[ -r "$source_os_release" ]] || die "не найден /etc/os-release"
# shellcheck source=/dev/null
source "$source_os_release"
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] ||
    die "поддерживается только Ubuntu 24.04"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

SOURCE_DIR=""
if [[ -f "$SCRIPT_DIR/vpssetup.sh" && -d "$SCRIPT_DIR/lib" ]]; then
    SOURCE_DIR="$SCRIPT_DIR"
else
    [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
        die "некорректный GitHub repository: $REPO"
    SOURCE_DIR="$TEMP_DIR/source"
    mkdir -p "$SOURCE_DIR/lib"
    download_source "vpssetup.sh" "$SOURCE_DIR/vpssetup.sh"
    download_source "version" "$SOURCE_DIR/version"
    for library in "${LIBRARIES[@]}"; do
        download_source "lib/${library}.sh" \
            "$SOURCE_DIR/lib/${library}.sh"
    done
fi

for script in "$SOURCE_DIR/vpssetup.sh" "$SOURCE_DIR"/lib/*.sh; do
    bash -n "$script" || die "синтаксическая ошибка: $script"
done

staging="$TEMP_DIR/install"
mkdir -p "$staging"
cp -a "$SOURCE_DIR/vpssetup.sh" "$SOURCE_DIR/version" "$SOURCE_DIR/lib" "$staging/"
[[ -f "$SOURCE_DIR/README.md" ]] && cp -a "$SOURCE_DIR/README.md" "$staging/"
chmod +x "$staging/vpssetup.sh" "$staging"/lib/*.sh

previous=""
mkdir -p "$(dirname "$INSTALL_DIR")"
if [[ -d "$INSTALL_DIR" ]]; then
    previous="${SYSTEM_ROOT%/}/opt/vpssetup.previous.$(date -u '+%Y%m%dT%H%M%SZ')"
    mv "$INSTALL_DIR" "$previous"
fi

if ! mv "$staging" "$INSTALL_DIR"; then
    [[ -n "$previous" ]] && mv "$previous" "$INSTALL_DIR"
    die "не удалось установить файлы"
fi
mkdir -p "$(dirname "$BIN_PATH")"
ln -sfn "$INSTALL_DIR/vpssetup.sh" "$BIN_PATH"

printf '\n  ✓ VPSSetup установлен\n'
printf '  Команда: sudo vpssetup\n'
[[ -n "$previous" ]] && printf '  Предыдущий код: %s\n' "$previous"
printf '\n'

if [[ "${1:-}" != "--no-setup" ]]; then
    exec "$BIN_PATH" setup
fi
