#!/usr/bin/env bash

prompt_setup_values() {
    local username port timezone locale
    username="$(read_choice "Административный пользователь" "$ADMIN_USER")"
    validate_username "$username" || {
        die "Некорректное имя пользователя"
        return 1
    }
    port="$(read_required_port "Новый SSH-порт")" || return 1
    timezone="$(read_choice "Timezone" "Europe/Moscow")"
    locale="$(read_choice "LC_TIME" "en_GB.UTF-8")"

    SETUP_USERNAME="$username"
    SETUP_SSH_PORT="$port"
    SETUP_TIMEZONE="$timezone"
    SETUP_LOCALE="$locale"
    if confirm "Открыть optional HTTP 80/tcp?" "N"; then
        SETUP_ENABLE_HTTP="true"
    else
        SETUP_ENABLE_HTTP="false"
    fi
}

run_setup_wizard() {
    require_root setup || return 1
    require_ubuntu_2404 || return 1

    if [[ "$PHASE" == "ssh_pending" ]]; then
        log_warn "Setup уже выполнен до стадии SSH confirmation"
        ssh_status
        log_info "Войдите на порт $SSH_PORT как $ADMIN_USER и выполните sudo vpssetup ssh confirm"
        return 2
    fi
    if [[ "$PHASE" == "configured" ]]; then
        log_info "VPSSetup уже настроен; запускаю health check"
        health_check
        return
    fi

    show_banner
    log_warn "Мастер обновит пакеты и системную конфигурацию."
    log_warn "Текущая SSH-сессия должна оставаться открытой до confirm."
    confirm "Начать setup?" "N" || {
        log_info "Setup отменён"
        return 0
    }

    if [[ -z "$INITIAL_BACKUP_ID" ]]; then
        backup_create initial || return 1
    fi
    prompt_setup_values || return 1
    confirm "Выполнить apt update && apt upgrade -y?" "Y" || {
        die "Полный upgrade обязателен для выбранного профиля setup"
        return 1
    }

    install_base_packages || return 1
    configure_timezone_locale "$SETUP_TIMEZONE" "$SETUP_LOCALE" || return 1
    ensure_admin_user "$SETUP_USERNAME" || return 1
    set_admin_password || return 1
    select_or_read_public_key || return 1
    install_admin_public_key "$SELECTED_PUBLIC_KEY" || return 1
    configure_unattended_upgrades || return 1
    ssh_stage "$SETUP_SSH_PORT" || return 1
    if [[ "$SETUP_ENABLE_HTTP" == "true" ]]; then
        ufw_enable_optional_http || log_warn "Не удалось добавить optional HTTP rule"
    fi

    echo ""
    log_success "Базовая стадия завершена"
    log_info "Откройте новую сессию: ssh -p $SSH_PORT $ADMIN_USER@<server>"
    log_info "Затем: sudo vpssetup ssh confirm"
}

manager_uninstall() {
    require_root uninstall || return 1
    log_warn "Hardening, пользователь, SSH/UFW и системные модули останутся без изменений."
    confirm "Удалить только менеджер VPSSetup?" "N" || {
        log_info "Удаление отменено"
        return 0
    }

    local keep_backups="true"
    confirm "Сохранить snapshots и журнал?" "Y" || keep_backups="false"
    local binary
    binary="$(system_path /usr/local/bin/vpssetup)"
    rm -f "$binary"

    if [[ "$keep_backups" == "false" ]]; then
        rm -rf "$STATE_DIR" "$LOG_DIR"
    else
        rm -f "$STATE_FILE" "$STATE_DIR/manager.lock"
    fi
    if [[ "$INSTALL_DIR" == /opt/vpssetup ||
        "$INSTALL_DIR" == "$(system_path /opt/vpssetup)" ]]; then
        rm -rf "$INSTALL_DIR"
    else
        log_warn "Checkout $INSTALL_DIR не удалён"
    fi
    log_success "Менеджер удалён; системная конфигурация сохранена"
}
