#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo_root}/install.sh"
host_files="${repo_root}/host-files"

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

assert_not_contains() {
  local needle="$1"
  local file="$2"

  ! grep -Fq -- "$needle" "$file" || {
    printf 'expected %s to be absent from %s\n' "$needle" "$file" >&2
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

assert_same_file() {
  local expected="$1"
  local actual="$2"

  cmp -s "$expected" "$actual" || {
    printf 'expected %s to match %s\n' "$actual" "$expected" >&2
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

count_exact_lines() {
  local line="$1"
  local file="$2"

  rg --no-filename --include-zero -x -c -- "$line" "$file"
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

write_fake_bridge() {
  local path="$1"
  local bridge="$2"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "detect" ]]; then
    printf '%s\n' "$bridge"
    exit 0
fi
exit 1
EOF
  chmod +x "$path"
}

write_fake_bridge_script() {
  local path="$1"
  local body="$2"

  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$body
EOF
  chmod +x "$path"
}

run_setup() {
  local root="$1"
  local bridge_bin="$2"

  run_setup_with_args "$root" "$bridge_bin"
}

run_setup_with_args() {
  local root="$1"
  local bridge_bin="$2"
  shift 2

  env \
    AORUS_SETUP_ALLOW_NON_ROOT=1 \
    AORUS_CAP_MODULE=never \
    UDEVADM_BIN=true \
    PATH="${root}/bin:${PATH}" \
    ETC_ROOT="${root}/etc" \
    MODPROBE_DIR="${root}/etc/modprobe.d" \
    SYSTEMD_ROOT="${root}/etc/systemd/system" \
    USR_LOCAL_BIN_DIR="${root}/usr/local/bin" \
    MKINITCPIO_CONF_PATH="${root}/etc/mkinitcpio.conf" \
    GRUB_DEFAULT_PATH="${root}/etc/default/grub" \
    GRUB_CFG_PATH="${root}/boot/grub/grub.cfg" \
    HOST_FILES_DIR="$host_files" \
    AORUS_BRIDGE_BIN="$bridge_bin" \
    bash "$script" "$@"
}

run_setup_with_host_files() {
  local root="$1"
  local bridge_bin="$2"
  local host_files_root="$3"
  shift 3

  env \
    AORUS_SETUP_ALLOW_NON_ROOT=1 \
    AORUS_CAP_MODULE=never \
    UDEVADM_BIN=true \
    PATH="${root}/bin:${PATH}" \
    ETC_ROOT="${root}/etc" \
    MODPROBE_DIR="${root}/etc/modprobe.d" \
    SYSTEMD_ROOT="${root}/etc/systemd/system" \
    USR_LOCAL_BIN_DIR="${root}/usr/local/bin" \
    MKINITCPIO_CONF_PATH="${root}/etc/mkinitcpio.conf" \
    GRUB_DEFAULT_PATH="${root}/etc/default/grub" \
    GRUB_CFG_PATH="${root}/boot/grub/grub.cfg" \
    HOST_FILES_DIR="$host_files_root" \
    AORUS_BRIDGE_BIN="$bridge_bin" \
    bash "$script" "$@"
}

run_setup_capture() {
  local root="$1"
  local bridge_bin="$2"
  local stdout_file="$3"
  local stderr_file="$4"
  shift 4

  if run_setup_with_args "$root" "$bridge_bin" "$@" >"$stdout_file" 2>"$stderr_file"; then
    return 0
  fi
  return 1
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

prepare_fake_root() {
  local root="$1"
  local log_file="$2"

  mkdir -p "${root}/etc/modprobe.d" "${root}/etc/default" \
    "${root}/usr/local/bin" "${root}/boot/grub" "${root}/bin"

  cat >"${root}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci nvidia nvidia_uvm thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF

  cat >"${root}/etc/modprobe.d/existing.conf" <<'EOF'
options nvidia NVreg_Foo=1
softdep nvidia pre: something
options snd_hda_intel power_save=1
EOF

  cat >"${root}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash rd.driver.blacklist=nvidia modprobe.blacklist=nvidia iommu=pt"
GRUB_CMDLINE_LINUX="pcie_aspm.policy=powersave"
EOF

  write_fake_command "${root}/bin/mkinitcpio" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/grub-mkconfig" "$log_file" 'while [[ $# -gt 0 ]]; do if [[ "$1" == "-o" ]]; then shift; : >"$1"; fi; shift; done'
  write_fake_command "${root}/bin/systemctl" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/install" "$log_file" '/usr/bin/install "$@"'
}

test_backup_suffixes_increment_when_prior_backup_exists() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cp "${tmpdir}/etc/mkinitcpio.conf" "${tmpdir}/etc/mkinitcpio.conf.aorus.00"

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_exists "${tmpdir}/etc/mkinitcpio.conf.aorus.01"
}

test_mkinitcpio_and_modprobe_changes_trigger_single_mkinitcpio_run() {
  local tmpdir log_file bridge_bin count
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'

  run_setup "$tmpdir" "$bridge_bin"

  count="$(count_exact_lines 'mkinitcpio -P' "$log_file")"
  assert_equals '1' "$count" 'mkinitcpio should run once when boot config changes'
  assert_contains 'MODULES=(xhci_pci thunderbolt)' "${tmpdir}/etc/mkinitcpio.conf"
  assert_not_contains 'nvidia' "${tmpdir}/etc/mkinitcpio.conf"
}

test_mkinitcpio_handles_single_quoted_module_entries() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cat >"${tmpdir}/etc/mkinitcpio.conf" <<'EOF'
MODULES=('xhci_pci' 'nvidia' 'nvidia_uvm' thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF

  run_setup "$tmpdir" "$bridge_bin"

  assert_contains 'MODULES=(xhci_pci thunderbolt)' "${tmpdir}/etc/mkinitcpio.conf"
  assert_not_contains 'nvidia' "${tmpdir}/etc/mkinitcpio.conf"
}

test_modprobe_changes_alone_trigger_single_mkinitcpio_run() {
  local tmpdir log_file bridge_bin count
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cat >"${tmpdir}/etc/mkinitcpio.conf" <<'EOF'
MODULES=(xhci_pci thunderbolt)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)
EOF

  run_setup "$tmpdir" "$bridge_bin"

  count="$(count_exact_lines 'mkinitcpio -P' "$log_file")"
  assert_equals '1' "$count" 'mkinitcpio should run once when only modprobe policy changes'
  assert_contains '# aorus-disabled: options nvidia NVreg_Foo=1' "${tmpdir}/etc/modprobe.d/existing.conf"
  assert_contains '# aorus-disabled: softdep nvidia pre: something' "${tmpdir}/etc/modprobe.d/existing.conf"
  assert_contains 'options snd_hda_intel power_save=1' "${tmpdir}/etc/modprobe.d/existing.conf"
}

test_grub_is_canonicalized_with_detected_bridge() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_content "$(
    cat <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
  )" "${tmpdir}/etc/default/grub"
  assert_contains 'grub-mkconfig -o ' "$log_file"
}

test_grub_preserves_unrelated_kernel_args() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 modprobe.blacklist=nvidia iommu=pt"
GRUB_CMDLINE_LINUX="audit=1 pcie_aspm.policy=powersave"
EOF

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_content "$(
    cat <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"
GRUB_CMDLINE_LINUX="audit=1 iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
  )" "${tmpdir}/etc/default/grub"
}

test_grub_adds_missing_cmdline_directives() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="audit=1"
EOF

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_content "$(
    cat <<'EOF'
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="audit=1 iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
GRUB_CMDLINE_LINUX_DEFAULT=""
EOF
  )" "${tmpdir}/etc/default/grub"
}

test_grub_handles_single_quoted_cmdline_values() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT='quiet splash modprobe.blacklist=nvidia iommu=pt'
GRUB_CMDLINE_LINUX='audit=1 pcie_aspm.policy=powersave'
EOF

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_content "$(
    cat <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="audit=1 iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@0000:03:00.0"
EOF
  )" "${tmpdir}/etc/default/grub"
}

test_detect_failure_with_stderr_is_fatal() {
  local tmpdir log_file bridge_bin stdout_file stderr_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"

  prepare_fake_root "$tmpdir" "$log_file"
  cat >"${tmpdir}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pci=resource_alignment=35@0000:03:00.0"
GRUB_CMDLINE_LINUX="audit=1"
EOF
  write_fake_bridge_script "$bridge_bin" 'if [[ "${1:-}" == "detect" ]]; then printf "hardware probe failed\n" >&2; exit 1; fi; exit 1'

  if run_setup_capture "$tmpdir" "$bridge_bin" "$stdout_file" "$stderr_file"; then
    printf 'expected install.sh to fail when aorus-bridge detect reports stderr\n' >&2
    return 1
  fi

  assert_contains 'hardware probe failed' "$stderr_file"
}

test_missing_required_host_file_fails_install() {
  local tmpdir log_file bridge_bin stdout_file stderr_file host_files_copy status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  host_files_copy="${tmpdir}/host-files"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cp -R "$host_files" "$host_files_copy"
  rm -f -- "${host_files_copy}/etc/systemd/system/aorus.service"

  if run_setup_with_host_files "$tmpdir" "$bridge_bin" "$host_files_copy" >"$stdout_file" 2>"$stderr_file"; then
    printf 'expected install.sh to fail when a required host file is missing\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'install should fail when a required host file is missing'
  assert_contains 'aorus.service' "$stderr_file"
}

test_install_dry_run_announces_actions_without_mutating_host() {
  local tmpdir log_file bridge_bin stdout_file stderr_file before after
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  before="$(snapshot_host_tree "$tmpdir")"

  if ! run_setup_capture "$tmpdir" "$bridge_bin" "$stdout_file" "$stderr_file" --dry-run; then
    printf 'expected install.sh --dry-run to succeed\n' >&2
    return 1
  fi

  after="$(snapshot_host_tree "$tmpdir")"
  assert_equals "$before" "$after" 'install dry-run should not mutate the fake host tree'
  assert_file_content '' "$log_file"
  assert_contains "[dry-run] replacing ${tmpdir}/etc/mkinitcpio.conf" "$stdout_file"
  assert_contains "[dry-run] replacing ${tmpdir}/etc/modprobe.d/existing.conf" "$stdout_file"
  assert_contains "[dry-run] replacing ${tmpdir}/etc/default/grub" "$stdout_file"
  assert_contains "[dry-run] installing ${tmpdir}/usr/local/bin/aorus-bridge" "$stdout_file"
  assert_contains "[dry-run] installing ${tmpdir}/etc/systemd/system/aorus.service" "$stdout_file"
  assert_contains '[dry-run] running mkinitcpio -P' "$stdout_file"
  assert_contains 'install complete; no reboot required' "$stdout_file"
}

test_install_dry_run_does_not_create_missing_modprobe_dir() {
  local tmpdir log_file bridge_bin stdout_file stderr_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  rm -rf -- "${tmpdir}/etc/modprobe.d"

  if ! run_setup_capture "$tmpdir" "$bridge_bin" "$stdout_file" "$stderr_file" --dry-run; then
    printf 'expected install.sh --dry-run to succeed without modprobe.d present\n' >&2
    return 1
  fi

  [[ ! -d "${tmpdir}/etc/modprobe.d" ]] || {
    printf 'expected dry-run to leave modprobe.d absent\n' >&2
    return 1
  }
  assert_contains "[dry-run] creating directory ${tmpdir}/etc/modprobe.d" "$stdout_file"
  assert_file_content '' "$log_file"
}

test_install_announces_each_file_mutation_and_non_file_action() {
  local tmpdir log_file bridge_bin stdout_file stderr_file
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'

  if ! run_setup_capture "$tmpdir" "$bridge_bin" "$stdout_file" "$stderr_file"; then
    printf 'expected install.sh to succeed for announcement coverage\n' >&2
    return 1
  fi

  assert_contains "replacing ${tmpdir}/etc/mkinitcpio.conf" "$stdout_file"
  assert_contains "replacing ${tmpdir}/etc/modprobe.d/existing.conf" "$stdout_file"
  assert_contains "replacing ${tmpdir}/etc/default/grub" "$stdout_file"
  assert_contains "installing ${tmpdir}/usr/local/bin/aorus-bridge" "$stdout_file"
  assert_contains "installing ${tmpdir}/usr/local/bin/aorus-modules" "$stdout_file"
  assert_contains "installing ${tmpdir}/etc/modprobe.d/aorus.conf" "$stdout_file"
  assert_contains 'running mkinitcpio -P' "$stdout_file"
  assert_contains 'running grub-mkconfig -o ' "$stdout_file"
  assert_contains 'reloading systemd manager' "$stdout_file"
  assert_contains 'enabling aorus.service' "$stdout_file"
}

test_install_rejects_unknown_args() {
  local tmpdir log_file bridge_bin stdout_file stderr_file status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'

  if run_setup_capture "$tmpdir" "$bridge_bin" "$stdout_file" "$stderr_file" --wat; then
    printf 'expected install.sh to reject unknown arguments\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'install should reject unknown arguments'
  assert_contains 'unknown argument: --wat' "$stderr_file"
}

test_install_dry_run_fails_when_required_host_file_is_missing() {
  local tmpdir log_file bridge_bin stdout_file stderr_file host_files_copy status
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  stdout_file="${tmpdir}/stdout.log"
  stderr_file="${tmpdir}/stderr.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"
  host_files_copy="${tmpdir}/host-files"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'
  cp -R "$host_files" "$host_files_copy"
  rm -f -- "${host_files_copy}/etc/systemd/system/aorus.service"

  if run_setup_with_host_files "$tmpdir" "$bridge_bin" "$host_files_copy" --dry-run >"$stdout_file" 2>"$stderr_file"; then
    printf 'expected install.sh --dry-run to fail when a required host file is missing\n' >&2
    return 1
  else
    status=$?
  fi

  assert_equals '1' "$status" 'install dry-run should fail when a required host file is missing'
  assert_contains 'aorus.service' "$stderr_file"
  assert_file_content '' "$log_file"
}

test_installs_host_artifacts_and_enables_service() {
  local tmpdir log_file bridge_bin
  tmpdir="$(mktemp -d)"
  trap "rm -rf -- '$tmpdir'" RETURN
  log_file="${tmpdir}/commands.log"
  : >"$log_file"
  bridge_bin="${tmpdir}/aorus-bridge"

  prepare_fake_root "$tmpdir" "$log_file"
  write_fake_bridge "$bridge_bin" '0000:03:00.0'

  run_setup "$tmpdir" "$bridge_bin"

  assert_file_exists "${tmpdir}/usr/local/bin/aorus-bridge"
  assert_file_exists "${tmpdir}/usr/local/bin/aorus-modules"
  assert_file_exists "${tmpdir}/etc/modprobe.d/aorus.conf"
  assert_file_exists "${tmpdir}/etc/systemd/system/aorus.service"
  assert_file_exists "${tmpdir}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
  assert_same_file "${repo_root}/aorus-bridge" "${tmpdir}/usr/local/bin/aorus-bridge"
  assert_same_file "${repo_root}/aorus-modules" "${tmpdir}/usr/local/bin/aorus-modules"
  assert_same_file "${host_files}/etc/modprobe.d/aorus.conf" "${tmpdir}/etc/modprobe.d/aorus.conf"
  assert_same_file "${host_files}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf" "${tmpdir}/etc/systemd/system/nvidia-persistenced.service.d/aorus.conf"
  assert_contains 'systemctl daemon-reload' "$log_file"
  assert_contains 'systemctl enable aorus.service' "$log_file"
}

main() {
  test_backup_suffixes_increment_when_prior_backup_exists
  test_mkinitcpio_and_modprobe_changes_trigger_single_mkinitcpio_run
  test_mkinitcpio_handles_single_quoted_module_entries
  test_modprobe_changes_alone_trigger_single_mkinitcpio_run
  test_grub_is_canonicalized_with_detected_bridge
  test_grub_preserves_unrelated_kernel_args
  test_grub_adds_missing_cmdline_directives
  test_grub_handles_single_quoted_cmdline_values
  test_detect_failure_with_stderr_is_fatal
  test_missing_required_host_file_fails_install
  test_install_dry_run_announces_actions_without_mutating_host
  test_install_dry_run_does_not_create_missing_modprobe_dir
  test_install_announces_each_file_mutation_and_non_file_action
  test_install_rejects_unknown_args
  test_install_dry_run_fails_when_required_host_file_is_missing
  test_installs_host_artifacts_and_enables_service
}

main "$@"
