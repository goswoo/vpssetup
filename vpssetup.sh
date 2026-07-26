#!/usr/bin/env bash

set -o pipefail
export LC_NUMERIC=C

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_PATH" ]]; do
    LINK_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
    SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
    [[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$LINK_DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
VERSION="$(sed -n '1p' "$SCRIPT_DIR/version" 2>/dev/null || echo 0.0.0-dev)"

if [[ -n "${VPSSETUP_INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="$VPSSETUP_INSTALL_DIR"
elif [[ -d "$SCRIPT_DIR/lib" ]]; then
    INSTALL_DIR="$SCRIPT_DIR"
else
    INSTALL_DIR="/opt/vpssetup"
fi

if [[ -n "${VPSSETUP_ROOT:-}" ]]; then
    STATE_DIR="${VPSSETUP_ROOT%/}/var/lib/vpssetup"
    LOG_DIR="${VPSSETUP_ROOT%/}/var/log/vpssetup"
else
    STATE_DIR="/var/lib/vpssetup"
    LOG_DIR="/var/log/vpssetup"
fi
STATE_FILE="$STATE_DIR/state.conf"
BACKUP_DIR="$STATE_DIR/backups"
LOG_FILE="$LOG_DIR/vpssetup.log"

for library in \
    colors utils state backup system firewall fail2ban ssh modules update status manager tui; do
    if [[ ! -r "$SCRIPT_DIR/lib/${library}.sh" ]]; then
        printf 'VPSSetup: missing library: %s\n' "$SCRIPT_DIR/lib/${library}.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/${library}.sh"
done

initialize_runtime() {
    if [[ "$(id -u)" -eq 0 ]] || is_test_mode; then
        mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR"
        chmod 700 "$STATE_DIR" "$BACKUP_DIR"
    fi
    load_state
}

show_help() {
    cat <<'EOF'
VPSSetup — Ubuntu 24.04 hardening manager

Usage:
  sudo vpssetup                         Interactive menu
  sudo vpssetup setup                   First-run wizard / health on rerun
  sudo vpssetup status [--json]         Current state
  sudo vpssetup health                  Live diagnostics
  sudo vpssetup logs                    Manager log
  sudo vpssetup ssh stage <port>
  sudo vpssetup ssh confirm [--force-console]
  sudo vpssetup ssh status
  sudo vpssetup module list
  sudo vpssetup module enable|disable <name> [option]
  sudo vpssetup backup create [label]
  sudo vpssetup backup list
  sudo vpssetup backup show <id>
  sudo vpssetup backup restore <id>
  sudo vpssetup rollback
  sudo vpssetup update
  sudo vpssetup uninstall
  vpssetup version
  vpssetup help

Modules: swap, ipv6, sudo-timeout, docker-group
EOF
}

dispatch_backup() {
    local action="${1:-list}"
    shift 2>/dev/null || true
    case "$action" in
        create) with_manager_lock backup_create "${1:-manual}" ;;
        list) backup_list ;;
        show) backup_show "${1:-}" ;;
        restore) with_manager_lock backup_restore "${1:-}" ;;
        *) die "Использование: vpssetup backup create|list|show|restore"; return 1 ;;
    esac
}

dispatch_ssh() {
    local action="${1:-status}"
    shift 2>/dev/null || true
    case "$action" in
        stage)
            local target_port="${1:-}"
            if [[ -z "$target_port" ]]; then
                if [[ -t 0 ]]; then
                    target_port="$(read_required_port "Новый SSH-порт")" || return 1
                else
                    die "Укажите SSH-порт: sudo vpssetup ssh stage <port>"
                    return 1
                fi
            fi
            with_manager_lock ssh_stage "$target_port"
            ;;
        confirm) with_manager_lock ssh_confirm "${1:-}" ;;
        status) ssh_status ;;
        *) die "Использование: vpssetup ssh stage|confirm|status"; return 1 ;;
    esac
}

main() {
    initialize_runtime
    local command="${1:-menu}"
    shift 2>/dev/null || true
    case "$command" in
        menu) show_main_menu ;;
        setup) with_manager_lock run_setup_wizard ;;
        status)
            require_root status || return 1
            if [[ "${1:-}" == "--json" ]]; then show_status_json; else show_status; fi
            status_has_drift && return 2
            return 0
            ;;
        health) require_root health && health_check ;;
        logs)
            require_root logs || return 1
            touch "$LOG_FILE"
            tail -n "${1:-100}" "$LOG_FILE"
            ;;
        ssh) dispatch_ssh "$@" ;;
        module)
            if [[ "${1:-list}" == "list" || "${1:-list}" == "status" ]]; then
                module_dispatch "$@"
            else
                with_manager_lock module_dispatch "$@"
            fi
            ;;
        backup) dispatch_backup "$@" ;;
        rollback) with_manager_lock rollback_initial ;;
        update) with_manager_lock manager_update ;;
        uninstall) with_manager_lock manager_uninstall ;;
        version) printf 'VPSSetup v%s\n' "$VERSION" ;;
        help|--help|-h) show_help ;;
        *) log_error "Неизвестная команда: $command"; show_help; return 1 ;;
    esac
}

main "$@"
