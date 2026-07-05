#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/uninstall.sh"

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

assert_file_exists() {
  local path="$1"

  [[ -e "$path" ]] || {
    printf 'expected file to exist: %s\n' "$path" >&2
    return 1
  }
}

assert_not_exists() {
  local path="$1"

  [[ ! -e "$path" ]] || {
    printf 'expected file to be absent: %s\n' "$path" >&2
    return 1
  }
}

assert_file_content() {
  local expected="$1"
  local file="$2"
  local actual

  actual="$(<"$file")"
  [[ "$expected" == "$actual" ]] || {
    printf 'unexpected contents for %s\nexpected:\n%s\nactual:\n%s\n' "$file" "$expected" "$actual" >&2
    return 1
  }
}

write_fake_command() {
  local path="$1"
  local log_file="$2"
  local body="$3"
  local command_name

  command_name="$(basename "$path")"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$command_name" "\$*" >>"$log_file"
$body
EOF
  chmod +x "$path"
}

write_fake_bridge_helper() {
  local path="$1"
  local log_file="$2"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'aorus-bridge %s\n' "\$*" >>"$log_file"
exit 0
EOF
  chmod +x "$path"
}

run_uninstall() {
  local root="$1"

  run_uninstall_with_args "$root"
}

run_uninstall_with_args() {
  local root="$1"
  shift

  env \
    AORUS_SETUP_ALLOW_NON_ROOT=1 \
    UDEVADM_BIN=true \
    DKMS_BIN=false \
    DKMS_SRC_DIR="${root}/usr/src" \
    PATH="${root}/bin:${PATH}" \
    ETC_ROOT="${root}/etc" \
    MODPROBE_DIR="${root}/etc/modprobe.d" \
    SYSTEMD_ROOT="${root}/etc/systemd/system" \
    USR_LOCAL_BIN_DIR="${root}/usr/local/bin" \
    MKINITCPIO_CONF_PATH="${root}/etc/mkinitcpio.conf" \
    GRUB_DEFAULT_PATH="${root}/etc/default/grub" \
    GRUB_CFG_PATH="${root}/boot/grub/grub.cfg" \
    bash "$script" "$@"
}

snapshot_host_tree() {
  local root="$1"

  tar --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -cf - \
    -C "$root" \
    etc usr boot | sha256sum | cut -d' ' -f1
}

run_uninstall_capture() {
  local root="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  if run_uninstall_with_args "$root" "$@" >"$stdout_file" 2>"$stderr_file"; then
    return 0
  fi
  return 1
}

prepare_fake_root() {
  local root="$1"
  local log_file="$2"

  mkdir -p "${root}/etc/modprobe.d" "${root}/etc/default" \
    "${root}/usr/local/bin" "${root}/boot/grub" "${root}/bin" \
    "${root}/etc/systemd/system/nvidia-persistenced.service.d"

  write_fake_command "${root}/bin/mkinitcpio" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/grub-mkconfig" "$log_file" 'while [[ $# -gt 0 ]]; do if [[ "$1" == "-o" ]]; then shift; : >"$1"; fi; shift; done'
  write_fake_command "${root}/bin/modprobe" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/systemctl" "$log_file" 'exit 0'
}

seed_installed_state() {
  local root="$1"

  cat >"${root}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF
  cat >"${root}/etc/mkinitcpio.conf.aorus.00" <<'EOF'
MODULES=(legacy)
BINARIES=()
FILES=()
HOOKS=(base)
EOF
  cat >"${root}/etc/mkinitcpio.conf.aorus.02" <<'EOF'
MODULES=(restored newest)
BINARIES=()
FILES=()
HOOKS=(base fsck)
EOF

  cat >"${root}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
GRUB_CMDLINE_LINUX="iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
  cat >"${root}/etc/default/grub.aorus.01" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="audit=1"
EOF

  cat >"${root}/etc/modprobe.d/existing.conf" <<'EOF'
# aorus-disabled: options nvidia NVreg_Foo=1
# aorus-disabled: softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
  cat >"${root}/etc/modprobe.d/existing.conf.aorus.00" <<'EOF'
options nvidia NVreg_Foo=1
softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
  cat >"${root}/etc/modprobe.d/deleted.conf.aorus.00" <<'EOF'
options nvidia NVreg_RegistryDwords=PerfLevelSrc=0x2222
EOF

  printf 'installed helper\n' >"${root}/usr/local/bin/aorus-bridge"
  printf 'installed helper\n' >"${root}/usr/local/bin/aorus-modules"
  printf 'installed service\n' >"${root}/etc/systemd/system/aorus.service"
  printf 'installed dropin\n' >"${root}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
  printf 'installed blacklist\n' >"${root}/etc/modprobe.d/aorus.conf"
}

test_uninstall_attempts_runtime_rollback() {
  local tmpdir log_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"
  write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"

  run_uninstall "$tmpdir"

  assert_contains 'aorus-bridge restore' "$log_file"
  assert_contains 'modprobe -r nvidia_uvm' "$log_file"
  assert_contains 'modprobe -r nvidia_drm' "$log_file"
  assert_contains 'modprobe -r nvidia_modeset' "$log_file"
  assert_contains 'modprobe -r nvidia' "$log_file"
}

test_uninstall_reports_reboot_required_when_boot_artifacts_regenerated() {
  local tmpdir log_file stdout_file stderr_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"
  write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"

  if ! run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
    printf 'expected uninstall.sh to succeed for managed state\n' >&2
    return 1
  fi

  assert_contains 'uninstall complete; reboot required' "$stdout_file"
}

test_uninstall_restores_backups_removes_owned_artifacts_and_reloads_daemons() {
  local tmpdir log_file count
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"

  run_uninstall "$tmpdir"

  assert_file_content "$(
    cat <<'EOF'
MODULES=(restored newest)
BINARIES=()
FILES=()
HOOKS=(base fsck)
EOF
  )" "${tmpdir}/etc/mkinitcpio.conf"
  assert_file_content "$(
    cat <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="audit=1"
EOF
  )" "${tmpdir}/etc/default/grub"
  assert_file_content "$(
    cat <<'EOF'
options nvidia NVreg_Foo=1
softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF
  )" "${tmpdir}/etc/modprobe.d/existing.conf"
  assert_file_content "$(
    cat <<'EOF'
options nvidia NVreg_RegistryDwords=PerfLevelSrc=0x2222
EOF
  )" "${tmpdir}/etc/modprobe.d/deleted.conf"

  assert_not_exists "${tmpdir}/usr/local/bin/aorus-bridge"
  assert_not_exists "${tmpdir}/usr/local/bin/aorus-modules"
  assert_not_exists "${tmpdir}/etc/systemd/system/aorus.service"
  assert_not_exists "${tmpdir}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
  assert_not_exists "${tmpdir}/etc/modprobe.d/aorus.conf"

  assert_contains 'systemctl disable aorus.service' "$log_file"
  assert_contains 'systemctl daemon-reload' "$log_file"
  assert_contains 'mkinitcpio -P' "$log_file"
  assert_contains 'grub-mkconfig -o ' "$log_file"
}

test_uninstall_ignores_unmanaged_mkinitcpio_and_grub_without_backups() {
  local tmpdir log_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  cat >"${tmpdir}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=off"
GRUB_CMDLINE_LINUX="audit=1"
EOF

  run_uninstall "$tmpdir"
}

test_uninstall_fails_when_managed_modprobe_file_has_no_backup() {
  local tmpdir log_file stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  cat >"${tmpdir}/etc/modprobe.d/existing.conf" <<'EOF'
# aorus-disabled: options nvidia NVreg_Foo=1
options snd_hda_intel power_save=1
EOF

  if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
    printf 'expected uninstall.sh to fail when a managed modprobe file has no backup\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'uninstall should fail when no backup exists for managed modprobe files'
  assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_fails_when_canonical_managed_grub_has_no_backup() {
  local tmpdir log_file stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
  printf 'previous service backup\n' >"${tmpdir}/etc/systemd/system/aorus.service.aorus.00"

  if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
    printf 'expected uninstall.sh to fail when a canonical managed grub file has no backup\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'uninstall should fail when no backup exists for managed grub files'
  assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_dry_run_announces_restore_and_remove_actions_without_mutating_host() {
  local tmpdir log_file stdout_file stderr_file before after
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"
  write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"
  before="$(snapshot_host_tree "$tmpdir")"

  if ! run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file" --dry-run; then
    printf 'expected uninstall.sh --dry-run to succeed\n' >&2
    return 1
  fi

  after="$(snapshot_host_tree "$tmpdir")"
  assert_equals "$before" "$after" 'uninstall dry-run should not mutate the fake host tree'
  assert_file_content '' "$log_file"
  assert_contains '[dry-run] disabling aorus.service' "$stdout_file"
  assert_contains '[dry-run] restoring live bridge state' "$stdout_file"
  assert_contains '[dry-run] unloading nvidia_uvm' "$stdout_file"
  assert_contains "[dry-run] restoring ${tmpdir}/etc/mkinitcpio.conf" "$stdout_file"
  assert_contains "[dry-run] restoring ${tmpdir}/etc/default/grub" "$stdout_file"
  assert_contains "[dry-run] removing ${tmpdir}/usr/local/bin/aorus-modules" "$stdout_file"
  assert_contains '[dry-run] running mkinitcpio -P' "$stdout_file"
  assert_contains '[dry-run] reloading systemd manager' "$stdout_file"
  assert_contains 'uninstall complete; no reboot required' "$stdout_file"
}

test_uninstall_announces_each_file_mutation_and_non_file_action() {
  local tmpdir log_file stdout_file stderr_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"
  write_fake_bridge_helper "${tmpdir}/usr/local/bin/aorus-bridge" "$log_file"

  if ! run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file"; then
    printf 'expected uninstall.sh to succeed for announcement coverage\n' >&2
    return 1
  fi

  assert_contains 'disabling aorus.service' "$stdout_file"
  assert_contains 'restoring live bridge state' "$stdout_file"
  assert_contains 'unloading nvidia_uvm' "$stdout_file"
  assert_contains "restoring ${tmpdir}/etc/mkinitcpio.conf" "$stdout_file"
  assert_contains "restoring ${tmpdir}/etc/default/grub" "$stdout_file"
  assert_contains "restoring ${tmpdir}/etc/modprobe.d/existing.conf" "$stdout_file"
  assert_contains "restoring ${tmpdir}/etc/modprobe.d/deleted.conf" "$stdout_file"
  assert_contains "removing ${tmpdir}/usr/local/bin/aorus-bridge" "$stdout_file"
  assert_contains "removing ${tmpdir}/etc/systemd/system/aorus.service" "$stdout_file"
  assert_contains 'running mkinitcpio -P' "$stdout_file"
  assert_contains 'running grub-mkconfig -o ' "$stdout_file"
  assert_contains 'reloading systemd manager' "$stdout_file"
}

test_uninstall_dry_run_preserves_missing_backup_failure() {
  local tmpdir log_file stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  cat >"${tmpdir}/etc/modprobe.d/existing.conf" <<'EOF'
# aorus-disabled: options nvidia NVreg_Foo=1
options snd_hda_intel power_save=1
EOF

  if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file" --dry-run; then
    printf 'expected uninstall.sh --dry-run to fail when a managed backup is missing\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'uninstall dry-run should preserve missing-backup failures'
  assert_contains 'missing backup for managed file' "$stderr_file"
}

test_uninstall_rejects_unknown_args() {
  local tmpdir log_file stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"
  seed_installed_state "$tmpdir"

  if run_uninstall_capture "$tmpdir" "$stdout_file" "$stderr_file" --wat; then
    printf 'expected uninstall.sh to reject unknown arguments\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'uninstall should reject unknown arguments'
  assert_contains 'unknown argument: --wat' "$stderr_file"
}

test_uninstall_reports_its_own_root_requirement() {
  local tmpdir log_file stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"

  prepare_fake_root "$tmpdir" "$log_file"

  if env \
    PATH="${tmpdir}/bin:${PATH}" \
    ETC_ROOT="${tmpdir}/etc" \
    MODPROBE_DIR="${tmpdir}/etc/modprobe.d" \
    SYSTEMD_ROOT="${tmpdir}/etc/systemd/system" \
    USR_LOCAL_BIN_DIR="${tmpdir}/usr/local/bin" \
    MKINITCPIO_CONF_PATH="${tmpdir}/etc/mkinitcpio.conf" \
    GRUB_DEFAULT_PATH="${tmpdir}/etc/default/grub" \
    GRUB_CFG_PATH="${tmpdir}/boot/grub/grub.cfg" \
    bash "$script" >"$stdout_file" 2>"$stderr_file"; then
    printf 'expected uninstall.sh to require root when override is absent\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'uninstall should fail before running as non-root'
  assert_contains 'uninstall.sh must be run as root' "$stderr_file"
}

main() {
  test_uninstall_restores_backups_removes_owned_artifacts_and_reloads_daemons
  test_uninstall_attempts_runtime_rollback
  test_uninstall_reports_reboot_required_when_boot_artifacts_regenerated
  test_uninstall_ignores_unmanaged_mkinitcpio_and_grub_without_backups
  test_uninstall_fails_when_managed_modprobe_file_has_no_backup
  test_uninstall_fails_when_canonical_managed_grub_has_no_backup
  test_uninstall_dry_run_announces_restore_and_remove_actions_without_mutating_host
  test_uninstall_announces_each_file_mutation_and_non_file_action
  test_uninstall_dry_run_preserves_missing_backup_failure
  test_uninstall_rejects_unknown_args
  test_uninstall_reports_its_own_root_requirement
}

main "$@"
