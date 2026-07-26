#!/usr/bin/env bash

BACKUP_KEEP_RECENT=5

backup_ids_newest_first() {
    [[ -d "$BACKUP_DIR" ]] || return 0

    local dir id created directory_mtime
    while IFS= read -r dir; do
        id="$(basename "$dir")"
        created="$(sed -n '1p' "$dir/created-at" 2>/dev/null || true)"
        if [[ ! "$created" =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z$ ]]; then
            created="${id:0:15}.000000000Z"
        fi
        directory_mtime="$(stat -c '%Y' "$dir" 2>/dev/null || echo 0)"
        printf '%s\t%s\t%s\n' "$created" "$directory_mtime" "$id"
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d) |
        sort -t $'\t' -k1,1r -k2,2nr |
        cut -f3-
}

managed_backup_paths() {
    cat <<'EOF'
/etc/ssh/sshd_config.d/00-vpssetup.conf
/etc/fail2ban/jail.d/10-vpssetup-sshd.local
/etc/apt/apt.conf.d/52vpssetup-auto-upgrades
/etc/sudoers.d/90-vpssetup-timeout
/etc/sysctl.d/99-vpssetup-disable-ipv6.conf
/etc/default/grub.d/99-vpssetup-ipv6.cfg
/etc/default/ufw
/etc/ufw/before.rules
/etc/ufw/user.rules
/etc/ufw/user6.rules
/etc/fstab
/etc/localtime
/etc/timezone
/etc/locale.conf
EOF
}

backup_prune() {
    local protected_id="${1:-}"
    local kept=0 id

    [[ -d "$BACKUP_DIR" ]] || return 0

    while IFS= read -r id; do
        [[ "$id" == "$INITIAL_BACKUP_ID" ]] && continue
        if ((kept < BACKUP_KEEP_RECENT)); then
            kept=$((kept + 1))
            continue
        fi
        [[ -n "$protected_id" && "$id" == "$protected_id" ]] && continue
        backup_validate_id "$id" || {
            log_warn "Пропущен повреждённый snapshot при очистке: $id"
            continue
        }
        rm -rf -- "${BACKUP_DIR:?}/$id"
        log_info "Удалён старый snapshot: $id"
    done < <(backup_ids_newest_first)
}

backup_create() {
    require_root backup create || return 1
    local label="${1:-manual}"
    local protected_id="${2:-}"
    local timestamp id target manifest
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    id="${timestamp}-$(safe_id "$label")"
    local suffix=1
    while [[ -e "$BACKUP_DIR/$id" ]]; do
        id="${timestamp}-$(safe_id "$label")-${suffix}"
        ((suffix++))
    done
    target="$BACKUP_DIR/$id"
    manifest="$target/manifest.tsv"

    mkdir -p "$target/files"
    chmod 700 "$BACKUP_DIR" "$target"
    printf '# present\trelative_path\n' >"$manifest"

    local logical actual relative
    while IFS= read -r logical; do
        [[ -n "$logical" ]] || continue
        actual="$(system_path "$logical")"
        relative="${logical#/}"
        if [[ -e "$actual" || -L "$actual" ]]; then
            printf 'yes\t%s\n' "$relative" >>"$manifest"
            mkdir -p "$target/files/$(dirname "$relative")"
            cp -a "$actual" "$target/files/$relative"
        else
            printf 'no\t%s\n' "$relative" >>"$manifest"
        fi
    done < <(managed_backup_paths)

    printf '%s\n' "$label" >"$target/label"
    # VERSION is initialized by the main entrypoint before this library is sourced.
    # shellcheck disable=SC2153
    printf '%s\n' "$VERSION" >"$target/version"
    date -u '+%Y%m%dT%H%M%S.%NZ' >"$target/created-at"
    if ufw_is_active; then
        printf 'active\n' >"$target/ufw-state"
    else
        printf 'inactive\n' >"$target/ufw-state"
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        save_state
    fi

    LAST_BACKUP_ID="$id"
    [[ -n "$INITIAL_BACKUP_ID" ]] || INITIAL_BACKUP_ID="$id"
    save_state
    cp -a "$STATE_FILE" "$target/manager-state.conf"
    chmod -R go-rwx "$target"
    backup_prune "$protected_id"
    log_success "Создан snapshot: $id"
}

backup_list() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "Snapshots пока нет"
        return 0
    fi

    local id label
    while IFS= read -r id; do
        label="$(sed -n '1p' "$BACKUP_DIR/$id/label" 2>/dev/null || true)"
        printf '  %-34s %s\n' "$id" "$label"
    done < <(backup_ids_newest_first)
}

backup_show() {
    local id="${1:-}"
    backup_validate_id "$id" || {
        die "Snapshot не найден или повреждён: ${id:-<пусто>}"
        return 1
    }

    local source="$BACKUP_DIR/$id"
    local label version created ufw_state present relative file_state
    label="$(sed -n '1p' "$source/label" 2>/dev/null || true)"
    version="$(sed -n '1p' "$source/version" 2>/dev/null || true)"
    created="$(sed -n '1p' "$source/created-at" 2>/dev/null || true)"
    [[ -n "$created" ]] || created="${id:0:16}"
    ufw_state="$(backup_ufw_state "$id")"

    printf 'Snapshot: %s\n' "$id"
    printf '  Метка: %s\n' "${label:-—}"
    printf '  Создан UTC: %s\n' "$created"
    printf '  Версия VPSSetup: %s\n' "${version:-—}"
    printf '  UFW: %s\n' "$ufw_state"
    printf '  Состояние менеджера: %s\n' \
        "$([[ -r "$source/manager-state.conf" ]] && echo "сохранено" || echo "нет")"
    printf '  Файлы:\n'

    while IFS=$'\t' read -r present relative; do
        [[ "$present" == "yes" || "$present" == "no" ]] || continue
        if [[ "$present" == "yes" ]]; then
            file_state="сохранён"
        else
            file_state="отсутствовал"
        fi
        printf '    %-12s /%s\n' "$file_state" "$relative"
    done <"$source/manifest.tsv"
}

backup_validate_id() {
    local id="${1:-}"
    [[ "$id" =~ ^[A-Za-z0-9_.-]+$ ]] &&
        [[ -r "$BACKUP_DIR/$id/manifest.tsv" ]]
}

backup_restore_files() {
    local id="$1"
    local source="$BACKUP_DIR/$id"
    local present relative target saved

    while IFS=$'\t' read -r present relative; do
        [[ "$present" == "yes" || "$present" == "no" ]] || continue
        [[ "$relative" != /* && "$relative" != *".."* ]] || {
            die "Небезопасный путь в manifest: $relative"
            return 1
        }
        target="$(system_path "/$relative")"
        saved="$source/files/$relative"
        mkdir -p "$(dirname "$target")"
        if [[ "$present" == "yes" ]]; then
            [[ -e "$saved" || -L "$saved" ]] || {
                die "Snapshot повреждён: отсутствует $relative"
                return 1
            }
            rm -f "$target"
            cp -a "$saved" "$target"
        else
            rm -f "$target"
        fi
    done <"$source/manifest.tsv"
}

backup_ufw_state() {
    local id="$1"
    local saved="$BACKUP_DIR/$id/ufw-state"
    if [[ -r "$saved" ]]; then
        sed -n '1p' "$saved"
    else
        printf 'preserve\n'
    fi
}

backup_apply_ufw_state() {
    local desired="$1"
    case "$desired" in
        preserve) return 0 ;;
        active|inactive) ;;
        *) die "Некорректное состояние UFW в snapshot"; return 1 ;;
    esac

    if is_test_mode; then
        local marker
        marker="$(system_path /var/lib/vpssetup-test/ufw-active)"
        mkdir -p "$(dirname "$marker")"
        if [[ "$desired" == "active" ]]; then
            touch "$marker"
        else
            rm -f "$marker"
        fi
        return 0
    fi

    command_exists ufw || return 0
    if [[ "$desired" == "active" ]]; then
        ufw --force enable >/dev/null
    else
        ufw --force disable >/dev/null
    fi
}

validate_restored_system_files() {
    local sshd_config sudoers_dir
    sshd_config="$(system_path /etc/ssh/sshd_config)"
    sudoers_dir="$(system_path /etc/sudoers.d)"

    if ! is_test_mode && command_exists sshd && [[ -r "$sshd_config" ]]; then
        validate_sshd_config || {
            die "Восстановленный SSH-конфиг не прошёл sshd -t"
            return 1
        }
    fi

    if ! is_test_mode && command_exists visudo && [[ -d "$sudoers_dir" ]]; then
        visudo -c >/dev/null || {
            die "Восстановленная sudo-конфигурация некорректна"
            return 1
        }
    fi
}

reload_managed_services() {
    is_test_mode && return 0
    command_exists systemctl || return 0
    systemctl daemon-reload || true
    if systemctl is-active --quiet ssh.socket; then
        systemctl restart ssh.socket || return 1
        systemctl try-reload-or-restart ssh.service >/dev/null 2>&1 || true
    else
        systemctl reload-or-restart ssh.service || return 1
    fi
    if command_exists ufw; then
        ufw reload >/dev/null 2>&1 || true
    fi
    systemctl restart fail2ban.service >/dev/null 2>&1 || true
}

backup_restore() {
    require_root backup restore || return 1
    local id="${1:-}"
    local confirmation="${2:-prompt}"
    backup_validate_id "$id" || {
        die "Snapshot не найден или повреждён: ${id:-<пусто>}"
        return 1
    }
    if ! is_test_mode && [[ "$confirmation" != "confirmed" ]]; then
        confirm "Восстановить snapshot $id?" "N" || {
            log_info "Restore отменён"
            return 0
        }
    fi

    local safety_id restore_ufw_state safety_ufw_state restoring_initial="false"
    [[ "$id" == "$INITIAL_BACKUP_ID" ]] && restoring_initial="true"
    restore_ufw_state="$(backup_ufw_state "$id")"
    if [[ "$restoring_initial" == "true" && "$restore_ufw_state" == "preserve" ]]; then
        die "Initial snapshot старого формата не содержит состояния UFW; rollback остановлен"
        return 1
    fi
    backup_create "pre-restore-${id}" "$id" || return 1
    safety_id="$LAST_BACKUP_ID"
    safety_ufw_state="$(backup_ufw_state "$safety_id")"
    log_info "Восстановление файлов из $id"

    if ! backup_restore_files "$id" ||
        ! validate_restored_system_files ||
        ! backup_apply_ufw_state "$restore_ufw_state"; then
        log_error "Restore не прошёл проверку; возвращаю состояние $safety_id"
        backup_restore_files "$safety_id" || true
        backup_apply_ufw_state "$safety_ufw_state" || true
        reload_managed_services || true
        return 1
    fi

    reload_managed_services || {
        log_error "Службы не приняли восстановленную конфигурацию; выполняю safety rollback"
        backup_restore_files "$safety_id" || true
        backup_apply_ufw_state "$safety_ufw_state" || true
        reload_managed_services || true
        return 1
    }

    if [[ -r "$BACKUP_DIR/$id/manager-state.conf" ]]; then
        cp -a "$BACKUP_DIR/$id/manager-state.conf" "$STATE_FILE"
        load_state
        if [[ "$restoring_initial" == "true" && -z "$INITIAL_BACKUP_ID" ]]; then
            INITIAL_BACKUP_ID="$id"
            [[ -n "$LAST_BACKUP_ID" ]] || LAST_BACKUP_ID="$id"
            save_state
        fi
    fi
    backup_prune
    if [[ -n "$LAST_BACKUP_ID" && ! -d "$BACKUP_DIR/$LAST_BACKUP_ID" ]]; then
        local newest_id=""
        while IFS= read -r newest_id; do
            break
        done < <(backup_ids_newest_first)
        LAST_BACKUP_ID="$newest_id"
        save_state
    fi
    log_success "Snapshot $id восстановлен"
}

rollback_initial() {
    require_root rollback || return 1
    [[ -n "$INITIAL_BACKUP_ID" ]] || {
        die "Начальный snapshot отсутствует"
        return 1
    }

    log_warn "Будут восстановлены управляемые системные файлы."
    log_warn "Пользователь $ADMIN_USER и его authorized_keys удалены НЕ будут."
    confirm "Введите подтверждение отката" "N" || {
        log_info "Откат отменён"
        return 0
    }
    backup_restore "$INITIAL_BACKUP_ID" confirmed
}
