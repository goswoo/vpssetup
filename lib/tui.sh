#!/usr/bin/env bash

show_banner() {
    printf '\n  %sVPSSetup v%s%s — управление Ubuntu 24.04\n' \
        "$C_BRIGHT_CYAN$C_BOLD" "$VERSION" "$C_RESET"
    printf '  %s%s%s\n\n' "$C_DIM" "────────────────────────────────────────────" "$C_RESET"
}

clear_screen() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

tui_phase_title() {
    case "$PHASE" in
        unconfigured) printf 'НЕ НАСТРОЕН' ;;
        ssh_pending) printf 'ОЖИДАЕТСЯ ПОДТВЕРЖДЕНИЕ SSH' ;;
        configured)
            if port_is_listening "$SSH_PORT"; then
                printf 'НАСТРОЕН'
            else
                printf 'ТРЕБУЕТ ВНИМАНИЯ'
            fi
            ;;
    esac
}

tui_show_dashboard() {
    local ssh_value fail2ban_value reboot_value
    if [[ "$PHASE" == "ssh_pending" ]]; then
        ssh_value="$SSH_OLD_PORT → $SSH_PORT"
    else
        ssh_value="$SSH_PORT"
    fi
    if fail2ban_is_healthy; then
        fail2ban_value="работает"
    else
        fail2ban_value="не запущен"
    fi
    if reboot_required_now; then
        reboot_value="требуется"
    else
        reboot_value="не требуется"
    fi

    printf '  Состояние:       %s\n' "$(tui_phase_title)"
    printf '  Пользователь:    %s\n' "$ADMIN_USER"
    printf '  SSH:             %s\n' "$ssh_value"
    printf '  Firewall:        %s\n' "$(ufw_status_summary)"
    printf '  Fail2ban:        %s\n' "$fail2ban_value"
    printf '  Перезагрузка:    %s\n' "$reboot_value"
    echo ""

    printf '  %sСледующий шаг:%s\n' "$C_BOLD" "$C_RESET"
    case "$PHASE" in
        unconfigured)
            echo "  Запустите мастер первоначальной настройки."
            ;;
        ssh_pending)
            printf '  В новом окне подключитесь: ssh -p %s %s@<SERVER>\n' \
                "$SSH_PORT" "$ADMIN_USER"
            echo "  Затем подтвердите новый SSH-порт."
            ;;
        configured)
            if port_is_listening "$SSH_PORT"; then
                echo "  Настройка завершена. Можно запустить диагностику."
            else
                printf '  SSH не слушает порт %s. Запустите диагностику.\n' "$SSH_PORT"
            fi
            ;;
    esac
    echo ""
}

tui_connection_help() {
    echo ""
    printf '  Подключение по SSH:\n\n'
    printf '    ssh -p %s %s@<SERVER>\n\n' "$SSH_PORT" "$ADMIN_USER"
    echo "  Выполните команду в новом окне и не закрывайте текущую сессию,"
    echo "  пока новый вход не будет подтверждён."
}

tui_ssh_overview() {
    local root_login password_login
    if [[ "$SSH_CONFIRMED" == "true" ]]; then
        root_login="запрещён"
        password_login="запрещён"
    else
        root_login="разрешён до подтверждения"
        password_login="разрешён до подтверждения"
    fi

    printf '  Текущий порт:      %s\n' "$SSH_OLD_PORT"
    if [[ "$PHASE" == "ssh_pending" ]]; then
        printf '  Новый порт:        %s\n' "$SSH_PORT"
    else
        printf '  Активный порт:     %s\n' "$SSH_PORT"
    fi
    printf '  Root-вход:         %s\n' "$root_login"
    printf '  Вход по паролю:    %s\n' "$password_login"
    printf '  Вход по ключу:     разрешён\n'
    printf '  UFW:               %s\n' "$(ufw_status_summary)"
}

tui_ssh_menu() {
    while true; do
        clear_screen
        show_banner
        echo "  SSH И СЕТЕВОЙ ДОСТУП"
        echo ""
        tui_ssh_overview
        echo ""

        if [[ "$PHASE" == "ssh_pending" ]]; then
            echo "  [1] Подтвердить новый SSH-порт"
        else
            echo "  [1] Настроить или сменить SSH-порт"
        fi
        echo "  [2] Показать команду подключения"
        echo "  [3] Как создать SSH-ключ"
        echo "  [4] Проверить SSH, UFW и Fail2ban"
        echo "  [0] Назад"

        case "$(read_choice "Выбор" "0")" in
            1)
                if [[ "$PHASE" == "ssh_pending" ]]; then
                    with_manager_lock ssh_confirm
                else
                    local port
                    port="$(read_required_port "Новый SSH-порт")" || {
                        press_any_key
                        continue
                    }
                    with_manager_lock ssh_stage "$port"
                fi
                press_any_key
                ;;
            2) tui_connection_help; press_any_key ;;
            3) show_client_key_manual; press_any_key ;;
            4) health_check || true; press_any_key ;;
            0) return ;;
        esac
    done
}

tui_swap_action() {
    echo ""
    echo "  Swap помогает серверу с небольшим объёмом RAM."
    if [[ -n "$MANAGED_SWAPFILE" ]]; then
        printf '  Сейчас включён: %s\n' "$MANAGED_SWAPFILE"
        confirm "Отключить управляемый swap?" "N" &&
            with_manager_lock module_dispatch disable swap
    else
        local size
        size="$(read_choice "Размер swap" "2G")"
        confirm "Создать swap размером $size?" "N" &&
            with_manager_lock module_dispatch enable swap "$size"
    fi
}

tui_ipv6_action() {
    echo ""
    if [[ -n "$IPV6_METHOD" ]]; then
        printf '  IPv6 отключён методом %s.\n' "$IPV6_METHOD"
        confirm "Включить IPv6 обратно?" "N" &&
            with_manager_lock module_dispatch disable ipv6
    else
        echo "  IPv6 сейчас включён."
        echo "  sysctl — применить сразу; grub — применить после reboot."
        local method
        method="$(read_choice "Метод отключения: sysctl/grub" "sysctl")"
        confirm "Отключить IPv6 методом $method?" "N" &&
            with_manager_lock module_dispatch enable ipv6 "$method"
    fi
}

tui_sudo_mode_label() {
    case "$SUDO_MODE" in
        standard) printf 'стандартный пароль' ;;
        timeout) printf 'пароль действует 60 минут' ;;
        nopasswd) printf 'NOPASSWD' ;;
    esac
}

tui_sudo_action() {
    echo ""
    printf '  Текущий режим: %s\n\n' "$(tui_sudo_mode_label)"
    echo "  [1] Стандартный запрос пароля"
    echo "  [2] Пароль действует 60 минут"
    echo "  [3] NOPASSWD — выполнять sudo без пароля"

    local default_choice choice mode
    case "$SUDO_MODE" in
        standard) default_choice=1 ;;
        timeout) default_choice=2 ;;
        nopasswd) default_choice=3 ;;
    esac
    choice="$(read_choice "Режим sudo" "$default_choice")"
    case "$choice" in
        1) mode="standard" ;;
        2) mode="timeout" ;;
        3) mode="nopasswd" ;;
        *) log_error "Неизвестный режим sudo"; return 1 ;;
    esac

    if [[ "$mode" == "$SUDO_MODE" ]] && sudo_policy_is_applied "$mode"; then
        log_info "Выбранный режим уже активен"
        return 0
    fi
    if [[ "$mode" == "nopasswd" ]]; then
        log_warn "$ADMIN_USER сможет выполнять любые команды через sudo без пароля."
    fi
    confirm "Применить выбранный режим sudo?" "N" &&
        with_manager_lock module_sudo_set "$mode"
}

tui_docker_group_action() {
    echo ""
    echo "  Разрешает административному пользователю запускать Docker без sudo."
    if [[ "$DOCKER_GROUP_ADDED" == "true" ]]; then
        confirm "Удалить управляемое членство в docker group?" "N" &&
            with_manager_lock module_dispatch disable docker-group
    else
        confirm "Добавить пользователя в docker group?" "N" &&
            with_manager_lock module_dispatch enable docker-group
    fi
}

tui_modules_menu() {
    while true; do
        clear_screen
        show_banner
        echo "  ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ"
        echo ""
        printf '  [1] Swap                %s\n' \
            "$([[ -n "$MANAGED_SWAPFILE" ]] && echo "включён" || echo "выключен")"
        echo "      Полезен при небольшом объёме RAM"
        printf '  [2] IPv6                %s\n' \
            "$([[ -n "$IPV6_METHOD" ]] && echo "отключён ($IPV6_METHOD)" || echo "включён")"
        echo "      Включение или отключение IPv6"
        printf '  [3] Sudo                %s\n' "$(tui_sudo_mode_label)"
        echo "      Запрос пароля и время действия sudo-сессии"
        printf '  [4] Docker group        %s\n' \
            "$([[ "$DOCKER_GROUP_ADDED" == "true" ]] && echo "включена" || echo "выключена")"
        echo "      Запуск Docker без sudo"
        echo "  [0] Назад"

        case "$(read_choice "Настройка" "0")" in
            1) tui_swap_action; press_any_key ;;
            2) tui_ipv6_action; press_any_key ;;
            3) tui_sudo_action; press_any_key ;;
            4) tui_docker_group_action; press_any_key ;;
            0) return ;;
        esac
    done
}

tui_status_menu() {
    while true; do
        clear_screen
        show_banner
        echo "  СОСТОЯНИЕ И ДИАГНОСТИКА"
        echo ""
        tui_show_dashboard
        echo "  [1] Запустить полную диагностику"
        echo "  [2] Показать подробный статус"
        echo "  [3] Показать технический JSON"
        echo "  [0] Назад"
        case "$(read_choice "Выбор" "0")" in
            1) health_check || true; press_any_key ;;
            2) show_status; press_any_key ;;
            3) show_status_json; press_any_key ;;
            0) return ;;
        esac
    done
}

tui_backup_menu() {
    local snapshot_count id label

    while true; do
        clear_screen
        show_banner
        snapshot_count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
            2>/dev/null | wc -l)"
        echo "  РЕЗЕРВНЫЕ КОПИИ И ОТКАТ"
        printf '  Сохранённых snapshots: %s\n\n' "$snapshot_count"
        echo "  [1] Показать snapshots"
        echo "  [2] Посмотреть snapshot"
        echo "  [3] Создать snapshot"
        echo "  [4] Восстановить snapshot"
        echo "  [5] Откатить управляемые файлы к начальному состоянию"
        echo "  [0] Назад"
        case "$(read_choice "Выбор" "0")" in
            1) backup_list; press_any_key ;;
            2)
                backup_list
                id="$(read_choice "Snapshot ID" "")"
                backup_show "$id"
                press_any_key
                ;;
            3)
                label="$(read_choice "Название snapshot" "manual")"
                with_manager_lock backup_create "$label"
                press_any_key
                ;;
            4)
                backup_list
                id="$(read_choice "Snapshot ID" "")"
                with_manager_lock backup_restore "$id"
                press_any_key
                ;;
            5) with_manager_lock rollback_initial; press_any_key ;;
            0) return ;;
        esac
    done
}

tui_maintenance_menu() {
    while true; do
        clear_screen
        show_banner
        echo "  ОБСЛУЖИВАНИЕ"
        echo ""
        printf '  Версия:              %s\n' "$VERSION"
        printf '  Перезагрузка:        %s\n\n' \
            "$(reboot_required_now && echo "требуется" || echo "не требуется")"
        echo "  [1] Обновить VPSSetup"
        echo "  [2] Показать последние 100 строк журнала"
        echo "  [3] Перезагрузить сервер"
        echo "  [9] Удалить VPSSetup"
        echo "  [0] Назад"
        case "$(read_choice "Выбор" "0")" in
            1) with_manager_lock manager_update; press_any_key ;;
            2)
                touch "$LOG_FILE"
                tail -n 100 "$LOG_FILE"
                press_any_key
                ;;
            3)
                if confirm "Перезагрузить сервер сейчас?" "N"; then
                    run_systemctl reboot
                    return
                fi
                ;;
            9)
                if with_manager_lock manager_uninstall; then
                    exit 0
                fi
                press_any_key
                ;;
            0) return ;;
        esac
    done
}

tui_recommended_action() {
    case "$PHASE" in
        unconfigured) with_manager_lock run_setup_wizard ;;
        ssh_pending) with_manager_lock ssh_confirm ;;
        configured) health_check || true ;;
    esac
}

show_main_menu() {
    require_root menu || return 1
    while true; do
        clear_screen
        show_banner
        tui_show_dashboard
        case "$PHASE" in
            unconfigured) echo "  [1] Начать настройку" ;;
            ssh_pending) echo "  [1] Подтвердить новый SSH-порт" ;;
            configured) echo "  [1] Проверить состояние" ;;
        esac
        echo "  [2] Состояние и диагностика"
        echo "  [3] SSH и сетевой доступ"
        echo "  [4] Дополнительные настройки"
        echo "  [5] Резервные копии и откат"
        echo "  [6] Обслуживание"
        echo "  [0] Выход"
        case "$(read_choice "Выбор" "0")" in
            1) tui_recommended_action; press_any_key ;;
            2) tui_status_menu ;;
            3) tui_ssh_menu ;;
            4) tui_modules_menu ;;
            5) tui_backup_menu ;;
            6) tui_maintenance_menu ;;
            0) return ;;
        esac
    done
}
