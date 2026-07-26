#!/usr/bin/env bash

ssh_dropin_path() {
    system_path /etc/ssh/sshd_config.d/00-vpssetup.conf
}

render_ssh_stage_config() {
    local old_port="$1"
    local new_port="$2"
    local keep_hardening="${3:-false}"
    cat <<EOF
# Managed by VPSSetup — staged access
Port ${old_port}
EOF
    if [[ "$new_port" != "$old_port" ]]; then
        printf 'Port %s\n' "$new_port"
    fi
    cat <<'EOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
    if [[ "$keep_hardening" == "true" ]]; then
        cat <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
    fi
}

render_ssh_final_config() {
    local port="$1"
    cat <<EOF
# Managed by VPSSetup — confirmed hardening
Port ${port}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
}

validate_sshd_config() {
    local config runtime_dir
    config="$(system_path /etc/ssh/sshd_config)"
    runtime_dir="$(system_path /run/sshd)"
    mkdir -p "$runtime_dir" || {
        die "Не удалось создать $runtime_dir"
        return 1
    }
    chmod 755 "$runtime_dir"
    is_test_mode && return 0
    command_exists sshd || {
        die "sshd не найден"
        return 1
    }
    sshd -t -f "$config"
}

validate_effective_ssh_hardening() {
    is_test_mode && return 0
    local config output
    config="$(system_path /etc/ssh/sshd_config)"
    output="$(sshd -T -f "$config" \
        -C "user=${ADMIN_USER},host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 1
    grep -qx "permitrootlogin no" <<<"$output" &&
        grep -qx "passwordauthentication no" <<<"$output" &&
        grep -qx "kbdinteractiveauthentication no" <<<"$output" &&
        grep -qx "pubkeyauthentication yes" <<<"$output" &&
        grep -qx "port ${SSH_PORT}" <<<"$output"
}

reload_ssh() {
    is_test_mode && return 0
    run_systemctl daemon-reload || return 1
    if systemctl is-active --quiet ssh.socket; then
        SSH_SERVICE_MODE="socket"
        systemctl restart ssh.socket || return 1
        systemctl try-reload-or-restart ssh.service >/dev/null 2>&1 || true
    else
        SSH_SERVICE_MODE="service"
        systemctl reload-or-restart ssh.service || return 1
    fi
}

ssh_service_fallback() {
    is_test_mode && return 0
    log_warn "Socket activation не открыл новый порт."
    confirm "Переключить OpenSSH на ssh.service, сохранив текущую сессию?" "N" || return 1
    systemctl disable --now ssh.socket || return 1
    systemctl enable --now ssh.service || return 1
    systemctl restart ssh.service || return 1
    SSH_SERVICE_MODE="service"
}

ensure_ssh_listener() {
    local port="$1"
    port_is_listening "$port" && return 0
    ssh_service_fallback || return 1
    port_is_listening "$port"
}

ssh_stage() {
    require_root ssh stage || return 1
    local target_port="${1:-}"
    validate_port "$target_port" || {
        die "Некорректный SSH-порт: $target_port"
        return 1
    }
    if [[ "$PHASE" == "ssh_pending" ]]; then
        die "SSH stage уже ожидает confirm на порту $SSH_PORT"
        return 1
    fi
    if [[ "$PHASE" == "configured" && "$target_port" == "$SSH_PORT" ]]; then
        log_info "SSH уже подтверждён на порту $SSH_PORT; изменений нет"
        return 0
    fi

    local current_port
    current_port="$(current_ssh_server_port)"
    validate_port "$current_port" || current_port=22

    if [[ "$target_port" != "$current_port" ]] && ! port_is_available "$target_port"; then
        die "Порт $target_port уже занят"
        return 1
    fi

    backup_create "pre-ssh-stage" || return 1
    local safety_id="$LAST_BACKUP_ID"
    local keep_hardening="$SSH_CONFIRMED"
    SSH_OLD_PORT="$current_port"
    SSH_PORT="$target_port"

    local content
    content="$(render_ssh_stage_config "$SSH_OLD_PORT" "$SSH_PORT" "$keep_hardening")"$'\n'
    atomic_write "$(ssh_dropin_path)" 600 "$content" || return 1
    validate_sshd_config || {
        backup_restore_files "$safety_id" || true
        die "Staged SSH-конфиг отклонён; исходные файлы восстановлены"
        return 1
    }
    ufw_prepare_stage "$SSH_OLD_PORT" "$SSH_PORT" || {
        backup_restore_files "$safety_id" || true
        reload_managed_services || true
        return 1
    }
    if ! reload_ssh || ! ensure_ssh_listener "$SSH_PORT"; then
        backup_restore_files "$safety_id" || true
        reload_managed_services || true
        die "Новый SSH-порт не открылся; выполнен rollback"
        return 1
    fi

    fail2ban_stage || {
        backup_restore_files "$safety_id" || true
        reload_managed_services || true
        return 1
    }

    PHASE="ssh_pending"
    SSH_CONFIRMED="false"
    save_state
    log_success "SSH staged: старый порт $SSH_OLD_PORT сохранён, новый порт $SSH_PORT слушает"
    log_warn "Не закрывайте текущую сессию. Войдите как $ADMIN_USER на порт $SSH_PORT."
    log_info "Из новой сессии выполните: sudo vpssetup ssh confirm"
}

ssh_confirm_session_is_safe() {
    is_test_mode && return 0
    if [[ "${1:-}" == "--force-console" ]]; then
        [[ -t 0 ]] || return 1
        local phrase=""
        printf '  Для console override введите новый порт (%s): ' "$SSH_PORT" >&2
        IFS= read -r phrase
        [[ "$phrase" == "$SSH_PORT" ]]
        return
    fi

    [[ "${SUDO_USER:-}" == "$ADMIN_USER" ]] || return 1
    [[ -n "${SSH_CONNECTION:-}" ]] || return 1
    local connected_port
    connected_port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    [[ "$connected_port" == "$SSH_PORT" ]]
}

ssh_confirm() {
    require_root ssh confirm || return 1
    [[ "$PHASE" == "ssh_pending" ]] || {
        die "Нет ожидающего SSH-переключения"
        return 1
    }
    ssh_confirm_session_is_safe "${1:-}" || {
        die "Подтверждение разрешено из новой SSH-сессии $ADMIN_USER@$SSH_PORT через sudo"
        log_info "Для provider console доступен: sudo vpssetup ssh confirm --force-console"
        return 1
    }

    backup_create "pre-ssh-confirm" || return 1
    local safety_id="$LAST_BACKUP_ID"
    local content
    content="$(render_ssh_final_config "$SSH_PORT")"$'\n'
    atomic_write "$(ssh_dropin_path)" 600 "$content" || return 1

    if ! validate_sshd_config || ! validate_effective_ssh_hardening; then
        backup_restore_files "$safety_id" || true
        die "Эффективная SSH-конфигурация не соответствует hardening policy"
        return 1
    fi

    if ! reload_ssh || ! ensure_ssh_listener "$SSH_PORT"; then
        backup_restore_files "$safety_id" || true
        reload_ssh || true
        die "SSH после hardening не слушает $SSH_PORT; выполнен rollback"
        return 1
    fi
    fail2ban_finalize || {
        backup_restore_files "$safety_id" || true
        reload_managed_services || true
        return 1
    }
    ufw_finalize_ssh || {
        log_warn "SSH hardened, но старое UFW-правило не удалено; устраните drift через health"
        return 1
    }

    PHASE="configured"
    SSH_CONFIRMED="true"
    save_state
    log_success "SSH hardening подтверждён на порту $SSH_PORT"
}

ssh_status() {
    printf '  Фаза:            %s\n' "$PHASE"
    printf '  Администратор:   %s\n' "$ADMIN_USER"
    printf '  Старый порт:     %s\n' "$SSH_OLD_PORT"
    printf '  Целевой порт:    %s\n' "$SSH_PORT"
    printf '  Подтверждено:    %s\n' "$SSH_CONFIRMED"
    printf '  Режим службы:    %s\n' "$SSH_SERVICE_MODE"
    if port_is_listening "$SSH_PORT"; then
        printf '  Listener %s:     active\n' "$SSH_PORT"
    else
        printf '  Listener %s:     missing\n' "$SSH_PORT"
    fi
}
