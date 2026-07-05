#!/usr/bin/env bash

AORUS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "${AORUS_LIB_DIR}/.." && pwd)}"
HOST_FILES_DIR="${HOST_FILES_DIR:-${REPO_ROOT}/host-files}"

ETC_ROOT="${ETC_ROOT:-/etc}"
MODPROBE_DIR="${MODPROBE_DIR:-${ETC_ROOT}/modprobe.d}"
SYSTEMD_ROOT="${SYSTEMD_ROOT:-${ETC_ROOT}/systemd/system}"
UDEV_RULES_DIR="${UDEV_RULES_DIR:-${ETC_ROOT}/udev/rules.d}"
USR_LOCAL_BIN_DIR="${USR_LOCAL_BIN_DIR:-/usr/local/bin}"
MKINITCPIO_CONF_PATH="${MKINITCPIO_CONF_PATH:-${ETC_ROOT}/mkinitcpio.conf}"
INITRAMFS_MODULES_PATH="${INITRAMFS_MODULES_PATH:-${ETC_ROOT}/initramfs-tools/modules}"
GRUB_DEFAULT_PATH="${GRUB_DEFAULT_PATH:-${ETC_ROOT}/default/grub}"
GRUB_CFG_PATH="${GRUB_CFG_PATH:-/boot/grub/grub.cfg}"

MKINITCPIO_BIN="${MKINITCPIO_BIN:-mkinitcpio}"
UPDATE_INITRAMFS_BIN="${UPDATE_INITRAMFS_BIN:-update-initramfs}"
# Selected initramfs backend: 'mkinitcpio' (Arch/Manjaro) or 'initramfs-tools' (Debian/Ubuntu).
# Left empty so detect_initramfs_backend can pick one; override to force a backend.
INITRAMFS_BACKEND="${INITRAMFS_BACKEND:-}"
GRUB_MKCONFIG_BIN="${GRUB_MKCONFIG_BIN:-grub-mkconfig}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
INSTALL_BIN="${INSTALL_BIN:-install}"
AORUS_BRIDGE_BIN="${AORUS_BRIDGE_BIN:-${REPO_ROOT}/aorus-bridge}"
INSTALL_REPO_FILE_UNCHANGED=10
DRY_RUN=0

parse_common_args() {
  DRY_RUN=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    *)
      die "unknown argument: $1"
      ;;
    esac
    shift
  done
}

announce_action() {
  local message="$1"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$message"
  else
    printf '%s\n' "$message"
  fi
}

run_action() {
  local message="$1"
  shift

  announce_action "$message"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  "$@"
}

run_quiet_action() {
  local message="$1"
  shift

  announce_action "$message"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  "$@" >/dev/null 2>&1
}

ensure_directory() {
  local path="$1"

  [[ -d "$path" ]] && return 0
  run_action "creating directory ${path}" mkdir -p -- "$path"
}

file_write_message() {
  local path="$1"

  if [[ -e "$path" ]]; then
    printf 'replacing %s\n' "$path"
  else
    printf 'installing %s\n' "$path"
  fi
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_root() {
  local script_name="${1:-install.sh}"

  if [[ "${AORUS_SETUP_ALLOW_NON_ROOT:-0}" == "1" ]]; then
    return 0
  fi

  if [[ "$EUID" -ne 0 ]]; then
    die "${script_name} must be run as root"
  fi
}

require_tool() {
  local path="$1"
  local label="$2"

  command -v "$path" >/dev/null 2>&1 || die "missing required tool: ${label}"
}

# Pick the initramfs backend for this host. Prefers mkinitcpio when present so
# Arch/Manjaro behaviour is unchanged; falls back to initramfs-tools on
# Debian/Ubuntu. Respects an explicit INITRAMFS_BACKEND override.
detect_initramfs_backend() {
  if [[ -n "$INITRAMFS_BACKEND" ]]; then
    return 0
  fi

  if command -v "$MKINITCPIO_BIN" >/dev/null 2>&1; then
    INITRAMFS_BACKEND='mkinitcpio'
  elif command -v "$UPDATE_INITRAMFS_BIN" >/dev/null 2>&1; then
    INITRAMFS_BACKEND='initramfs-tools'
  else
    die 'missing required tool: mkinitcpio or update-initramfs'
  fi
}

backup_path_for() {
  local path="$1"
  local index=0
  local candidate

  while :; do
    printf -v candidate '%s.aorus.%02d' "$path" "$index"
    [[ ! -e "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
    index=$((index + 1))
  done
}

newest_backup_path_for() {
  local path="$1"
  local file suffix max_suffix=-1 newest=''

  shopt -s nullglob
  for file in "${path}.aorus."*; do
    [[ "$file" =~ \.aorus\.([0-9]+)$ ]] || continue
    suffix=$((10#${BASH_REMATCH[1]}))
    if ((suffix > max_suffix)); then
      max_suffix=$suffix
      newest="$file"
    fi
  done
  shopt -u nullglob

  [[ -n "$newest" ]] || return 1
  printf '%s\n' "$newest"
}

backup_existing_file() {
  local path="$1"

  [[ -f "$path" ]] || return 0
  cp -- "$path" "$(backup_path_for "$path")"
}

write_if_changed() {
  local target="$1"
  local source="$2"
  local message

  if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
    rm -f -- "$source"
    return 1
  fi

  if [[ -f "$target" ]]; then
    chmod --reference="$target" "$source"
    if [[ "${AORUS_SETUP_ALLOW_NON_ROOT:-0}" != "1" ]]; then
      chown --reference="$target" "$source"
    fi
  else
    chmod 0644 "$source"
  fi

  message="$(file_write_message "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    announce_action "$message"
    rm -f -- "$source"
    return 0
  fi

  backup_existing_file "$target"
  run_action "$message" mv -- "$source" "$target"
  return 0
}

install_repo_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  local message

  [[ -f "$src" ]] || die "missing required file: ${src}"
  ensure_directory "$(dirname -- "$dst")" || return $?
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    return "$INSTALL_REPO_FILE_UNCHANGED"
  fi

  message="$(file_write_message "$dst")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    announce_action "$message"
    return 0
  fi

  backup_existing_file "$dst" || return $?

  if [[ "${AORUS_SETUP_ALLOW_NON_ROOT:-0}" == "1" ]]; then
    run_action "$message" "$INSTALL_BIN" -D -m "$mode" "$src" "$dst" || return $?
  else
    run_action "$message" "$INSTALL_BIN" -o root -g root -D -m "$mode" "$src" "$dst" || return $?
  fi

  return 0
}

regenerate_if_dirty() {
  if [[ "$MKINITCPIO_DIRTY" -eq 1 ]]; then
    case "$INITRAMFS_BACKEND" in
    initramfs-tools)
      run_action 'running update-initramfs -u' "$UPDATE_INITRAMFS_BIN" -u
      ;;
    *)
      run_action 'running mkinitcpio -P' "$MKINITCPIO_BIN" -P
      ;;
    esac
    [[ "$DRY_RUN" -eq 0 ]] && REBOOT_REQUIRED=1
  fi

  if [[ "$GRUB_DIRTY" -eq 1 ]]; then
    run_action "running grub-mkconfig -o ${GRUB_CFG_PATH}" "$GRUB_MKCONFIG_BIN" -o "$GRUB_CFG_PATH"
    [[ "$DRY_RUN" -eq 0 ]] && REBOOT_REQUIRED=1
  fi

  return 0
}

repo_owned_artifact_paths() {
  printf '%s\n' \
    "${USR_LOCAL_BIN_DIR}/aorus-bridge" \
    "${USR_LOCAL_BIN_DIR}/aorus-modules" \
    "${MODPROBE_DIR}/aorus.conf" \
    "${SYSTEMD_ROOT}/aorus.service" \
    "${SYSTEMD_ROOT}/nvidia-persistenced.service.d/aorus.conf"
}
