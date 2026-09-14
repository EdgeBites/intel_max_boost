#!/usr/bin/env bash
#
# intel_max_boost.sh — apply max-boost MSR tuning on Intel Xeon Gold (Skylake-SP).
#
# Requires: unlocked MSR BIOS (pre-Plundervolt-mitigation), msr-tools, root.
#
# What it does:
#   1. Sets CPU governor to `performance` (required so 0x199/PERF_CTL sticks).
#   2. Writes 13 MSRs to all CPUs via `wrmsr -a`.
#      0x610 is package-scope; writing it per-CPU is harmless.
#   3. Verifies with `rdmsr -p <cpu>`; 0x64F upper bits are HW-dynamic (warn only).
#
# WARNING: writing MSRs can crash, overheat, or damage hardware. Know what each
# MSR does on your CPU before running. See README.md. Use at your own risk.
#
# SPDX-License-Identifier: MIT
# Usage: sudo ./intel_max_boost.sh [--dry-run] [--log-file PATH]
#        sudo ./intel_max_boost.sh --help

set -euo pipefail
shopt -s extglob

LOG_FILE="/var/log/msr-apply.log"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sudo intel_max_boost.sh [OPTIONS]

Apply Intel max-boost MSR tuning to all CPUs, then verify.

Options:
  -n, --dry-run        Print what would be done, do not write MSRs/governor
      --log-file PATH  Log file (default: /var/log/msr-apply.log).
                       Use --log-file "" to log to stdout only.
  -h, --help           Show this help and exit.

Requires: root, msr-tools (wrmsr/rdmsr), unlocked MSR BIOS.
Target: Xeon Gold Skylake-SP.
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Ordered MSR list is the single source of truth (13 entries).
MSR_ORDER=(
  0x48 0x4E 0x199 0x1A0 0x1A4 0x1B0 0x1B2
  0x38D 0x38F 0x3F1 0x610 0x64F 0x770
)

declare -A MSR_VALUES=(
  [0x48]="0x0"
  [0x4E]="0x2"
  [0x199]="0x2500"
  [0x1A0]="0x850089"
  [0x1A4]="0x2"
  [0x1B0]="0x0"
  [0x1B2]="0x0"
  [0x38D]="0x330"
  [0x38F]="0x70000000f"
  [0x3F1]="0x0"
  [0x610]="0x28b1800fe8b18"
  [0x64F]="0xc000c000"
  [0x770]="0x0"
)

# Strict-verify list: everything except 0x64F (dynamic upper 16 bits).
STRICT_ORDER=(
  0x48 0x4E 0x199 0x1A0 0x1A4 0x1B0 0x1B2
  0x38D 0x38F 0x3F1 0x610 0x770
)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -n | --dry-run)
        DRY_RUN=1
        shift
        ;;
      --log-file)
        [[ $# -ge 2 ]] || die "--log-file needs a PATH argument"
        LOG_FILE="$2"
        shift 2
        ;;
      --log-file=*)
        LOG_FILE="${1#--log-file=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1 (see --help)"
        ;;
      *)
        die "unexpected argument: $1 (see --help)"
        ;;
    esac
  done
}

setup_logging() {
  [[ -n "${LOG_FILE}" ]] || return 0
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  local log_dir
  log_dir="$(dirname "${LOG_FILE}")"
  if ! mkdir -p "${log_dir}" 2>/dev/null || ! touch "${LOG_FILE}" 2>/dev/null; then
    warn "cannot write to ${LOG_FILE}; logging to stdout only"
    LOG_FILE=""
    return 0
  fi
  # shellcheck disable=SC2064
  trap "exec 1>&3 2>&4" EXIT
  exec 3>&1 4>&2
  exec > >(tee -a "${LOG_FILE}") 2>&1
}

check_root() {
  [[ "${DRY_RUN}" -eq 1 ]] && return 0
  [[ "$(id -u)" -eq 0 ]] || die "must run as root (use sudo)"
}

check_deps() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    command -v wrmsr >/dev/null 2>&1 || warn "wrmsr not found (would need msr-tools for real run)"
    command -v rdmsr >/dev/null 2>&1 || warn "rdmsr not found (would need msr-tools for real run)"
    return 0
  fi
  command -v wrmsr >/dev/null 2>&1 || die "wrmsr not found (install msr-tools)"
  command -v rdmsr >/dev/null 2>&1 || die "rdmsr not found (install msr-tools)"
  command -v modprobe >/dev/null 2>&1 || die "modprobe not found"
  modprobe msr || die "modprobe msr failed"
}

warn_hardware() {
  log "--- hardware (warn-only, no enforcement) ---"
  if command -v lscpu >/dev/null 2>&1; then
    lscpu | grep -Ei 'vendor|model name|family|stepping' || true
  else
    warn "lscpu not found; skipping CPU identification"
  fi
  warn "values target Xeon Gold Skylake-SP. Other CPUs are untested."
  warn "requires unlocked MSR BIOS; writes can crash or damage hardware."
}

# Normalize hex for comparison: lowercase, strip 0x, strip leading zeros.
# Prints "0" for empty/zero input. Never fails (safe with `set -e`).
norm_hex() {
  local h="${1:-}"
  h="${h,,}"
  h="${h#0x}"
  h="${h##+(0)}"
  if [[ -z "${h}" ]]; then
    printf '0'
  else
    printf '%s' "${h}"
  fi
  return 0
}

cpu_list() {
  local n
  n="$(nproc)"
  seq 0 $((n - 1))
}

set_governor() {
  log "--- setting governor=performance ---"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "(dry-run) would set governor=performance via cpupower/sysfs"
    return 0
  fi

  if command -v cpupower >/dev/null 2>&1; then
    cpupower frequency-set -g performance || warn "cpupower failed, falling back to sysfs"
  fi

  local f ok=0 total=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -e "${f}" ]] || continue
    total=$((total + 1))
    if echo performance >"${f}" 2>/dev/null; then
      ok=$((ok + 1))
    else
      warn "cannot write ${f}"
    fi
  done

  if [[ "${total}" -eq 0 ]]; then
    warn "no scaling_governor files found; skipping governor check"
    return 0
  fi

  sleep 1
  local perf=0
  perf=$(grep -c '^performance$' /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true)
  log "governor performance: ${perf}/${total} (wrote ${ok}/${total})"
  [[ "${perf}" == "${total}" ]] || warn "not all CPUs on performance"
}

apply_msrs() {
  log "--- wrmsr -a ---"
  local msr val fail=0
  for msr in "${MSR_ORDER[@]}"; do
    val="${MSR_VALUES[${msr}]}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      log "(dry-run) wrmsr -a ${msr} ${val}"
      continue
    fi
    if wrmsr -a "${msr}" "${val}"; then
      log "OK ${msr}=${val}"
    else
      warn "FAIL ${msr}=${val}"
      fail=$((fail + 1))
    fi
  done
  [[ "${fail}" -eq 0 ]] || die "${fail} wrmsr failures"
}

verify_msr_strict() {
  local msr="$1" exp="$2"
  local exp_n bad=0 cpu got got_n
  exp_n="$(norm_hex "${exp}")"
  while read -r cpu; do
    if ! got="$(rdmsr -p "${cpu}" "${msr}" 2>&1)"; then
      got="RDFAIL"
    fi
    got_n="$(norm_hex "${got}")"
    if [[ "${got_n}" != "${exp_n}" ]]; then
      bad=$((bad + 1))
      if [[ "${bad}" -le 3 ]]; then
        warn "MISMATCH cpu${cpu} ${msr} exp=${exp} got=${got}"
      fi
    fi
  done < <(cpu_list)
  if [[ "${bad}" -eq 0 ]]; then
    log "VERIFY OK ${msr}=${exp} (all CPUs)"
    return 0
  fi
  warn "VERIFY FAIL ${msr} exp=${exp} mismatches=${bad}"
  return 1
}

verify_msr_64f() {
  # Only lower 16 bits (c000) are required; upper bits are HW-dynamic
  # (c000c000, c080c000, e080c000, ... observed live).
  local bad=0 cpu got norm
  while read -r cpu; do
    if ! got="$(rdmsr -p "${cpu}" 0x64F 2>&1)"; then
      got="RDFAIL"
    fi
    norm="$(norm_hex "${got}")"
    case "${norm}" in
      c000 | *[0-9a-f]c000)
        # lower 16 bits == 0xc000
        ;;
      *)
        bad=$((bad + 1))
        if [[ "${bad}" -le 3 ]]; then
          warn "MISMATCH cpu${cpu} 0x64F got=${got} (want lower16=c000)"
        fi
        ;;
    esac
  done < <(cpu_list)
  if [[ "${bad}" -eq 0 ]]; then
    log "VERIFY OK 0x64F lower=c000 (upper dynamic, file=c000c000)"
  else
    warn "0x64F mismatches=${bad} (HW-dynamic upper bits)"
  fi
}

verify_all() {
  log "--- verify (rdmsr all CPUs) ---"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "(dry-run) would verify ${#MSR_ORDER[@]} MSRs via rdmsr"
    return 0
  fi
  local msr mismatch=0
  for msr in "${STRICT_ORDER[@]}"; do
    verify_msr_strict "${msr}" "${MSR_VALUES[${msr}]}" || mismatch=$((mismatch + 1))
  done
  verify_msr_64f
  [[ "${mismatch}" -eq 0 ]] || die "${mismatch} strict MSR mismatches"
}

main() {
  parse_args "$@"
  setup_logging
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "=== intel_max_boost.sh $(date -u) (dry-run) ==="
  else
    log "=== intel_max_boost.sh $(date -u) ==="
  fi
  check_root
  check_deps
  warn_hardware
  set_governor
  apply_msrs
  verify_all
  log "=== intel_max_boost.sh DONE $(date -u) ==="
}

main "$@"
