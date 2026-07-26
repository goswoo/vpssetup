#!/usr/bin/env bash

fail2ban_write_jail() {
    require_root setup || return 1
    local ports="$1"
    local target content
    target="$(system_path /etc/fail2ban/jail.d/10-vpssetup-sshd.local)"
    content="[sshd]
enabled = true
backend = systemd
port = ${ports}
maxretry = 5
findtime = 10m
bantime = 10m
"
    atomic_write "$target" 644 "$content" || return 1

    if ! is_test_mode; then
        command_exists fail2ban-client || {
            die "fail2ban-client не найден"
            return 1
        }
        fail2ban-client -t >/dev/null || {
            die "Fail2ban-конфигурация не прошла проверку"
            return 1
        }
        run_systemctl enable --now fail2ban.service >/dev/null || return 1
        run_systemctl restart fail2ban.service || return 1
    fi
    log_success "Fail2ban sshd: порт(ы) $ports, 5 попыток / ban 10m"
}

fail2ban_stage() {
    local ports="$SSH_PORT"
    [[ "$SSH_OLD_PORT" == "$SSH_PORT" ]] || ports="${SSH_OLD_PORT},${SSH_PORT}"
    fail2ban_write_jail "$ports"
}

fail2ban_finalize() {
    fail2ban_write_jail "$SSH_PORT"
}

fail2ban_is_healthy() {
    is_test_mode && return 0
    command_exists fail2ban-client &&
        fail2ban-client status sshd >/dev/null 2>&1
}

