#!/usr/bin/env bash

wait_for_apt() {
    is_test_mode && return 0
    local waited=0
    while command_exists fuser &&
        (fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
            fuser /var/lib/apt/lists/lock >/dev/null 2>&1); do
        if ((waited >= 120)); then
            die "APT остаётся заблокирован более 120 секунд"
            return 1
        fi
        ((waited += 2))
        sleep 2
    done
}

install_base_packages() {
    require_root setup || return 1
    if is_test_mode; then
        log_success "TEST: пакеты и обновления пропущены"
        return 0
    fi

    wait_for_apt || return 1
    export DEBIAN_FRONTEND=noninteractive
    log_info "Обновление индекса пакетов"
    apt-get update || return 1
    log_info "Установка обновлений Ubuntu"
    apt-get upgrade -y || return 1
    log_info "Установка зависимостей"
    apt-get install -y \
        curl wget ca-certificates ufw fail2ban unattended-upgrades \
        openssh-server openssh-client sudo locales || return 1
    log_success "Пакеты готовы"

    if [[ -e /var/run/reboot-required ]]; then
        REBOOT_REQUIRED="true"
        save_state
        log_warn "После обновлений требуется reboot; vpssetup не выполнит его автоматически"
    fi
}

configure_timezone_locale() {
    require_root setup || return 1
    local timezone="${1:-Europe/Moscow}"
    local locale="${2:-en_GB.UTF-8}"

    if is_test_mode; then
        atomic_write "$(system_path /etc/timezone)" 644 "${timezone}"$'\n'
        atomic_write "$(system_path /etc/locale.conf)" 644 "LC_TIME=${locale}"$'\n'
        return 0
    fi

    timedatectl set-timezone "$timezone" || return 1
    local normalized_locale available_locales
    normalized_locale="${locale,,}"
    normalized_locale="${normalized_locale//-/}"
    normalized_locale="${normalized_locale//./}"
    available_locales="$(locale -a | tr '[:upper:]' '[:lower:]' | tr -d '.-')"
    if ! grep -qx "$normalized_locale" <<<"$available_locales"; then
        locale-gen "$locale" || return 1
    fi
    localectl set-locale "LC_TIME=$locale" || return 1
    log_success "Timezone: $timezone; LC_TIME: $locale"
}

ensure_admin_user() {
    require_root setup || return 1
    local username="$1"
    validate_username "$username" || {
        die "Некорректное имя пользователя: $username"
        return 1
    }

    if is_test_mode; then
        mkdir -p "$(system_path "/home/$username")"
        ADMIN_USER="$username"
        save_state
        return 0
    fi

    if id "$username" >/dev/null 2>&1; then
        log_info "Пользователь $username уже существует"
        local home shell
        home="$(getent passwd "$username" | cut -d: -f6)"
        shell="$(getent passwd "$username" | cut -d: -f7)"
        [[ "$home" == "/home/$username" ]] ||
            log_warn "Домашний каталог пользователя нестандартный: $home"
        [[ "$shell" == "/bin/bash" ]] ||
            log_warn "Shell пользователя нестандартный: $shell"
        usermod -aG sudo "$username" || return 1
    else
        useradd -m "$username" -G sudo -s /bin/bash || return 1
        log_success "Создан пользователь $username"
    fi

    ADMIN_USER="$username"
    save_state
}

set_admin_password() {
    require_root setup || return 1
    is_test_mode && return 0
    log_info "Задайте пароль для sudo пользователя $ADMIN_USER"
    passwd "$ADMIN_USER"
}

validate_public_key_file() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    ssh-keygen -lf "$file" >/dev/null 2>&1
}

install_admin_public_key() {
    require_root setup || return 1
    local public_key="$1"
    local home ssh_dir auth_file tmp_key

    if is_test_mode; then
        home="$(system_path "/home/$ADMIN_USER")"
    else
        home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    fi
    [[ -n "$home" ]] || {
        die "Не найден home пользователя $ADMIN_USER"
        return 1
    }

    tmp_key="$(mktemp)"
    printf '%s\n' "$public_key" >"$tmp_key"
    if ! is_test_mode && ! validate_public_key_file "$tmp_key"; then
        rm -f "$tmp_key"
        die "Публичный ключ не прошёл проверку ssh-keygen"
        return 1
    fi
    rm -f "$tmp_key"

    ssh_dir="$home/.ssh"
    auth_file="$ssh_dir/authorized_keys"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_file"
    chmod 600 "$auth_file"

    if ! grep -Fqx "$public_key" "$auth_file"; then
        printf '%s\n' "$public_key" >>"$auth_file"
    fi

    if ! is_test_mode; then
        chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"
    fi
    log_success "SSH-ключ установлен для $ADMIN_USER"
}

select_or_read_public_key() {
    local root_keys
    root_keys="$(system_path /root/.ssh/authorized_keys)"
    local mode
    echo ""
    echo "  [1] Вставить публичный ключ"
    if [[ -r "$root_keys" ]]; then
        echo "  [2] Выбрать ключ из $root_keys"
    fi
    mode="$(read_choice "Источник SSH-ключа" "1")"

    if [[ "$mode" == "2" && -r "$root_keys" ]]; then
        local -a keys=()
        local line index=1
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            keys+=("$line")
            local key_tmp fingerprint
            key_tmp="$(mktemp)"
            printf '%s\n' "$line" >"$key_tmp"
            fingerprint="$(ssh-keygen -lf "$key_tmp" 2>/dev/null || echo "неизвестный fingerprint")"
            rm -f "$key_tmp"
            printf '  [%d] %s\n' "$index" "$fingerprint"
            ((index++))
        done <"$root_keys"

        ((${#keys[@]} > 0)) || {
            die "В $root_keys нет ключей"
            return 1
        }
        local selected
        selected="$(read_choice "Номер ключа" "1")"
        if ! [[ "$selected" =~ ^[0-9]+$ ]] ||
            ! ((selected >= 1 && selected <= ${#keys[@]})); then
            die "Некорректный номер ключа"
            return 1
        fi
        SELECTED_PUBLIC_KEY="${keys[$((selected - 1))]}"
    else
        printf '  Вставьте одну строку публичного ключа: ' >&2
        IFS= read -r SELECTED_PUBLIC_KEY
    fi

    [[ -n "$SELECTED_PUBLIC_KEY" ]] || {
        die "Пустой SSH-ключ"
        return 1
    }
}

configure_unattended_upgrades() {
    require_root setup || return 1
    local target content
    target="$(system_path /etc/apt/apt.conf.d/52vpssetup-auto-upgrades)"
    content='// Managed by VPSSetup
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
'
    atomic_write "$target" 644 "$content" || return 1
    run_systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    log_success "Security updates включены; automatic reboot выключен"
}
