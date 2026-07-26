#!/usr/bin/env bash

manager_update() {
    require_root update || return 1
    [[ -n "$RELEASE_REPO" ]] || {
        die "Release repository не настроен."
        log_info "После публикации задайте owner/repo в $CONFIG_FILE"
        return 1
    }
    validate_repo_slug "$RELEASE_REPO" || {
        die "Некорректный RELEASE_REPO: $RELEASE_REPO"
        return 1
    }

    local temp_dir archive checksum_url archive_url expected actual
    temp_dir="$(mktemp -d)"
    archive="$temp_dir/vpssetup.tar.gz"
    archive_url="https://github.com/${RELEASE_REPO}/releases/latest/download/vpssetup.tar.gz"
    checksum_url="${archive_url}.sha256"

    log_info "Скачивание latest release из $RELEASE_REPO"
    curl -fsSL --retry 4 --retry-all-errors --max-time 90 \
        "$archive_url" -o "$archive" || {
        rm -rf "$temp_dir"
        return 1
    }
    expected="$(curl -fsSL --retry 4 --retry-all-errors --max-time 45 "$checksum_url" |
        awk '{print $1; exit}')" || {
        rm -rf "$temp_dir"
        return 1
    }
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && "$actual" == "$expected" ]] || {
        rm -rf "$temp_dir"
        die "SHA-256 release archive не совпал"
        return 1
    }
    tar_archive_has_safe_paths "$archive" || {
        rm -rf "$temp_dir"
        die "Release archive содержит небезопасные пути"
        return 1
    }

    mkdir -p "$temp_dir/unpacked"
    tar -xzf "$archive" -C "$temp_dir/unpacked" || {
        rm -rf "$temp_dir"
        return 1
    }
    local source
    source="$(find "$temp_dir/unpacked" -type f -name vpssetup.sh -printf '%h\n' | head -n1)"
    [[ -n "$source" && -d "$source/lib" ]] || {
        rm -rf "$temp_dir"
        die "Release archive не содержит vpssetup.sh и lib/"
        return 1
    }

    local script
    while IFS= read -r script; do
        bash -n "$script" || {
            rm -rf "$temp_dir"
            die "Синтаксическая ошибка в release: $script"
            return 1
        }
    done < <(find "$source" -type f -name '*.sh')

    local code_backup
    code_backup="$STATE_DIR/code-backup-$(date -u '+%Y%m%dT%H%M%SZ')"
    cp -a "$INSTALL_DIR" "$code_backup" || {
        rm -rf "$temp_dir"
        return 1
    }

    if ! cp -a "$source/." "$INSTALL_DIR/"; then
        rm -rf "$INSTALL_DIR"
        mv "$code_backup" "$INSTALL_DIR"
        rm -rf "$temp_dir"
        die "Update не применён; восстановлена предыдущая версия"
        return 1
    fi
    chmod +x "$INSTALL_DIR/vpssetup.sh"
    ln -sfn "$INSTALL_DIR/vpssetup.sh" "$(system_path /usr/local/bin/vpssetup)"
    rm -rf "$temp_dir"
    log_success "VPSSetup обновлён; предыдущий код: $code_backup"
}
