#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/aorus-bridge"
fake_bridge='0000:ff:ff.f'

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "$expected" == "$actual" ]] || {
        printf '%s: expected %s, got %s\n' "$message" "$expected" "$actual" >&2
        return 1
    }
}

assert_contains() {
    local needle="$1"
    local file="$2"

    grep -Fq -- "$needle" "$file" || {
        printf 'expected to find %s in %s\n' "$needle" "$file" >&2
        return 1
    }
}

assert_empty_file() {
    local file="$1"

    [[ ! -s "$file" ]] || {
        printf 'expected empty file: %s\n' "$file" >&2
        return 1
    }
}

run_script_capture() {
    local stdout_file="$1"
    local stderr_file="$2"
    local status
    shift 2

    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        return 0
    else
        status=$?
    fi

    return "$status"
}

write_fake_setpci() {
    local path="$1"
    local mode="$2"

    case "$mode" in
        fail-first-write)
            cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${3:-}" in
    CAP_EXP+0x30.W)
        printf '0010\n'
        ;;
    CAP_EXP+0x30.W=*)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
            ;;
        fail-status-read)
            cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${3:-}" in
    CAP_EXP+0x30.W)
        printf '0033\n'
        ;;
    CAP_EXP+0x12.W)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
            ;;
        restore-ok)
            cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${3:-}" in
    CAP_EXP+0x30.W)
        printf '0033\n'
        ;;
    CAP_EXP+0x30.W=0013)
        ;;
    *)
        exit 1
        ;;
esac
EOF
            ;;
        *)
            printf 'unknown fake setpci mode: %s\n' "$mode" >&2
            return 1
            ;;
    esac

    chmod +x "$path"
}

create_fake_detect_sysfs() {
    local root="$1"
    local bridge_bdf="$2"
    local gpu_bdf="$3"
    local gpu_dir="${root}/tree/${bridge_bdf}/${gpu_bdf}"

    mkdir -p "$gpu_dir" "$root"
    printf '0x10de\n' >"${gpu_dir}/vendor"
    printf '0x2b85\n' >"${gpu_dir}/device"
    printf '0x030000\n' >"${gpu_dir}/class"
    ln -s "$gpu_dir" "${root}/gpu0"
}

test_apply_fails_when_lnkctl2_write_fails() {
    local tmpdir stdout_file stderr_file fake_setpci status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_setpci="${tmpdir}/setpci"
    write_fake_setpci "$fake_setpci" fail-first-write

    if run_script_capture "$stdout_file" "$stderr_file" \
      env SETPCI_BIN="$fake_setpci" BRIDGE="$fake_bridge" FORCE_TB=1 LOCKDOWN_PATH=/dev/null \
      bash "$script" apply; then
        printf 'expected apply to fail when the LnkCtl2 write fails\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '2' "$status" 'apply should exit 2 on write failure'
    assert_contains 'could not write LnkCtl2=' "$stderr_file"
}

test_status_fails_when_lnksta_read_fails() {
    local tmpdir stdout_file stderr_file fake_setpci status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_setpci="${tmpdir}/setpci"
    write_fake_setpci "$fake_setpci" fail-status-read

    if run_script_capture "$stdout_file" "$stderr_file" \
      env SETPCI_BIN="$fake_setpci" BRIDGE="$fake_bridge" FORCE_TB=1 LOCKDOWN_PATH=/dev/null \
      bash "$script" status; then
        printf 'expected status to fail when LnkSta cannot be read\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '2' "$status" 'status should exit 2 on read failure'
    assert_contains "could not read LnkSta from ${fake_bridge}" "$stderr_file"
}

test_restore_reports_target_is_left_unchanged() {
    local tmpdir stdout_file stderr_file fake_setpci
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_setpci="${tmpdir}/setpci"
    write_fake_setpci "$fake_setpci" restore-ok

    if ! run_script_capture "$stdout_file" "$stderr_file" \
      env SETPCI_BIN="$fake_setpci" BRIDGE="$fake_bridge" FORCE_TB=1 LOCKDOWN_PATH=/dev/null \
      bash "$script" restore; then
        printf 'expected restore to succeed with fake setpci\n' >&2
        printf 'stderr:\n' >&2
        sed -n '1,120p' "$stderr_file" >&2
        return 1
    fi

    assert_contains 'Target Link Speed left unchanged' "$stdout_file"
}

test_detect_prints_parent_bridge_only() {
    local tmpdir stdout_file stderr_file fake_sysfs
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_sysfs="${tmpdir}/pci-devices"
    create_fake_detect_sysfs "$fake_sysfs" '0000:03:00.0' '0000:04:00.0'

    if ! run_script_capture "$stdout_file" "$stderr_file" \
      env PCI_SYSFS_ROOT="$fake_sysfs" \
      bash "$script" detect; then
        printf 'expected detect to succeed with fake sysfs\n' >&2
        return 1
    fi

    assert_equals '0000:03:00.0' "$(tr -d '\n' <"$stdout_file")" 'detect should print parent bridge only'
    assert_empty_file "$stderr_file"
}

test_detect_returns_1_with_no_output_when_missing() {
    local tmpdir stdout_file stderr_file fake_sysfs status
    tmpdir="$(mktemp -d)"
    trap "rm -rf -- '$tmpdir'" RETURN
    stdout_file="${tmpdir}/stdout"
    stderr_file="${tmpdir}/stderr"
    fake_sysfs="${tmpdir}/pci-devices"
    mkdir -p "$fake_sysfs"

    if run_script_capture "$stdout_file" "$stderr_file" \
      env PCI_SYSFS_ROOT="$fake_sysfs" \
      bash "$script" detect; then
        printf 'expected detect to fail when no GPU is present\n' >&2
        return 1
    else
        status=$?
    fi

    assert_equals '1' "$status" 'detect should exit 1 when no bridge is found'
    assert_empty_file "$stdout_file"
    assert_empty_file "$stderr_file"
}

main() {
    test_apply_fails_when_lnkctl2_write_fails
    test_status_fails_when_lnksta_read_fails
    test_restore_reports_target_is_left_unchanged
    test_detect_prints_parent_bridge_only
    test_detect_returns_1_with_no_output_when_missing
}

main "$@"
