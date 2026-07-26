#!/usr/bin/env bash

manager_update() {
    require_root update || return 1

    local temp_dir installer base_url installer_url
    temp_dir="$(mktemp -d)"
    installer="$temp_dir/install.sh"
    base_url="${VPSSETUP_RAW_BASE_URL:-https://raw.githubusercontent.com/goswoo/vpssetup/main}"
    installer_url="$base_url/install.sh"
    if [[ "$installer_url" == http://* || "$installer_url" == https://* ]]; then
        installer_url="${installer_url}?v=$(date +%s)-${RANDOM}"
    fi

    log_info "Скачивание обновления"
    download_url "$installer_url" "$installer" || {
        rm -rf "$temp_dir"
        die "Не удалось скачать install.sh"
        return 1
    }
    bash -n "$installer" || {
        rm -rf "$temp_dir"
        die "Синтаксическая ошибка в install.sh"
        return 1
    }
    bash "$installer" --no-setup || {
        rm -rf "$temp_dir"
        return 1
    }
    rm -rf "$temp_dir"
    log_success "VPSSetup обновлён"
}
