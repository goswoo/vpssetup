#!/usr/bin/env bash

manager_update() {
    require_root update || return 1

    local temp_dir installer base_url installer_url metadata commit
    temp_dir="$(mktemp -d)"
    installer="$temp_dir/install.sh"
    base_url="${VPSSETUP_RAW_BASE_URL:-}"
    if [[ -z "$base_url" ]]; then
        metadata="$temp_dir/github-commit.json"
        download_url \
            "https://api.github.com/repos/goswoo/vpssetup/commits/main?v=$(date +%s)-${RANDOM}" \
            "$metadata" || {
            rm -rf "$temp_dir"
            die "Не удалось определить актуальный commit"
            return 1
        }
        commit="$(
            sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-fA-F]\{40\}\)",*$/\1/p' \
                "$metadata" |
                head -n1
        )"
        [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || {
            rm -rf "$temp_dir"
            die "GitHub вернул некорректный commit"
            return 1
        }
        base_url="https://raw.githubusercontent.com/goswoo/vpssetup/${commit}"
    fi
    installer_url="$base_url/install.sh"

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
    VPSSETUP_RAW_BASE_URL="$base_url" bash "$installer" --no-setup || {
        rm -rf "$temp_dir"
        return 1
    }
    rm -rf "$temp_dir"
    log_success "VPSSetup обновлён"
}
