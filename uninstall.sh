#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/install-common.sh
source "${REPO_ROOT}/lib/install-common.sh"

MKINITCPIO_DIRTY=0
GRUB_DIRTY=0
REBOOT_REQUIRED=0

CAP_MODULE_NAME="aorus-cap"
CAP_MODULE_VERSION="0.1"

best_effort_runtime_rollback() {
  local installed_bridge_bin="${USR_LOCAL_BIN_DIR}/aorus-bridge"
  local module
  # aorus_cap is unloaded last, after the bridge restore has used it (under
  # lockdown the restore delegates the bit-5 clear to this same module).
  local -a modules=(nvidia_uvm nvidia_drm nvidia_modeset nvidia aorus_cap)
  local modprobe_bin="${MODPROBE_BIN:-modprobe}"

  if [[ -x "$installed_bridge_bin" ]]; then
    run_quiet_action 'restoring live bridge state' "$installed_bridge_bin" restore || true
  fi

  if command -v "$modprobe_bin" >/dev/null 2>&1; then
    for module in "${modules[@]}"; do
      run_quiet_action "unloading ${module}" "$modprobe_bin" -r "$module" || true
    done
  fi
}

mark_generated_artifacts_dirty() {
  local target="$1"

  case "$target" in
  "$MKINITCPIO_CONF_PATH" | "$INITRAMFS_MODULES_PATH" | "$MODPROBE_DIR"/*.conf)
    MKINITCPIO_DIRTY=1
    ;;
  esac

  if [[ "$target" == "$GRUB_DEFAULT_PATH" ]]; then
    GRUB_DIRTY=1
  fi
}

managed_backup_exists() {
  local path file found=1

  if newest_backup_path_for "$MKINITCPIO_CONF_PATH" >/dev/null 2>&1 ||
    newest_backup_path_for "$INITRAMFS_MODULES_PATH" >/dev/null 2>&1 ||
    newest_backup_path_for "$GRUB_DEFAULT_PATH" >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r path; do
    if newest_backup_path_for "$path" >/dev/null 2>&1; then
      return 0
    fi
  done < <(repo_owned_artifact_paths)

  [[ -d "$MODPROBE_DIR" ]] || return 1

  shopt -s nullglob
  for file in "$MODPROBE_DIR"/*.conf.aorus.*; do
    [[ "$file" =~ \.aorus\.[0-9]+$ ]] || continue
    found=0
    break
  done
  shopt -u nullglob

  return "$found"
}

grub_value_has_managed_args() {
  local value="$1"
  local expected_bridge="$2"
  local token seen_iommu_pt=0 seen_host_reset=0
  local seen_aspm=0 seen_clx=0 seen_port_pm=0 seen_bridge=0
  # Must mirror install.sh's `required` array exactly (iommu.passthrough=1, not
  # the old iommu=off/intel_iommu=off) or uninstall won't recognize the managed
  # GRUB_CMDLINE_LINUX and will refuse to restore it.
  local suffix_regex='(^| )iommu.passthrough=1 thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@([[:xdigit:]:.]+)$'
  local -a tokens=()

  [[ "$value" =~ $suffix_regex ]] || return 1
  [[ -n "$expected_bridge" && "${BASH_REMATCH[2]}" == "$expected_bridge" ]] || return 1

  read -r -a tokens <<<"$value"
  for token in "${tokens[@]}"; do
    case "$token" in
    *nvidia* | rd.driver.blacklist=*nvidia* | modprobe.blacklist=*nvidia* | module_blacklist=*nvidia*)
      return 1
      ;;
    iommu.passthrough=1)
      seen_iommu_pt=$((seen_iommu_pt + 1))
      ;;
    iommu.passthrough=*)
      return 1
      ;;
    thunderbolt.host_reset=false)
      seen_host_reset=$((seen_host_reset + 1))
      ;;
    thunderbolt.host_reset=*)
      return 1
      ;;
    pcie_aspm.policy=performance)
      seen_aspm=$((seen_aspm + 1))
      ;;
    pcie_aspm.policy=*)
      return 1
      ;;
    thunderbolt.clx=0)
      seen_clx=$((seen_clx + 1))
      ;;
    thunderbolt.clx=*)
      return 1
      ;;
    pcie_port_pm=off)
      seen_port_pm=$((seen_port_pm + 1))
      ;;
    pcie_port_pm=*)
      return 1
      ;;
    pci=resource_alignment=35@"$expected_bridge")
      seen_bridge=$((seen_bridge + 1))
      ;;
    pci=resource_alignment=35@*)
      return 1
      ;;
    esac
  done

  [[ "$seen_iommu_pt" -eq 1 && "$seen_host_reset" -eq 1 && "$seen_aspm" -eq 1 && "$seen_clx" -eq 1 && "$seen_port_pm" -eq 1 && "$seen_bridge" -eq 1 ]]
}

mkinitcpio_has_managed_edits() {
  local path="$1"
  local line raw token
  local -a modules=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^MODULES=\((.*)\)$ ]] || continue
    raw="${BASH_REMATCH[1]}"
    eval "modules=( ${raw} )"

    for token in "${modules[@]}"; do
      case "$token" in
      nvidia | nvidia_drm | nvidia_modeset | nvidia_uvm)
        return 0
        ;;
      esac
    done

    return 1
  done <"$path"

  return 1
}

initramfs_tools_has_managed_edits() {
  local path="$1"
  local line module

  while IFS= read -r line || [[ -n "$line" ]]; do
    module="${line%%[[:space:]]*}"
    case "$module" in
    nvidia | nvidia_drm | nvidia_modeset | nvidia_uvm)
      return 0
      ;;
    esac
  done <"$path"

  return 1
}

restore_managed_initramfs_config() {
  case "$INITRAMFS_BACKEND" in
  initramfs-tools)
    restore_managed_mutable_file "$INITRAMFS_MODULES_PATH" initramfs_tools_has_managed_edits
    ;;
  *)
    restore_managed_mutable_file "$MKINITCPIO_CONF_PATH" mkinitcpio_has_managed_edits
    ;;
  esac
}

grub_has_managed_edits() {
  local path="$1"
  local line default_value='' linux_value=''
  local bridge

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
    GRUB_CMDLINE_LINUX_DEFAULT=\"*\")
      default_value="${line#GRUB_CMDLINE_LINUX_DEFAULT=\"}"
      default_value="${default_value%\"}"
      ;;
    GRUB_CMDLINE_LINUX=\"*\")
      linux_value="${line#GRUB_CMDLINE_LINUX=\"}"
      linux_value="${linux_value%\"}"
      ;;
    esac
  done <"$path"

  [[ "$linux_value" =~ pci=resource_alignment=35@([[:xdigit:]:.]+)$ ]] || return 1
  bridge="${BASH_REMATCH[1]}"

  grub_value_has_managed_args "$linux_value" "$bridge" || return 1
  ! grub_value_has_managed_args "$default_value" "$bridge"
}

modprobe_file_has_managed_edits() {
  local path="$1"

  grep -Fq '# aorus-disabled:' "$path"
}

restore_managed_mutable_file() {
  local path="$1"
  local detector="$2"
  local backup

  if backup="$(newest_backup_path_for "$path")"; then
    announce_action "restoring ${path}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      mv -- "$backup" "$path"
    fi
    mark_generated_artifacts_dirty "$path"
    return 0
  fi

  if [[ -f "$path" ]] && "$detector" "$path"; then
    die "missing backup for managed file: ${path}"
  fi
}

restore_managed_modprobe_tree() {
  local file path
  local -A seen=()

  [[ -d "$MODPROBE_DIR" ]] || return 0
  for file in "$MODPROBE_DIR"/*.conf "$MODPROBE_DIR"/*.conf.aorus.*; do
    [[ -e "$file" ]] || continue
    path="${file%.aorus.*}"
    [[ "$path" == "$MODPROBE_DIR/aorus.conf" ]] && continue
    [[ -n "${seen[$path]:-}" ]] && continue
    seen["$path"]=1
    restore_managed_mutable_file "$path" modprobe_file_has_managed_edits
  done
}

restore_or_remove_repo_owned_file() {
  local path="$1"
  local backup

  if backup="$(newest_backup_path_for "$path")"; then
    announce_action "restoring ${path}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      mv -- "$backup" "$path"
    fi
    mark_generated_artifacts_dirty "$path"
    return 0
  fi

  if [[ -e "$path" ]]; then
    run_action "removing ${path}" rm -f -- "$path"
    mark_generated_artifacts_dirty "$path"
  fi
}

restore_or_remove_repo_owned_artifacts() {
  local path

  while IFS= read -r path; do
    restore_or_remove_repo_owned_file "$path"
  done < <(repo_owned_artifact_paths)
}

# Remove the aorus_cap DKMS module (built + installed only under Secure Boot by
# install.sh). dkms remove --all drops it for every kernel and deletes the built
# objects; the staged source tree under /usr/src is removed separately.
remove_cap_module() {
  local spec="-m ${CAP_MODULE_NAME} -v ${CAP_MODULE_VERSION}"
  local src="${DKMS_SRC_DIR}/${CAP_MODULE_NAME}-${CAP_MODULE_VERSION}"

  if command -v "$DKMS_BIN" >/dev/null 2>&1 && "$DKMS_BIN" status $spec 2>/dev/null | grep -q .; then
    run_quiet_action "removing DKMS module ${CAP_MODULE_NAME}/${CAP_MODULE_VERSION}" \
      "$DKMS_BIN" remove $spec --all || true
  fi

  if [[ -d "$src" ]]; then
    run_action "removing ${src}" rm -rf -- "$src"
  fi
}

reload_daemons() {
  run_action 'reloading systemd manager' "$SYSTEMCTL_BIN" daemon-reload
  if command -v "$UDEVADM_BIN" >/dev/null 2>&1; then
    run_action 'reloading udev rules' "$UDEVADM_BIN" control --reload-rules
  fi
}

main() {
  parse_common_args "$@"

  require_root 'uninstall.sh'
  detect_initramfs_backend
  require_tool "$GRUB_MKCONFIG_BIN" 'grub-mkconfig'
  require_tool "$SYSTEMCTL_BIN" 'systemctl'

  run_quiet_action 'disabling aorus.service' "$SYSTEMCTL_BIN" disable aorus.service || true

  best_effort_runtime_rollback
  remove_cap_module
  restore_managed_initramfs_config
  restore_managed_mutable_file "$GRUB_DEFAULT_PATH" grub_has_managed_edits
  restore_managed_modprobe_tree
  restore_or_remove_repo_owned_artifacts
  regenerate_if_dirty
  reload_daemons

  if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    printf 'uninstall complete; reboot required\n'
  else
    printf 'uninstall complete; no reboot required\n'
  fi
}

main "$@"
