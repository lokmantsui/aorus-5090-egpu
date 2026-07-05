#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
install_script="${repo_root}/install.sh"
uninstall_script="${repo_root}/uninstall.sh"
host_files="${repo_root}/host-files"

assert_equals() {
  local expected="$1" actual="$2" message="$3"
  [[ "$expected" == "$actual" ]] || {
    printf '%s: expected %s, got %s\n' "$message" "$expected" "$actual" >&2
    return 1
  }
}

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" || {
    printf 'expected to find %s in %s\n' "$needle" "$file" >&2
    return 1
  }
}

assert_not_contains() {
  local needle="$1" file="$2"
  ! grep -Fq -- "$needle" "$file" || {
    printf 'expected %s to be absent from %s\n' "$needle" "$file" >&2
    return 1
  }
}

assert_file_exists() {
  [[ -e "$1" ]] || {
    printf 'expected file to exist: %s\n' "$1" >&2
    return 1
  }
}

assert_file_content() {
  local expected="$1" file="$2" actual
  actual="$(<"$file")"
  [[ "$expected" == "$actual" ]] || {
    printf 'unexpected contents for %s\nexpected:\n%s\nactual:\n%s\n' "$file" "$expected" "$actual" >&2
    return 1
  }
}

write_fake_command() {
  local path="$1" log_file="$2" body="$3" name
  name="$(basename "$path")"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$name" "\$*" >>"$log_file"
$body
EOF
  chmod +x "$path"
}

write_fake_bridge() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "detect" ]] && { printf '0000:03:00.0\n'; exit 0; }
exit 1
EOF
  chmod +x "$1"
}

# A fake root that looks like Debian/Ubuntu: no mkinitcpio binary, only
# update-initramfs and /etc/initramfs-tools/modules.
prepare_ubuntu_root() {
  local root="$1" log_file="$2"

  mkdir -p "${root}/etc/modprobe.d" "${root}/etc/default" \
    "${root}/etc/initramfs-tools" "${root}/usr/local/bin" \
    "${root}/boot/grub" "${root}/bin"

  cat >"${root}/etc/initramfs-tools/modules" <<'EOF'
# List of modules that you want to include in your initramfs.
xhci_pci
nvidia
nvidia_drm modeset=1
thunderbolt
EOF

  cat >"${root}/etc/modprobe.d/nvidia.conf" <<'EOF'
options nvidia-drm modeset=1
softdep nvidia post: nvidia-uvm
EOF

  cat >"${root}/etc/default/grub" <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
EOF

  write_fake_command "${root}/bin/update-initramfs" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/grub-mkconfig" "$log_file" 'while [[ $# -gt 0 ]]; do if [[ "$1" == "-o" ]]; then shift; : >"$1"; fi; shift; done'
  write_fake_command "${root}/bin/systemctl" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/modprobe" "$log_file" 'exit 0'
  write_fake_command "${root}/bin/install" "$log_file" '/usr/bin/install "$@"'
}

run_script() {
  local root="$1" script="$2"
  shift 2
  # PATH deliberately excludes any real mkinitcpio so detection falls through
  # to the initramfs-tools backend.
  env \
    AORUS_SETUP_ALLOW_NON_ROOT=1 \
    AORUS_CAP_MODULE=never \
    UDEVADM_BIN=true \
    DKMS_BIN=false \
    DKMS_SRC_DIR="${root}/usr/src" \
    PATH="${root}/bin:/usr/bin:/bin" \
    ETC_ROOT="${root}/etc" \
    MODPROBE_DIR="${root}/etc/modprobe.d" \
    SYSTEMD_ROOT="${root}/etc/systemd/system" \
    USR_LOCAL_BIN_DIR="${root}/usr/local/bin" \
    INITRAMFS_MODULES_PATH="${root}/etc/initramfs-tools/modules" \
    MKINITCPIO_CONF_PATH="${root}/etc/mkinitcpio.conf" \
    GRUB_DEFAULT_PATH="${root}/etc/default/grub" \
    GRUB_CFG_PATH="${root}/boot/grub/grub.cfg" \
    HOST_FILES_DIR="$host_files" \
    AORUS_BRIDGE_BIN="${root}/aorus-bridge" \
    bash "$script" "$@"
}

test_install_uses_update_initramfs_and_strips_nvidia_modules() {
  local root log_file
  root="$(mktemp -d)"
  trap "rm -rf -- '$root'" RETURN
  log_file="${root}/commands.log"
  : >"$log_file"

  prepare_ubuntu_root "$root" "$log_file"
  write_fake_bridge "${root}/aorus-bridge"

  run_script "$root" "$install_script" >/dev/null

  # Initramfs regeneration goes through update-initramfs, never mkinitcpio.
  assert_contains 'update-initramfs -u' "$log_file"
  assert_not_contains 'mkinitcpio' "$log_file"

  # NVIDIA force-load entries are removed; unrelated modules are preserved.
  assert_file_content "$(
    cat <<'EOF'
# List of modules that you want to include in your initramfs.
xhci_pci
thunderbolt
EOF
  )" "${root}/etc/initramfs-tools/modules"

  # Pre-existing NVIDIA modprobe policy is disabled, repo files installed.
  assert_contains '# aorus-disabled: options nvidia-drm modeset=1' "${root}/etc/modprobe.d/nvidia.conf"
  assert_file_exists "${root}/etc/modprobe.d/aorus.conf"
  assert_file_exists "${root}/usr/local/bin/aorus-bridge"
  assert_file_exists "${root}/etc/systemd/system/aorus.service"

  # GRUB still gets the managed power-management args.
  assert_contains 'pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off' "${root}/etc/default/grub"
}

test_install_then_uninstall_round_trips_initramfs_tools_host() {
  local root log_file modules_before nvidia_before grub_before
  root="$(mktemp -d)"
  trap "rm -rf -- '$root'" RETURN
  log_file="${root}/commands.log"
  : >"$log_file"

  prepare_ubuntu_root "$root" "$log_file"
  write_fake_bridge "${root}/aorus-bridge"

  modules_before="$(<"${root}/etc/initramfs-tools/modules")"
  nvidia_before="$(<"${root}/etc/modprobe.d/nvidia.conf")"
  grub_before="$(<"${root}/etc/default/grub")"

  run_script "$root" "$install_script" >/dev/null
  run_script "$root" "$uninstall_script" >/dev/null

  assert_file_content "$modules_before" "${root}/etc/initramfs-tools/modules"
  assert_file_content "$nvidia_before" "${root}/etc/modprobe.d/nvidia.conf"
  assert_file_content "$grub_before" "${root}/etc/default/grub"

  [[ ! -e "${root}/etc/modprobe.d/aorus.conf" ]] || {
    printf 'expected aorus.conf to be removed on uninstall\n' >&2
    return 1
  }
  [[ ! -e "${root}/usr/local/bin/aorus-bridge" ]] || {
    printf 'expected aorus-bridge to be removed on uninstall\n' >&2
    return 1
  }

  assert_equals '0' "$(find "$root" -name '*.aorus.*' | wc -l)" 'no managed backups should remain'
}

main() {
  test_install_uses_update_initramfs_and_strips_nvidia_modules
  test_install_then_uninstall_round_trips_initramfs_tools_host
}

main "$@"
