#!/usr/bin/env bash

fstab_path() {
    system_path /etc/fstab
}

module_swap_enable() {
    require_root module swap enable || return 1
    local size="${1:-2G}"
    validate_swap_size "$size" || {
        die "Размер swap должен иметь вид 512M или 2G"
        return 1
    }
    [[ -z "$MANAGED_SWAPFILE" ]] || {
        die "Управляемый swap уже существует: $MANAGED_SWAPFILE"
        return 1
    }

    if ! is_test_mode && swapon --show=NAME --noheadings | grep -q '[^[:space:]]'; then
        die "В системе уже есть swap; vpssetup не будет создавать второй"
        return 1
    fi

    backup_create "pre-module-swap" || return 1
    local logical="/swapfile"
    local actual
    actual="$(system_path "$logical")"
    mkdir -p "$(dirname "$actual")"

    if is_test_mode; then
        truncate -s 1M "$actual"
    elif ! fallocate -l "$size" "$actual"; then
        local count_mb
        case "${size: -1}" in
            G|g) count_mb=$((${size%?} * 1024)) ;;
            *) count_mb="${size%?}" ;;
        esac
        dd if=/dev/zero of="$actual" bs=1M count="$count_mb" status=progress || return 1
    fi
    chmod 600 "$actual"

    if ! is_test_mode; then
        mkswap "$actual" >/dev/null || return 1
        swapon "$actual" || return 1
    fi

    local fstab
    fstab="$(fstab_path)"
    touch "$fstab"
    if ! grep -Fq "$logical none swap sw 0 0 # vpssetup" "$fstab"; then
        printf '%s\n' "$logical none swap sw 0 0 # vpssetup" >>"$fstab"
    fi
    MANAGED_SWAPFILE="$logical"
    save_state
    log_success "Создан swap $logical размером $size"
}

module_swap_disable() {
    require_root module swap disable || return 1
    [[ -n "$MANAGED_SWAPFILE" ]] || {
        log_info "Управляемый swap не включён"
        return 0
    }
    local actual fstab tmp
    actual="$(system_path "$MANAGED_SWAPFILE")"
    fstab="$(fstab_path)"
    backup_create "pre-disable-swap" || return 1

    is_test_mode || swapoff "$actual" || return 1
    if [[ -f "$fstab" ]]; then
        tmp="$(mktemp)"
        awk '!/#[[:space:]]*vpssetup[[:space:]]*$/' "$fstab" >"$tmp"
        chmod --reference="$fstab" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        mv "$tmp" "$fstab"
    fi
    rm -f "$actual"
    MANAGED_SWAPFILE=""
    save_state
    log_success "Управляемый swap удалён"
}

read_ufw_ipv6_value() {
    local file
    file="$(system_path /etc/default/ufw)"
    if [[ ! -f "$file" ]]; then
        printf 'missing\n'
    else
        local value
        value="$(awk -F= '$1 == "IPV6" {print $2; exit}' "$file")"
        printf '%s\n' "${value:-unset}"
    fi
}

set_ufw_ipv6_value() {
    local value="$1"
    local file tmp
    file="$(system_path /etc/default/ufw)"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp="$(mktemp)"
    awk -v value="$value" '
        BEGIN {done=0}
        /^IPV6=/ {
            if (!done) print "IPV6=" value
            done=1
            next
        }
        {print}
        END {if (!done) print "IPV6=" value}
    ' "$file" >"$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv "$tmp" "$file"
}

module_ipv6_enable() {
    require_root module ipv6 enable || return 1
    local method="${1:-sysctl}"
    [[ "$method" == "sysctl" || "$method" == "grub" ]] || {
        die "Метод IPv6: sysctl или grub"
        return 1
    }
    [[ -z "$IPV6_METHOD" ]] || {
        die "IPv6 уже управляется методом $IPV6_METHOD"
        return 1
    }
    backup_create "pre-module-ipv6-${method}" || return 1
    IPV6_UFW_PREVIOUS="$(read_ufw_ipv6_value)"

    if [[ "$method" == "sysctl" ]]; then
        atomic_write "$(system_path /etc/sysctl.d/99-vpssetup-disable-ipv6.conf)" 644 \
            "# Managed by VPSSetup
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
" || return 1
        is_test_mode || sysctl --system >/dev/null || return 1
    else
        # shellcheck disable=SC2016
        atomic_write "$(system_path /etc/default/grub.d/99-vpssetup-ipv6.cfg)" 644 \
            '# Managed by VPSSetup
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} ipv6.disable=1"
' || return 1
        is_test_mode || update-grub || return 1
        mark_reboot_required
    fi

    set_ufw_ipv6_value no
    is_test_mode || ufw reload >/dev/null 2>&1 || true
    IPV6_METHOD="$method"
    save_state
    log_success "IPv6 disable настроен методом $method"
    if [[ "$method" == "grub" ]]; then
        log_warn "Требуется ручной reboot"
    fi
}

module_ipv6_disable() {
    require_root module ipv6 disable || return 1
    [[ -n "$IPV6_METHOD" ]] || {
        log_info "IPv6-модуль не включён"
        return 0
    }
    local method="$IPV6_METHOD"
    backup_create "pre-disable-ipv6" || return 1
    rm -f "$(system_path /etc/sysctl.d/99-vpssetup-disable-ipv6.conf)"
    rm -f "$(system_path /etc/default/grub.d/99-vpssetup-ipv6.cfg)"

    case "$IPV6_UFW_PREVIOUS" in
        yes|no|YES|NO) set_ufw_ipv6_value "$IPV6_UFW_PREVIOUS" ;;
        unset)
            local file tmp
            file="$(system_path /etc/default/ufw)"
            tmp="$(mktemp)"
            awk '$0 !~ /^IPV6=/' "$file" >"$tmp"
            chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
            mv "$tmp" "$file"
            ;;
        missing) rm -f "$(system_path /etc/default/ufw)" ;;
    esac

    if ! is_test_mode; then
        if [[ "$method" == "sysctl" ]]; then
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null || true
        else
            update-grub >/dev/null || true
        fi
        ufw reload >/dev/null 2>&1 || true
    fi
    IPV6_METHOD=""
    IPV6_UFW_PREVIOUS=""
    save_state
    log_success "Управляемое отключение IPv6 снято"
    if [[ "$method" == "grub" ]]; then
        log_warn "Для полного включения IPv6 после GRUB нужен reboot"
    fi
}

sudo_policy_path() {
    system_path /etc/sudoers.d/90-vpssetup-sudo
}

legacy_sudo_timeout_path() {
    system_path /etc/sudoers.d/90-vpssetup-timeout
}

sudo_policy_is_applied() {
    local mode="$1"
    local target legacy
    target="$(sudo_policy_path)"
    legacy="$(legacy_sudo_timeout_path)"
    [[ ! -e "$legacy" ]] || return 1

    case "$mode" in
        standard) [[ ! -e "$target" ]] ;;
        timeout)
            [[ -r "$target" ]] &&
                grep -Fqx "Defaults:${ADMIN_USER} timestamp_timeout=60" "$target"
            ;;
        nopasswd)
            [[ -r "$target" ]] &&
                grep -Fqx "${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL" "$target"
            ;;
        *) return 1 ;;
    esac
}

module_sudo_set() {
    require_root module sudo || return 1
    local mode="${1:-standard}"
    case "$mode" in
        standard|timeout|nopasswd) ;;
        *) die "Режим sudo: standard, timeout или nopasswd"; return 1 ;;
    esac

    local target legacy
    target="$(sudo_policy_path)"
    legacy="$(legacy_sudo_timeout_path)"
    if [[ "$mode" == "$SUDO_MODE" ]] && sudo_policy_is_applied "$mode"; then
        log_info "Выбранный режим sudo уже активен"
        return 0
    fi

    backup_create "pre-module-sudo-${mode}" || return 1

    if [[ "$mode" == "standard" ]]; then
        rm -f "$target" "$legacy"
    else
        local content dir tmp
        if [[ "$mode" == "timeout" ]]; then
            content="# Managed by VPSSetup
Defaults:${ADMIN_USER} timestamp_timeout=60
"
        else
            content="# Managed by VPSSetup
${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD: ALL
"
        fi

        dir="$(dirname "$target")"
        mkdir -p "$dir"
        tmp="$(mktemp "$dir/.vpssetup-sudo.XXXXXX")" || return 1
        printf '%s' "$content" >"$tmp"
        chmod 440 "$tmp"
        if ! is_test_mode && ! visudo -cf "$tmp" >/dev/null; then
            rm -f "$tmp"
            die "sudoers drop-in не прошёл visudo"
            return 1
        fi
        mv -f "$tmp" "$target"
        rm -f "$legacy"
    fi

    SUDO_MODE="$mode"
    save_state
    case "$mode" in
        standard) log_success "sudo: стандартный запрос пароля" ;;
        timeout) log_success "sudo: пароль действует 60 минут" ;;
        nopasswd) log_success "sudo: NOPASSWD включён для $ADMIN_USER" ;;
    esac
}

module_sudo_timeout_enable() {
    module_sudo_set timeout
}

module_sudo_timeout_disable() {
    module_sudo_set standard
}

module_docker_group_enable() {
    require_root module docker-group enable || return 1
    is_test_mode || command_exists docker || {
        die "Docker не установлен; vpssetup не устанавливает его автоматически"
        return 1
    }

    if is_test_mode; then
        DOCKER_GROUP_ADDED="true"
    elif id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx docker; then
        DOCKER_GROUP_ADDED="false"
        log_info "$ADMIN_USER уже состоит в группе docker"
    else
        getent group docker >/dev/null || groupadd docker || return 1
        usermod -aG docker "$ADMIN_USER" || return 1
        DOCKER_GROUP_ADDED="true"
    fi
    save_state
    log_success "Docker group настроена; выполните relogin пользователя $ADMIN_USER"
}

module_docker_group_disable() {
    require_root module docker-group disable || return 1
    if [[ "$DOCKER_GROUP_ADDED" == "true" ]] && ! is_test_mode; then
        gpasswd -d "$ADMIN_USER" docker >/dev/null || return 1
    fi
    DOCKER_GROUP_ADDED="false"
    save_state
    log_success "Управляемое членство в docker group снято"
}

module_list() {
    printf '  %-18s %s\n' "swap" "${MANAGED_SWAPFILE:-off}"
    printf '  %-18s %s\n' "ipv6" "${IPV6_METHOD:-off}"
    printf '  %-18s %s\n' "sudo" "$SUDO_MODE"
    printf '  %-18s %s\n' "docker-group" "$DOCKER_GROUP_ADDED"
}

module_dispatch() {
    local action="${1:-list}"
    local name="${2:-}"
    shift 2 2>/dev/null || true

    case "$action" in
        list|status) module_list ;;
        enable)
            case "$name" in
                swap) module_swap_enable "${1:-2G}" ;;
                ipv6) module_ipv6_enable "${1:-sysctl}" ;;
                sudo) module_sudo_set "${1:-timeout}" ;;
                sudo-timeout) module_sudo_timeout_enable ;;
                docker-group) module_docker_group_enable ;;
                *) die "Неизвестный модуль: $name"; return 1 ;;
            esac
            ;;
        disable)
            case "$name" in
                swap) module_swap_disable ;;
                ipv6) module_ipv6_disable ;;
                sudo) module_sudo_set standard ;;
                sudo-timeout) module_sudo_timeout_disable ;;
                docker-group) module_docker_group_disable ;;
                *) die "Неизвестный модуль: $name"; return 1 ;;
            esac
            ;;
        *) die "Использование: vpssetup module list|enable|disable <name>"; return 1 ;;
    esac
}
