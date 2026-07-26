#!/usr/bin/env bash

show_banner() {
    printf '%s' "$C_BRIGHT_CYAN"
    cat <<'EOF'

  ██╗   ██╗██████╗ ███████╗███████╗███████╗████████╗██╗   ██╗██████╗
  ██║   ██║██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
  ██║   ██║██████╔╝███████╗███████╗█████╗     ██║   ██║   ██║██████╔╝
  ╚██╗ ██╔╝██╔═══╝ ╚════██║╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
   ╚████╔╝ ██║     ███████║███████║███████╗   ██║   ╚██████╔╝██║
    ╚═══╝  ╚═╝     ╚══════╝╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
EOF
    printf '  %sVPSSetup v%s — Ubuntu 24.04 hardening manager%s\n\n' \
        "$C_BOLD" "$VERSION" "$C_RESET"
}

clear_screen() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

tui_ssh_menu() {
    while true; do
        clear_screen
        show_banner
        ssh_status
        echo ""
        echo "  [1] Stage SSH"
        echo "  [2] Confirm SSH"
        echo "  [3] Health check"
        echo "  [0] Назад"
        case "$(read_choice "Выбор" "0")" in
            1)
                local port
                port="$(read_choice "Новый SSH-порт" "$SSH_PORT")"
                with_manager_lock ssh_stage "$port"
                press_any_key
                ;;
            2) with_manager_lock ssh_confirm; press_any_key ;;
            3) health_check || true; press_any_key ;;
            0) return ;;
        esac
    done
}

tui_modules_menu() {
    while true; do
        clear_screen
        show_banner
        module_list
        echo ""
        echo "  [1] Swap (рекомендуется при RAM < 2 GiB)"
        echo "  [2] IPv6 / Marzban"
        echo "  [3] sudo timeout"
        echo "  [4] Docker group"
        echo "  [5] ICMP limiter (experimental)"
        echo "  [0] Назад"
        local choice action
        choice="$(read_choice "Модуль" "0")"
        [[ "$choice" == "0" ]] && return
        action="$(read_choice "Действие: enable/disable" "enable")"
        case "$choice" in
            1)
                local size
                size="$(read_choice "Размер swap" "2G")"
                with_manager_lock module_dispatch "$action" swap "$size"
                ;;
            2)
                local method
                method="$(read_choice "Метод: sysctl/grub" "sysctl")"
                with_manager_lock module_dispatch "$action" ipv6 "$method"
                ;;
            3) with_manager_lock module_dispatch "$action" sudo-timeout ;;
            4) with_manager_lock module_dispatch "$action" docker-group ;;
            5) with_manager_lock module_dispatch "$action" icmp-rate-limit ;;
        esac
        press_any_key
    done
}

tui_backup_menu() {
    while true; do
        clear_screen
        show_banner
        echo "  [1] Список snapshots"
        echo "  [2] Создать snapshot"
        echo "  [3] Восстановить snapshot"
        echo "  [4] Откатить к initial snapshot"
        echo "  [0] Назад"
        case "$(read_choice "Выбор" "0")" in
            1) backup_list; press_any_key ;;
            2)
                local label
                label="$(read_choice "Метка" "manual")"
                with_manager_lock backup_create "$label"
                press_any_key
                ;;
            3)
                local id
                backup_list
                id="$(read_choice "Snapshot ID" "")"
                with_manager_lock backup_restore "$id"
                press_any_key
                ;;
            4) with_manager_lock rollback_initial; press_any_key ;;
            0) return ;;
        esac
    done
}

show_main_menu() {
    require_root menu || return 1
    while true; do
        clear_screen
        show_banner
        printf '  Фаза: %-16s SSH: %-5s  UFW: %s\n' \
            "$PHASE" "$SSH_PORT" "$(ufw_status_summary)"
        printf '  Admin: %-15s Reboot required: %s\n\n' \
            "$ADMIN_USER" "$(reboot_required_now && echo yes || echo no)"
        echo "  [1] Первый setup / восстановление"
        echo "  [2] SSH hardening"
        echo "  [3] Опциональные модули"
        echo "  [4] Status"
        echo "  [5] Health"
        echo "  [6] Snapshots / rollback"
        echo "  [7] Update"
        echo "  [8] Uninstall manager"
        echo "  [0] Выход"
        case "$(read_choice "Выбор" "0")" in
            1) with_manager_lock run_setup_wizard; press_any_key ;;
            2) tui_ssh_menu ;;
            3) tui_modules_menu ;;
            4) show_status; press_any_key ;;
            5) health_check || true; press_any_key ;;
            6) tui_backup_menu ;;
            7) with_manager_lock manager_update; press_any_key ;;
            8) with_manager_lock manager_uninstall; return ;;
            0) return ;;
        esac
    done
}
