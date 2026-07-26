#!/usr/bin/env bash

set -euo pipefail

SYSTEM_ROOT="${VPSSETUP_ROOT:-}"
INSTALL_DIR="${SYSTEM_ROOT%/}/opt/vpssetup"
BIN_PATH="${SYSTEM_ROOT%/}/usr/local/bin/vpssetup"
ETC_DIR="${SYSTEM_ROOT%/}/etc/vpssetup"
REPO="${VPSSETUP_REPO:-}"
REQUESTED_VERSION="${VPSSETUP_VERSION:-latest}"

die() {
    printf 'VPSSetup installer: %s\n' "$*" >&2
    exit 1
}

archive_has_safe_paths() {
    local archive="$1"
    local entry
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..)
                return 1
                ;;
        esac
    done < <(tar -tzf "$archive")
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
        die "для remote install задайте VPSSETUP_REPO=owner/repository"
    command -v curl >/dev/null || die "curl не установлен"
    command -v sha256sum >/dev/null || die "sha256sum не найден"

    if [[ "$REQUESTED_VERSION" == "latest" ]]; then
        base_url="https://github.com/${REPO}/releases/latest/download"
    else
        [[ "$REQUESTED_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
            die "некорректная версия: $REQUESTED_VERSION"
        base_url="https://github.com/${REPO}/releases/download/${REQUESTED_VERSION}"
    fi

    archive="$TEMP_DIR/vpssetup.tar.gz"
    curl -fsSL --retry 5 --retry-all-errors --max-time 90 \
        "$base_url/vpssetup.tar.gz" -o "$archive"
    expected="$(curl -fsSL --retry 5 --retry-all-errors --max-time 45 \
        "$base_url/vpssetup.tar.gz.sha256" | awk '{print $1; exit}')"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "$expected" == "$actual" ]] ||
        die "SHA-256 archive не совпал"
    archive_has_safe_paths "$archive" ||
        die "release archive содержит небезопасные пути"

    mkdir -p "$TEMP_DIR/source"
    tar -xzf "$archive" -C "$TEMP_DIR/source"
    SOURCE_DIR="$(find "$TEMP_DIR/source" -type f -name vpssetup.sh -printf '%h\n' | head -n1)"
    [[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR/lib" ]] ||
        die "release archive имеет неверную структуру"
fi

for script in "$SOURCE_DIR/vpssetup.sh" "$SOURCE_DIR/install.sh" "$SOURCE_DIR"/lib/*.sh; do
    [[ -f "$script" ]] || continue
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

mkdir -p "$ETC_DIR"
chmod 700 "$ETC_DIR"
if [[ ! -f "$ETC_DIR/config.conf" ]]; then
    {
        printf '# VPSSetup release configuration\n'
        printf "RELEASE_REPO='%s'\n" "$REPO"
    } >"$ETC_DIR/config.conf"
    chmod 600 "$ETC_DIR/config.conf"
fi

printf '\n  ✓ VPSSetup установлен\n'
printf '  Команда: sudo vpssetup\n'
[[ -n "$previous" ]] && printf '  Предыдущий код: %s\n' "$previous"
printf '\n'

if [[ "${1:-}" != "--no-setup" ]]; then
    exec "$BIN_PATH" setup
fi
