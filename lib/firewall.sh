#!/usr/bin/env bash

ufw_is_active() {
    if is_test_mode; then
        [[ -f "$(system_path /var/lib/vpssetup-test/ufw-active)" ]]
        return
    fi
    command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_has_exact_allow() {
    local port="$1"
    if is_test_mode; then
        local rules
        rules="$(system_path /var/lib/vpssetup-test/ufw-rules)"
        [[ -r "$rules" ]] && awk -F'\t' -v wanted="$port" \
            '$1 == wanted {found=1} END {exit(found ? 0 : 1)}' "$rules"
        return
    fi
    ufw status 2>/dev/null |
        awk -v wanted="${port}/tcp" '
            $1 == wanted && $2 == "ALLOW" {found=1}
            END {exit(found ? 0 : 1)}
        '
}

ufw_has_owned_rule() {
    local port="$1"
    local comment="$2"
    if is_test_mode; then
        local rules
        rules="$(system_path /var/lib/vpssetup-test/ufw-rules)"
        [[ -r "$rules" ]] && awk -F'\t' -v wanted="$port" -v marker="$comment" \
            '$1 == wanted && $2 == marker {found=1} END {exit(found ? 0 : 1)}' \
            "$rules"
        return
    fi
    ufw status 2>/dev/null |
        awk -v wanted="${port}/tcp" -v marker="$comment" '
            $1 == wanted && $2 == "ALLOW" && index($0, marker) {found=1}
            END {exit(found ? 0 : 1)}
        '
}

ufw_add_owned_rule() {
    local port="$1"
    local comment="$2"
    local state_variable="$3"

    if ufw_has_exact_allow "$port"; then
        if ufw_has_owned_rule "$port" "$comment"; then
            printf -v "$state_variable" '%s' "true"
            log_info "UFW уже содержит правило vpssetup для ${port}/tcp"
        else
            printf -v "$state_variable" '%s' "false"
            log_info "UFW уже разрешает ${port}/tcp; правило не присваивается vpssetup"
        fi
        return 0
    fi

    if is_test_mode; then
        mkdir -p "$(system_path /var/lib/vpssetup-test)"
        printf '%s\t%s\n' "$port" "$comment" \
            >>"$(system_path /var/lib/vpssetup-test/ufw-rules)"
    else
        ufw allow "${port}/tcp" comment "$comment" || return 1
    fi
    printf -v "$state_variable" '%s' "true"
}

ufw_delete_owned_rule() {
    local comment="$1"
    if is_test_mode; then
        local rules tmp
        rules="$(system_path /var/lib/vpssetup-test/ufw-rules)"
        [[ -f "$rules" ]] || return 0
        tmp="$(mktemp)"
        awk -F'\t' -v comment="$comment" '$2 != comment' "$rules" >"$tmp"
        mv "$tmp" "$rules"
        return 0
    fi

    local -a numbers=()
    local number
    while IFS= read -r number; do
        [[ "$number" =~ ^[0-9]+$ ]] && numbers+=("$number")
    done < <(
        ufw status numbered 2>/dev/null |
            awk -v marker="$comment" '
                index($0, marker) {
                    value=$1
                    gsub(/[^0-9]/, "", value)
                    print value
                }
            ' |
            sort -rn
    )

    for number in "${numbers[@]}"; do
        ufw --force delete "$number" || return 1
    done
}

ufw_prepare_stage() {
    require_root ssh stage || return 1
    local old_port="$1"
    local new_port="$2"
    command_exists ufw || is_test_mode || {
        die "ufw не установлен"
        return 1
    }

    if ufw_is_active; then
        UFW_WAS_ACTIVE="true"
    else
        UFW_WAS_ACTIVE="false"
        if is_test_mode; then
            mkdir -p "$(system_path /var/lib/vpssetup-test)"
        else
            ufw default deny incoming || return 1
            ufw default allow outgoing || return 1
        fi
    fi

    ufw_add_owned_rule "$old_port" "vpssetup:ssh-stage-old" UFW_OLD_RULE_OWNED || return 1
    if [[ "$new_port" == "$old_port" ]]; then
        UFW_NEW_RULE_OWNED="$UFW_OLD_RULE_OWNED"
    else
        ufw_add_owned_rule "$new_port" "vpssetup:ssh-target" UFW_NEW_RULE_OWNED || return 1
    fi
    ufw_add_owned_rule 443 "vpssetup:https" UFW_HTTPS_RULE_OWNED || return 1

    if [[ "$UFW_WAS_ACTIVE" == "false" ]]; then
        if is_test_mode; then
            touch "$(system_path /var/lib/vpssetup-test/ufw-active)"
        else
            ufw --force enable || return 1
        fi
    fi

    log_success "UFW сохраняет текущий SSH-порт и разрешает ${new_port}/tcp, 443/tcp"
}

ufw_finalize_ssh() {
    require_root ssh confirm || return 1
    if [[ "$SSH_OLD_PORT" != "$SSH_PORT" && "$UFW_OLD_RULE_OWNED" == "true" ]]; then
        ufw_delete_owned_rule "vpssetup:ssh-stage-old" || return 1
        UFW_OLD_RULE_OWNED="false"
    fi
    save_state
    log_success "Старое управляемое SSH-правило UFW удалено"
}

ufw_enable_optional_http() {
    require_root setup || return 1
    ufw_add_owned_rule 80 "vpssetup:http" UFW_HTTP_RULE_OWNED || return 1
    save_state
    log_success "UFW разрешает optional HTTP 80/tcp"
}

ufw_status_summary() {
    if ufw_is_active; then
        printf 'active'
    else
        printf 'inactive'
    fi
}
