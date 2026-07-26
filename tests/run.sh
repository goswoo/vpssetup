#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export VPSSETUP_ROOT="$TEST_ROOT"
export VPSSETUP_TEST_MODE=1
export VPSSETUP_INSTALL_DIR="$PROJECT_DIR"
export NO_COLOR=1

pass_count=0

pass() {
    printf 'ok %d - %s\n' "$((++pass_count))" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
    local file="$1"
    local value="$2"
    grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

assert_not_contains() {
    local file="$1"
    local value="$2"
    ! grep -Fq -- "$value" "$file" || fail "$file unexpectedly contains: $value"
}

run_vpssetup() {
    bash "$PROJECT_DIR/vpssetup.sh" "$@"
}

numbered_rules="$(
    printf '[ 1] 22/tcp ALLOW IN Anywhere # vpssetup:ssh-stage-old\n'
    printf '[12] 22/tcp (v6) ALLOW IN Anywhere (v6) # vpssetup:ssh-stage-old\n'
    printf '[ 3] 443/tcp ALLOW IN Anywhere # vpssetup:https\n'
)"
parsed_rules="$(
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/firewall.sh"
    printf '%s\n' "$numbered_rules" |
        ufw_rule_numbers_for_comment "vpssetup:ssh-stage-old"
)"
[[ "$parsed_rules" == $'12\n1' ]] || fail "UFW numbered rule parser"
parsed_rule="$(
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/lib/firewall.sh"
    printf '%s\n' "$numbered_rules" |
        ufw_rule_numbers_for_comment "vpssetup:ssh-stage-old" 22
)"
[[ "$parsed_rule" == $'12\n1' ]] || fail "UFW numbered port filter"
pass "UFW numbered rule parser"

INSTALL_ROOT="$(mktemp -d)"
mkdir -p "$INSTALL_ROOT/etc"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$INSTALL_ROOT/etc/os-release"
VPSSETUP_ROOT="$INSTALL_ROOT" VPSSETUP_TEST_MODE=1 \
    bash "$PROJECT_DIR/install.sh" --no-setup >/dev/null
assert_file "$INSTALL_ROOT/opt/vpssetup/vpssetup.sh"
[[ -L "$INSTALL_ROOT/usr/local/bin/vpssetup" ]] || fail "installer symlink"
VPSSETUP_ROOT="$INSTALL_ROOT" VPSSETUP_TEST_MODE=1 \
    "$INSTALL_ROOT/usr/local/bin/vpssetup" version | grep -q 'v0.1.0' ||
    fail "installed symlink execution"
rm -rf "$INSTALL_ROOT"
pass "local installer and symlink execution"

REMOTE_INSTALL_ROOT="$(mktemp -d)"
REMOTE_INSTALLER_DIR="$(mktemp -d)"
mkdir -p "$REMOTE_INSTALL_ROOT/etc"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$REMOTE_INSTALL_ROOT/etc/os-release"
cp "$PROJECT_DIR/install.sh" "$REMOTE_INSTALLER_DIR/install.sh"
VPSSETUP_ROOT="$REMOTE_INSTALL_ROOT" VPSSETUP_TEST_MODE=1 \
    VPSSETUP_RAW_BASE_URL="file://$PROJECT_DIR" \
    bash "$REMOTE_INSTALLER_DIR/install.sh" --no-setup >/dev/null
assert_file "$REMOTE_INSTALL_ROOT/opt/vpssetup/vpssetup.sh"
assert_file "$REMOTE_INSTALL_ROOT/opt/vpssetup/lib/manager.sh"
VPSSETUP_ROOT="$REMOTE_INSTALL_ROOT" VPSSETUP_TEST_MODE=1 \
    VPSSETUP_RAW_BASE_URL="file://$PROJECT_DIR" \
    "$REMOTE_INSTALL_ROOT/usr/local/bin/vpssetup" update >/dev/null
assert_file "$REMOTE_INSTALL_ROOT/opt"/vpssetup.previous.*/vpssetup.sh
rm -rf "$REMOTE_INSTALL_ROOT" "$REMOTE_INSTALLER_DIR"
pass "remote-style install and update download source files"

WIZARD_ROOT="$(mktemp -d)"
mkdir -p \
    "$WIZARD_ROOT/etc/ssh/sshd_config.d" \
    "$WIZARD_ROOT/etc/ufw" \
    "$WIZARD_ROOT/etc/default"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$WIZARD_ROOT/etc/os-release"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' \
    >"$WIZARD_ROOT/etc/ssh/sshd_config"
printf 'IPV6=yes\n' >"$WIZARD_ROOT/etc/default/ufw"
printf '/dev/root / ext4 defaults 0 1\n' >"$WIZARD_ROOT/etc/fstab"
cat >"$WIZARD_ROOT/etc/ufw/before.rules" <<'EOF'
*filter
:ufw-before-input - [0:0]
-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT
COMMIT
EOF
printf 'y\n\n54222\n\n\n\n\n\nssh-ed25519 AAAATEST wizard@test\n' |
    VPSSETUP_ROOT="$WIZARD_ROOT" VPSSETUP_TEST_MODE=1 \
        VPSSETUP_INSTALL_DIR="$PROJECT_DIR" NO_COLOR=1 \
        bash "$PROJECT_DIR/vpssetup.sh" setup >"$WIZARD_ROOT/wizard.out" 2>&1
assert_contains "$WIZARD_ROOT/wizard.out" 'ssh-keygen -t ed25519'
assert_contains "$WIZARD_ROOT/wizard.out" 'Windows PowerShell'
assert_contains "$WIZARD_ROOT/wizard.out" 'Приватный файл id_ed25519'
assert_contains "$WIZARD_ROOT/var/lib/vpssetup/state.conf" "PHASE='ssh_pending'"
assert_file "$WIZARD_ROOT/home/deploy/.ssh/authorized_keys"
[[ -d "$WIZARD_ROOT/run/sshd" ]] || fail "sshd runtime directory"
VPSSETUP_ROOT="$WIZARD_ROOT" VPSSETUP_TEST_MODE=1 \
    VPSSETUP_INSTALL_DIR="$PROJECT_DIR" NO_COLOR=1 \
    bash "$PROJECT_DIR/vpssetup.sh" ssh confirm >/dev/null
assert_contains "$WIZARD_ROOT/var/lib/vpssetup/state.conf" "PHASE='configured'"
rm -rf "$WIZARD_ROOT"
pass "first-run wizard to SSH confirmation"

mkdir -p \
    "$TEST_ROOT/etc/ssh/sshd_config.d" \
    "$TEST_ROOT/etc/ufw" \
    "$TEST_ROOT/etc/default" \
    "$TEST_ROOT/etc/apt/apt.conf.d" \
    "$TEST_ROOT/etc/fail2ban/jail.d" \
    "$TEST_ROOT/root/.ssh" \
    "$TEST_ROOT/var/run"

printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$TEST_ROOT/etc/os-release"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' \
    >"$TEST_ROOT/etc/ssh/sshd_config"
printf 'IPV6=yes\n' >"$TEST_ROOT/etc/default/ufw"
printf '/dev/root / ext4 defaults 0 1\n' >"$TEST_ROOT/etc/fstab"
cat >"$TEST_ROOT/etc/ufw/before.rules" <<'EOF'
*filter
:ufw-before-input - [0:0]
-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT
COMMIT
EOF

[[ "$(run_vpssetup version)" == "VPSSetup v0.1.0" ]] || fail "version"
run_vpssetup help | grep -q 'ssh confirm' || fail "help"
pass "version and help"

if run_vpssetup ssh stage </dev/null >/dev/null 2>&1; then
    fail "SSH stage accepted missing port"
fi
pass "SSH port is required"

run_vpssetup backup create initial >/dev/null
assert_file "$TEST_ROOT/var/lib/vpssetup/state.conf"
assert_file "$TEST_ROOT/var/lib/vpssetup/backups/"*/manifest.tsv
pass "initial snapshot"

run_vpssetup backup create restore-point >/dev/null
restore_id="$(sed -n "s/^LAST_BACKUP_ID='\\([^']*\\)'$/\\1/p" \
    "$TEST_ROOT/var/lib/vpssetup/state.conf")"
printf 'IPV6=no\n' >"$TEST_ROOT/etc/default/ufw"
run_vpssetup backup restore "$restore_id" >/dev/null
assert_contains "$TEST_ROOT/etc/default/ufw" 'IPV6=yes'
pass "snapshot restore"

run_vpssetup module enable sudo-timeout >/dev/null
assert_contains "$TEST_ROOT/etc/sudoers.d/90-vpssetup-timeout" 'timestamp_timeout=60'
run_vpssetup module disable sudo-timeout >/dev/null
[[ ! -e "$TEST_ROOT/etc/sudoers.d/90-vpssetup-timeout" ]] || fail "sudo timeout disable"
pass "sudo timeout module"

run_vpssetup module enable swap 2G >/dev/null
assert_file "$TEST_ROOT/swapfile"
assert_contains "$TEST_ROOT/etc/fstab" '# vpssetup'
run_vpssetup module disable swap >/dev/null
[[ ! -e "$TEST_ROOT/swapfile" ]] || fail "swap disable"
assert_not_contains "$TEST_ROOT/etc/fstab" '# vpssetup'
pass "swap module lifecycle"

run_vpssetup module enable ipv6 sysctl >/dev/null
assert_file "$TEST_ROOT/etc/sysctl.d/99-vpssetup-disable-ipv6.conf"
assert_contains "$TEST_ROOT/etc/default/ufw" 'IPV6=no'
run_vpssetup module disable ipv6 >"$TEST_ROOT/ipv6-sysctl-disable.out"
assert_contains "$TEST_ROOT/etc/default/ufw" 'IPV6=yes'
assert_not_contains "$TEST_ROOT/ipv6-sysctl-disable.out" 'reboot'
pass "IPv6 module lifecycle"

run_vpssetup module enable ipv6 grub >/dev/null
assert_file "$TEST_ROOT/etc/default/grub.d/99-vpssetup-ipv6.cfg"
assert_contains "$TEST_ROOT/etc/default/grub.d/99-vpssetup-ipv6.cfg" 'ipv6.disable=1'
run_vpssetup module disable ipv6 >"$TEST_ROOT/ipv6-grub-disable.out"
assert_contains "$TEST_ROOT/ipv6-grub-disable.out" 'reboot'
pass "IPv6 GRUB module lifecycle"

run_vpssetup module enable docker-group >/dev/null
assert_contains "$TEST_ROOT/var/lib/vpssetup/state.conf" "DOCKER_GROUP_ADDED='true'"
run_vpssetup module disable docker-group >/dev/null
pass "Docker group module lifecycle"

run_vpssetup module enable icmp-rate-limit >/dev/null
assert_contains "$TEST_ROOT/etc/ufw/before.rules" '# vpssetup:icmp-rate-limit begin'
first_limit="$(grep -n -- '--limit 1/second' "$TEST_ROOT/etc/ufw/before.rules" | cut -d: -f1)"
commit_line="$(grep -n '^COMMIT$' "$TEST_ROOT/etc/ufw/before.rules" | cut -d: -f1)"
((first_limit < commit_line)) || fail "ICMP rule order"
if grep -qx -- '-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT' \
    "$TEST_ROOT/etc/ufw/before.rules"; then
    fail "unlimited ICMP accept remains"
fi
run_vpssetup module disable icmp-rate-limit >/dev/null
assert_not_contains "$TEST_ROOT/etc/ufw/before.rules" '# vpssetup:icmp-rate-limit begin'
pass "ICMP module placement and removal"

mkdir -p "$TEST_ROOT/var/lib/vpssetup-test"
touch "$TEST_ROOT/var/lib/vpssetup-test/ufw-active"
printf '22\tvpssetup:ssh-stage-old\n' \
    >"$TEST_ROOT/var/lib/vpssetup-test/ufw-rules"
printf '55222\tvpssetup:ssh-target\n443\tvpssetup:https\n' \
    >>"$TEST_ROOT/var/lib/vpssetup-test/ufw-rules"
run_vpssetup ssh stage 55222 >/dev/null
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 22'
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 55222'
assert_contains "$TEST_ROOT/etc/fail2ban/jail.d/10-vpssetup-sshd.local" 'port = 22,55222'
assert_contains "$TEST_ROOT/var/lib/vpssetup/state.conf" "PHASE='ssh_pending'"
assert_contains "$TEST_ROOT/var/lib/vpssetup/state.conf" "UFW_OLD_RULE_OWNED='true'"
pass "two-port SSH stage recovers existing UFW rules"

run_vpssetup ssh confirm >/dev/null
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'PermitRootLogin no'
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'PasswordAuthentication no'
assert_not_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 22'
assert_contains "$TEST_ROOT/etc/fail2ban/jail.d/10-vpssetup-sshd.local" 'port = 55222'
assert_contains "$TEST_ROOT/var/lib/vpssetup/state.conf" "PHASE='configured'"
pass "SSH confirmation hardening"

printf '22\tvpssetup:ssh-stage-old\n' \
    >>"$TEST_ROOT/var/lib/vpssetup-test/ufw-rules"
run_vpssetup ssh confirm >/dev/null
assert_not_contains "$TEST_ROOT/var/lib/vpssetup-test/ufw-rules" \
    'vpssetup:ssh-stage-old'
pass "repeated SSH confirmation cleans stale UFW rule"

run_vpssetup ssh stage 55222 >/dev/null
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'PermitRootLogin no'
assert_contains "$TEST_ROOT/var/lib/vpssetup/state.conf" "PHASE='configured'"
pass "same-port SSH restage is a no-op"

SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 55222' \
    run_vpssetup ssh stage 55223 >/dev/null
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 55222'
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 55223'
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'PasswordAuthentication no'
run_vpssetup ssh confirm >/dev/null
assert_not_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 55222'
assert_contains "$TEST_ROOT/etc/ssh/sshd_config.d/00-vpssetup.conf" 'Port 55223'
assert_not_contains "$TEST_ROOT/var/lib/vpssetup-test/ufw-rules" \
    $'55222\tvpssetup:ssh-target'
assert_contains "$TEST_ROOT/var/lib/vpssetup-test/ufw-rules" \
    $'55223\tvpssetup:ssh-target'
pass "port migration preserves hardening"

run_vpssetup status --json >"$TEST_ROOT/status.json"
python3 -m json.tool "$TEST_ROOT/status.json" >/dev/null
assert_contains "$TEST_ROOT/status.json" '"phase":"configured"'
pass "stable JSON status"

printf "EVIL='\$(touch %s/pwned)'\n" "$TEST_ROOT" \
    >>"$TEST_ROOT/var/lib/vpssetup/state.conf"
run_vpssetup status --json >/dev/null
[[ ! -e "$TEST_ROOT/pwned" ]] || fail "state parser executed content"
pass "state parser does not source content"

if run_vpssetup ssh stage 70000 >/dev/null 2>&1; then
    fail "invalid port accepted"
fi
pass "invalid port rejected"

printf 'APT::Periodic::Unattended-Upgrade "1";\n' \
    >"$TEST_ROOT/etc/apt/apt.conf.d/52vpssetup-auto-upgrades"
health_rc=0
run_vpssetup health >/dev/null || health_rc=$?
[[ "$health_rc" -eq 2 ]] || fail "health warning exit code"
pass "configured sandbox health with reboot warning"

rm -f "$TEST_ROOT/var/run/reboot-required"
printf "REBOOT_REQUIRED='true'\n" >>"$TEST_ROOT/var/lib/vpssetup/state.conf"
printf "REBOOT_BOOT_ID='00000000-0000-0000-0000-000000000000'\n" \
    >>"$TEST_ROOT/var/lib/vpssetup/state.conf"
run_vpssetup health >/dev/null || fail "stale reboot warning after boot"
pass "reboot warning clears after boot changes"

printf '1..%d\n' "$pass_count"
