#!/usr/bin/env bash

ssh_listener_status() {
    if port_is_listening "$SSH_PORT"; then
        printf 'true'
    else
        printf 'false'
    fi
}

reboot_required_now() {
    [[ -e "$(system_path /var/run/reboot-required)" ]] && return 0
    [[ "$REBOOT_REQUIRED" == "true" && -n "$REBOOT_BOOT_ID" ]] || return 1
    [[ "$REBOOT_BOOT_ID" == "$(current_boot_id)" ]]
}

status_has_drift() {
    [[ "$PHASE" != "configured" ]] && return 0
    [[ "$PHASE" == "configured" ]] && ! port_is_listening "$SSH_PORT" && return 0
    return 1
}

show_status_json() {
    local listener ufw_status f2b reboot drift
    listener="$(ssh_listener_status)"
    ufw_status="$(ufw_status_summary)"
    if fail2ban_is_healthy; then f2b=true; else f2b=false; fi
    if reboot_required_now; then reboot=true; else reboot=false; fi
    if status_has_drift; then drift='["ssh_or_phase"]'; else drift='[]'; fi

    printf '{'
    printf '"version":"%s",' "$(json_escape "$VERSION")"
    printf '"phase":"%s",' "$(json_escape "$PHASE")"
    printf '"admin_user":"%s",' "$(json_escape "$ADMIN_USER")"
    printf '"ssh":{"old_port":%s,"target_port":%s,"confirmed":%s,"listening":%s},' \
        "$SSH_OLD_PORT" "$SSH_PORT" "$SSH_CONFIRMED" "$listener"
    printf '"ufw":{"status":"%s"},' "$(json_escape "$ufw_status")"
    printf '"fail2ban":{"healthy":%s},' "$f2b"
    printf '"unattended_upgrades":{"configured":%s},' \
        "$([[ -f "$(system_path /etc/apt/apt.conf.d/52vpssetup-auto-upgrades)" ]] && echo true || echo false)"
    printf '"modules":{"swap":%s,"ipv6":"%s","sudo_timeout":%s,"docker_group":%s,"icmp_rate_limit":%s},' \
        "$([[ -n "$MANAGED_SWAPFILE" ]] && echo true || echo false)" \
        "$(json_escape "${IPV6_METHOD:-off}")" \
        "$SUDO_TIMEOUT_ENABLED" "$DOCKER_GROUP_ADDED" "$ICMP_LIMIT_ENABLED"
    printf '"reboot_required":%s,' "$reboot"
    printf '"drift":%s' "$drift"
    printf '}\n'
}

show_status() {
    local listener="missing"
    port_is_listening "$SSH_PORT" && listener="active"
    echo ""
    printf '  %sVPSSetup v%s%s\n' "$C_BOLD" "$VERSION" "$C_RESET"
    printf '  %-22s %s\n' "Фаза" "$PHASE"
    printf '  %-22s %s\n' "Администратор" "$ADMIN_USER"
    printf '  %-22s %s (%s)\n' "SSH" "$SSH_PORT" "$listener"
    printf '  %-22s %s\n' "UFW" "$(ufw_status_summary)"
    printf '  %-22s %s\n' "Fail2ban" \
        "$(fail2ban_is_healthy && echo healthy || echo unavailable)"
    printf '  %-22s %s\n' "Reboot required" \
        "$(reboot_required_now && echo yes || echo no)"
    echo ""
    module_list
}

health_check() {
    local failures=0 warnings=0
    echo ""
    log_info "Проверка VPSSetup"

    if require_ubuntu_2404; then
        log_success "OS: Ubuntu 24.04"
    else
        ((failures++))
    fi

    if [[ "$PHASE" == "configured" ]]; then
        if port_is_listening "$SSH_PORT"; then
            log_success "SSH слушает $SSH_PORT"
        else
            log_error "SSH не слушает $SSH_PORT"
            ((failures++))
        fi
        if validate_effective_ssh_hardening; then
            log_success "SSH effective policy соответствует hardening"
        else
            log_error "SSH effective policy имеет drift"
            ((failures++))
        fi
    elif [[ "$PHASE" == "ssh_pending" ]]; then
        log_warn "SSH ожидает подтверждения из новой сессии"
        ((warnings++))
    else
        log_warn "Базовая настройка не завершена"
        ((warnings++))
    fi

    if ufw_is_active; then
        log_success "UFW active"
    else
        log_error "UFW inactive"
        ((failures++))
    fi

    if fail2ban_is_healthy; then
        log_success "Fail2ban jail sshd active"
    else
        log_error "Fail2ban jail sshd недоступен"
        ((failures++))
    fi

    if [[ -f "$(system_path /etc/apt/apt.conf.d/52vpssetup-auto-upgrades)" ]]; then
        log_success "Unattended upgrades configured"
    else
        log_error "Unattended upgrades drop-in отсутствует"
        ((failures++))
    fi

    if reboot_required_now; then
        log_warn "Требуется ручной reboot"
        ((warnings++))
    fi

    if ((failures > 0)); then
        log_error "Health: $failures ошибок, $warnings предупреждений"
        return 1
    fi
    if ((warnings > 0)); then
        log_warn "Health: без ошибок, $warnings предупреждений"
        return 2
    fi
    log_success "Health: healthy"
}
