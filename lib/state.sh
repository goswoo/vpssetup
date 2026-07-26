#!/usr/bin/env bash

STATE_SCHEMA=1
PHASE="unconfigured"
ADMIN_USER="deploy"
SSH_OLD_PORT="22"
SSH_PORT="22"
SSH_CONFIRMED="false"
SSH_SERVICE_MODE="auto"
UFW_WAS_ACTIVE="unknown"
UFW_OLD_RULE_OWNED="false"
UFW_NEW_RULE_OWNED="false"
UFW_HTTPS_RULE_OWNED="false"
UFW_HTTP_RULE_OWNED="false"
INITIAL_BACKUP_ID=""
LAST_BACKUP_ID=""
REBOOT_REQUIRED="false"
REBOOT_BOOT_ID=""
MANAGED_SWAPFILE=""
IPV6_METHOD=""
IPV6_UFW_PREVIOUS=""
SUDO_TIMEOUT_ENABLED="false"
DOCKER_GROUP_ADDED="false"

state_allowed_key() {
    case "$1" in
        STATE_SCHEMA|PHASE|ADMIN_USER|SSH_OLD_PORT|SSH_PORT|SSH_CONFIRMED|\
        SSH_SERVICE_MODE|UFW_WAS_ACTIVE|UFW_OLD_RULE_OWNED|UFW_NEW_RULE_OWNED|\
        UFW_HTTPS_RULE_OWNED|UFW_HTTP_RULE_OWNED|INITIAL_BACKUP_ID|LAST_BACKUP_ID|REBOOT_REQUIRED|\
        REBOOT_BOOT_ID|\
        MANAGED_SWAPFILE|IPV6_METHOD|IPV6_UFW_PREVIOUS|\
        SUDO_TIMEOUT_ENABLED|DOCKER_GROUP_ADDED)
            return 0
            ;;
    esac
    return 1
}

load_state() {
    [[ -r "$STATE_FILE" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\'([^\']*)\'$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        state_allowed_key "$key" || continue
        printf -v "$key" '%s' "$value"
    done <"$STATE_FILE"

    validate_username "$ADMIN_USER" || ADMIN_USER="deploy"
    validate_port "$SSH_OLD_PORT" || SSH_OLD_PORT="22"
    validate_port "$SSH_PORT" || SSH_PORT="22"
    [[ -z "$REBOOT_BOOT_ID" ||
        "$REBOOT_BOOT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || REBOOT_BOOT_ID=""
    [[ -z "$MANAGED_SWAPFILE" || "$MANAGED_SWAPFILE" == "/swapfile" ]] ||
        MANAGED_SWAPFILE=""
    case "$IPV6_METHOD" in
        ""|sysctl|grub) ;;
        *) IPV6_METHOD="" ;;
    esac
    case "$IPV6_UFW_PREVIOUS" in
        ""|yes|no|YES|NO|unset|missing) ;;
        *) IPV6_UFW_PREVIOUS="" ;;
    esac
    case "$SSH_SERVICE_MODE" in
        auto|socket|service) ;;
        *) SSH_SERVICE_MODE="auto" ;;
    esac
    local boolean_key
    for boolean_key in \
        SSH_CONFIRMED UFW_OLD_RULE_OWNED UFW_NEW_RULE_OWNED \
        UFW_HTTPS_RULE_OWNED UFW_HTTP_RULE_OWNED REBOOT_REQUIRED \
        SUDO_TIMEOUT_ENABLED DOCKER_GROUP_ADDED; do
        [[ "${!boolean_key}" == "true" ]] ||
            printf -v "$boolean_key" '%s' "false"
    done
    case "$PHASE" in
        unconfigured|ssh_pending|configured) ;;
        *) PHASE="unconfigured" ;;
    esac
}

save_state() {
    local content
    content="# VPSSetup state. Managed by vpssetup; do not edit while it is running.
STATE_SCHEMA='${STATE_SCHEMA}'
PHASE='${PHASE}'
ADMIN_USER='${ADMIN_USER}'
SSH_OLD_PORT='${SSH_OLD_PORT}'
SSH_PORT='${SSH_PORT}'
SSH_CONFIRMED='${SSH_CONFIRMED}'
SSH_SERVICE_MODE='${SSH_SERVICE_MODE}'
UFW_WAS_ACTIVE='${UFW_WAS_ACTIVE}'
UFW_OLD_RULE_OWNED='${UFW_OLD_RULE_OWNED}'
UFW_NEW_RULE_OWNED='${UFW_NEW_RULE_OWNED}'
UFW_HTTPS_RULE_OWNED='${UFW_HTTPS_RULE_OWNED}'
UFW_HTTP_RULE_OWNED='${UFW_HTTP_RULE_OWNED}'
INITIAL_BACKUP_ID='${INITIAL_BACKUP_ID}'
LAST_BACKUP_ID='${LAST_BACKUP_ID}'
REBOOT_REQUIRED='${REBOOT_REQUIRED}'
REBOOT_BOOT_ID='${REBOOT_BOOT_ID}'
MANAGED_SWAPFILE='${MANAGED_SWAPFILE}'
IPV6_METHOD='${IPV6_METHOD}'
IPV6_UFW_PREVIOUS='${IPV6_UFW_PREVIOUS}'
SUDO_TIMEOUT_ENABLED='${SUDO_TIMEOUT_ENABLED}'
DOCKER_GROUP_ADDED='${DOCKER_GROUP_ADDED}'
"
    atomic_write "$STATE_FILE" 600 "$content"
}
