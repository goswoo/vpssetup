#!/usr/bin/env bash

log_line() {
    local level="$1"
    shift
    local message="$*"
    local color="$C_CYAN"
    local symbol="•"

    case "$level" in
        OK) color="$C_GREEN"; symbol="$SYM_OK" ;;
        WARN) color="$C_YELLOW"; symbol="$SYM_WARN" ;;
        ERROR) color="$C_RED"; symbol="$SYM_FAIL" ;;
    esac

    printf '  %s%s%s %s\n' "$color" "$symbol" "$C_RESET" "$message"

    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$message" \
            >>"$LOG_FILE" 2>/dev/null || true
    fi
}

log_info() { log_line INFO "$@"; }
log_success() { log_line OK "$@"; }
log_warn() { log_line WARN "$@"; }
log_error() { log_line ERROR "$@" >&2; }

die() {
    log_error "$*"
    return 1
}

system_path() {
    local path="$1"
    if [[ -n "${VPSSETUP_ROOT:-}" ]]; then
        printf '%s%s\n' "${VPSSETUP_ROOT%/}" "$path"
    else
        printf '%s\n' "$path"
    fi
}

is_test_mode() {
    [[ "${VPSSETUP_TEST_MODE:-0}" == "1" ]]
}

require_root() {
    if ! is_test_mode && [[ "$(id -u)" -ne 0 ]]; then
        die "Команда требует root. Запустите: sudo vpssetup $*"
        return 1
    fi
}

require_ubuntu_2404() {
    local os_release
    os_release="$(system_path /etc/os-release)"
    [[ -r "$os_release" ]] || {
        die "Не найден $os_release"
        return 1
    }

    local id="" version_id=""
    while IFS='=' read -r key value; do
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            ID) id="$value" ;;
            VERSION_ID) version_id="$value" ;;
        esac
    done <"$os_release"

    if [[ "$id" != "ubuntu" || "$version_id" != "24.04" ]]; then
        die "Поддерживается только Ubuntu 24.04 (обнаружено: ${id:-?} ${version_id:-?})"
        return 1
    fi
}

validate_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] &&
        ((port >= 1 && port <= 65535))
}

read_required_port() {
    local prompt="${1:-SSH-порт}"
    local answer=""
    while true; do
        printf '  %s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >&2
        if ! IFS= read -r answer; then
            die "SSH-порт обязателен"
            return 1
        fi
        if validate_port "$answer"; then
            printf '%s\n' "$answer"
            return 0
        fi
        log_error "Введите порт от 1 до 65535"
    done
}

validate_username() {
    local username="${1:-}"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] &&
        [[ "$username" != "root" ]]
}

validate_swap_size() {
    [[ "${1:-}" =~ ^[1-9][0-9]*([MmGg])$ ]]
}

read_choice() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""
    printf '  %s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default" >&2
    IFS= read -r answer || true
    printf '%s\n' "${answer:-$default}"
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer=""
    printf '  %s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default" >&2
    IFS= read -r answer || true
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[YyДд]$ ]]
}

press_any_key() {
    [[ -t 0 ]] || return 0
    printf '  %sНажмите Enter для продолжения...%s' "$C_DIM" "$C_RESET"
    IFS= read -r _ || true
}

atomic_write() {
    local target="$1"
    local mode="$2"
    local content="$3"
    local dir tmp
    dir="$(dirname "$target")"
    mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.vpssetup.XXXXXX")" || return 1
    printf '%s' "$content" >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

download_url() {
    local url="$1"
    local destination="$2"
    if command_exists curl; then
        curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$destination"
    elif command_exists wget; then
        wget -q --timeout=30 --tries=3 -O "$destination" "$url"
    else
        die "Нужен curl или wget"
        return 1
    fi
}

run_systemctl() {
    is_test_mode && return 0
    command_exists systemctl || {
        die "systemctl недоступен"
        return 1
    }
    systemctl "$@"
}

safe_id() {
    local value="${1:-snapshot}"
    value="${value//[^A-Za-z0-9_.-]/-}"
    printf '%s\n' "${value:0:48}"
}

current_ssh_server_port() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        awk '{print $4}' <<<"$SSH_CONNECTION"
        return
    fi

    if command_exists sshd; then
        sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}'
        return
    fi

    printf '22\n'
}

port_is_listening() {
    local port="$1"
    is_test_mode && return 0
    command_exists ss || return 1
    ss -H -ltn 2>/dev/null |
        awk -v wanted="$port" '
            {
                address=$4
                sub(/^.*:/, "", address)
                gsub(/[\[\]]/, "", address)
                if (address == wanted) found=1
            }
            END { exit(found ? 0 : 1) }
        '
}

port_is_available() {
    is_test_mode && return 0
    ! port_is_listening "$1"
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

with_manager_lock() {
    local lock_file="$STATE_DIR/manager.lock"
    mkdir -p "$STATE_DIR"
    exec 9>"$lock_file"
    if ! flock -n 9; then
        die "Другой процесс vpssetup уже выполняет изменения"
        return 1
    fi
    "$@"
}
