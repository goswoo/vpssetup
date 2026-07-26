#!/usr/bin/env bash

tui_paint() {
    local tone="$1"
    local text="$2"
    local color=""

    case "$tone" in
        good) color="$C_GREEN" ;;
        warn) color="$C_YELLOW" ;;
        bad) color="$C_RED" ;;
        accent) color="$C_CYAN" ;;
        bright) color="$C_BRIGHT_CYAN" ;;
        muted) color="$C_DIM" ;;
    esac
    printf '%s%s%s' "$color" "$text" "$C_RESET"
}

tui_title() {
    printf '  %s%s%s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET"
}

tui_hint() {
    printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

tui_menu_item() {
    local key="$1"
    local label="$2"
    local tone="${3:-normal}"
    local key_color="$C_CYAN"
    local label_color=""

    case "$tone" in
        primary)
            key_color="$C_BRIGHT_CYAN"
            label_color="$C_BOLD"
            ;;
        warning)
            key_color="$C_YELLOW"
            label_color="$C_YELLOW"
            ;;
        danger)
            key_color="$C_RED"
            label_color="$C_RED"
            ;;
        muted)
            key_color="$C_DIM"
            label_color="$C_DIM"
            ;;
    esac

    printf '  %s[%s]%s %s%s%s\n' \
        "$key_color" "$key" "$C_RESET" "$label_color" "$label" "$C_RESET"
}

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
        unconfigured) tui_paint warn 'НЕ НАСТРОЕН' ;;
        ssh_pending) tui_paint warn 'ОЖИДАЕТСЯ ПОДТВЕРЖДЕНИЕ SSH' ;;
        configured)
            if port_is_listening "$SSH_PORT"; then
                tui_paint good 'НАСТРОЕН'
            else
                tui_paint bad 'ТРЕБУЕТ ВНИМАНИЯ'
            fi
            ;;
    esac
}

tui_show_dashboard() {
    local ssh_value ssh_tone fail2ban_value fail2ban_tone
    local firewall_value firewall_tone reboot_value reboot_tone
    if [[ "$PHASE" == "ssh_pending" ]]; then
        ssh_value="$SSH_OLD_PORT → $SSH_PORT"
        ssh_tone="warn"
    else
        ssh_value="$SSH_PORT"
        ssh_tone="accent"
    fi
    if fail2ban_is_healthy; then
        fail2ban_value="работает"
        fail2ban_tone="good"
    else
        fail2ban_value="не запущен"
        fail2ban_tone="bad"
    fi
    firewall_value="$(ufw_status_summary)"
    if ufw_is_active; then
        firewall_tone="good"
    else
        firewall_tone="bad"
    fi
    if reboot_required_now; then
        reboot_value="требуется"
        reboot_tone="warn"
    else
        reboot_value="не требуется"
        reboot_tone="good"
    fi

    printf '  Состояние:       %s\n' "$(tui_phase_title)"
    printf '  Пользователь:    %s\n' "$(tui_paint accent "$ADMIN_USER")"
    printf '  SSH:             %s\n' "$(tui_paint "$ssh_tone" "$ssh_value")"
    printf '  Firewall:        %s\n' "$(tui_paint "$firewall_tone" "$firewall_value")"
    printf '  Fail2ban:        %s\n' "$(tui_paint "$fail2ban_tone" "$fail2ban_value")"
    printf '  Перезагрузка:    %s\n' "$(tui_paint "$reboot_tone" "$reboot_value")"
    echo ""

    printf '  %sСледующий шаг:%s\n' "$C_BOLD" "$C_RESET"
    case "$PHASE" in
        unconfigured)
            echo "  Запустите мастер первоначальной настройки."
            ;;
        ssh_pending)
            printf '  В новом окне подключитесь: %sssh -p %s %s@<SERVER>%s\n' \
                "$C_CYAN" "$SSH_PORT" "$ADMIN_USER" "$C_RESET"
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
    tui_title "ПОДКЛЮЧЕНИЕ ПО SSH"
    printf '\n    %sssh -p %s %s@<SERVER>%s\n\n' \
        "$C_CYAN" "$SSH_PORT" "$ADMIN_USER" "$C_RESET"
    tui_hint "Выполните команду в новом окне и не закрывайте текущую сессию,"
    tui_hint "пока новый вход не будет подтверждён."
}

tui_ssh_overview() {
    local root_login password_login access_tone firewall_tone
    if [[ "$SSH_CONFIRMED" == "true" ]]; then
        root_login="запрещён"
        password_login="запрещён"
        access_tone="good"
    else
        root_login="разрешён до подтверждения"
        password_login="разрешён до подтверждения"
        access_tone="warn"
    fi
    if ufw_is_active; then firewall_tone="good"; else firewall_tone="bad"; fi

    if [[ "$PHASE" == "ssh_pending" ]]; then
        printf '  Старый порт:       %s\n' "$(tui_paint muted "$SSH_OLD_PORT")"
        printf '  Новый порт:        %s\n' "$(tui_paint warn "$SSH_PORT")"
    else
        printf '  Активный порт:     %s\n' "$(tui_paint accent "$SSH_PORT")"
    fi
    printf '  Root-вход:         %s\n' "$(tui_paint "$access_tone" "$root_login")"
    printf '  Вход по паролю:    %s\n' "$(tui_paint "$access_tone" "$password_login")"
    printf '  Вход по ключу:     %s\n' "$(tui_paint good "разрешён")"
    printf '  UFW:               %s\n' \
        "$(tui_paint "$firewall_tone" "$(ufw_status_summary)")"
}

tui_ssh_menu() {
    while true; do
        clear_screen
        show_banner
        tui_title "SSH И СЕТЕВОЙ ДОСТУП"
        echo ""
        tui_ssh_overview
        echo ""

        if [[ "$PHASE" == "ssh_pending" ]]; then
            tui_menu_item 1 "Подтвердить новый SSH-порт" primary
        else
            tui_menu_item 1 "Настроить или сменить SSH-порт"
        fi
        tui_menu_item 2 "Показать команду подключения"
        tui_menu_item 3 "Как создать SSH-ключ"
        tui_menu_item 4 "Проверить SSH, UFW и Fail2ban"
        tui_menu_item 0 "Назад" muted

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
    tui_hint "Swap помогает серверу с небольшим объёмом RAM."
    if [[ -n "$MANAGED_SWAPFILE" ]]; then
        printf '  Сейчас включён: %s\n' "$(tui_paint good "$MANAGED_SWAPFILE")"
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
        printf '  IPv6 отключён методом %s.\n' "$(tui_paint accent "$IPV6_METHOD")"
        confirm "Включить IPv6 обратно?" "N" &&
            with_manager_lock module_dispatch disable ipv6
    else
        printf '  IPv6 сейчас %s.\n' "$(tui_paint good "включён")"
        tui_hint "sysctl — применить сразу; grub — применить после reboot."
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

tui_sudo_mode_tone() {
    case "$SUDO_MODE" in
        standard) printf 'good' ;;
        timeout|nopasswd) printf 'warn' ;;
    esac
}

tui_sudo_action() {
    echo ""
    printf '  Текущий режим: %s\n\n' \
        "$(tui_paint "$(tui_sudo_mode_tone)" "$(tui_sudo_mode_label)")"
    tui_menu_item 1 "Стандартный запрос пароля"
    tui_menu_item 2 "Пароль действует 60 минут"
    tui_menu_item 3 "NOPASSWD — выполнять sudo без пароля" warning

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
    tui_hint "Разрешает административному пользователю запускать Docker без sudo."
    if [[ "$DOCKER_GROUP_ADDED" == "true" ]]; then
        confirm "Удалить управляемое членство в docker group?" "N" &&
            with_manager_lock module_dispatch disable docker-group
    else
        confirm "Добавить пользователя в docker group?" "N" &&
            with_manager_lock module_dispatch enable docker-group
    fi
}

tui_modules_menu() {
    local swap_state ipv6_state docker_state

    while true; do
        clear_screen
        show_banner
        tui_title "ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ"
        echo ""
        if [[ -n "$MANAGED_SWAPFILE" ]]; then
            swap_state="$(tui_paint good "включён")"
        else
            swap_state="$(tui_paint muted "выключен")"
        fi
        if [[ -n "$IPV6_METHOD" ]]; then
            ipv6_state="$(tui_paint accent "отключён ($IPV6_METHOD)")"
        else
            ipv6_state="$(tui_paint good "включён")"
        fi
        if [[ "$DOCKER_GROUP_ADDED" == "true" ]]; then
            docker_state="$(tui_paint warn "включена")"
        else
            docker_state="$(tui_paint muted "выключена")"
        fi

        printf '  %s[1]%s Swap                %s\n' \
            "$C_CYAN" "$C_RESET" "$swap_state"
        printf '      %sПолезен при небольшом объёме RAM%s\n' "$C_DIM" "$C_RESET"
        printf '  %s[2]%s IPv6                %s\n' \
            "$C_CYAN" "$C_RESET" "$ipv6_state"
        printf '      %sВключение или отключение IPv6%s\n' "$C_DIM" "$C_RESET"
        printf '  %s[3]%s Sudo                %s\n' "$C_CYAN" "$C_RESET" \
            "$(tui_paint "$(tui_sudo_mode_tone)" "$(tui_sudo_mode_label)")"
        printf '      %sЗапрос пароля и время действия sudo-сессии%s\n' "$C_DIM" "$C_RESET"
        printf '  %s[4]%s Docker group        %s\n' \
            "$C_CYAN" "$C_RESET" "$docker_state"
        printf '      %sЗапуск Docker без sudo%s\n' "$C_DIM" "$C_RESET"
        tui_menu_item 0 "Назад" muted

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
        tui_title "СОСТОЯНИЕ И ДИАГНОСТИКА"
        echo ""
        tui_show_dashboard
        tui_menu_item 1 "Запустить полную диагностику" primary
        tui_menu_item 2 "Показать подробный статус"
        tui_menu_item 3 "Показать технический JSON"
        tui_menu_item 0 "Назад" muted
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
        tui_title "РЕЗЕРВНЫЕ КОПИИ И ОТКАТ"
        printf '  Сохранённых snapshots: %s\n\n' "$(tui_paint accent "$snapshot_count")"
        tui_menu_item 1 "Показать snapshots"
        tui_menu_item 2 "Посмотреть snapshot"
        tui_menu_item 3 "Создать snapshot"
        tui_menu_item 4 "Восстановить snapshot" warning
        tui_menu_item 5 "Откатить управляемые файлы к начальному состоянию" warning
        tui_menu_item 0 "Назад" muted
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
    local reboot_state

    while true; do
        clear_screen
        show_banner
        tui_title "ОБСЛУЖИВАНИЕ"
        echo ""
        if reboot_required_now; then
            reboot_state="$(tui_paint warn "требуется")"
        else
            reboot_state="$(tui_paint good "не требуется")"
        fi
        printf '  Версия:              %s\n' "$(tui_paint accent "$VERSION")"
        printf '  Перезагрузка:        %s\n\n' "$reboot_state"
        tui_menu_item 1 "Обновить VPSSetup"
        tui_menu_item 2 "Показать последние 100 строк журнала"
        tui_menu_item 3 "Перезагрузить сервер" warning
        tui_menu_item 9 "Удалить VPSSetup" danger
        tui_menu_item 0 "Назад" muted
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
            unconfigured) tui_menu_item 1 "Начать настройку" primary ;;
            ssh_pending) tui_menu_item 1 "Подтвердить новый SSH-порт" primary ;;
            configured) tui_menu_item 1 "Проверить состояние" primary ;;
        esac
        tui_menu_item 2 "Состояние и диагностика"
        tui_menu_item 3 "SSH и сетевой доступ"
        tui_menu_item 4 "Дополнительные настройки"
        tui_menu_item 5 "Резервные копии и откат"
        tui_menu_item 6 "Обслуживание"
        tui_menu_item 0 "Выход" muted
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
