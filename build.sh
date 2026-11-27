#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# ARKM PRODUCTION BUILD + VALIDATION SYSTEM
# ============================================================================
#
# This build script preserves the existing ARKM workflow while adding:
#   - strict toolchain/dependency checks
#   - strict kernel compilation (-Wall -Wextra -Werror)
#   - architecture/source completeness checks
#   - interrupt-stub ownership checks
#   - ARKM-patched GRUB 2.14 x86_64-efi loader built with native Linux GCC in WSL
#     when the main workflow is launched from MSYS2 UCRT64
#   - UEFI-only El Torito ISO (EFI entry only; no BIOS boot entry)
#   - PE32+ EFI application and UEFI El Torito catalog validation
#   - separate OVMF + Q35 test runner, matching the established ARKM workflow
#   - deterministic FAT32 test disk creation
#   - QEMU CPU-reset/triple-fault diagnostics
#   - production certification artifact generation
#   - an explicit distinction between BUILD/BOOT proof and runtime
#     certification.  The script never claims LUNA/AMP/Aegis/PROD runtime
#     certification unless the guest itself reports it.
#
# Two-stage workflow:
#   ./build.sh
#   ./run-arkm-uefi-only-qemu.sh
# The build stage produces arkm-uefi-only-test.iso; the separate runner boots
# it under OVMF + Q35 and uses copied test HDD/VARS images.
# E1000-only device profile remains available; it still boots through UEFI:
#   QEMU_PROFILE=legacy ./build.sh
#
# Production kernel file can be selected without renaming it:
#   KERNEL_SOURCE=arkm_production_v1.c ./build.sh
#
# BSP-only diagnostic:
#   SMP_CPUS=1 ./build.sh
#
# Override the discovered x86_64 OVMF pair when required:
#   OVMF_CODE=/path/edk2-x86_64-code.fd OVMF_VARS=/path/edk2-i386-vars.fd ./build.sh
# Persistent writable UEFI variable store: arkm_uefi_vars.fd
# Disable QEMU launch (UEFI ISO/certification artifacts only):
#   RUN_QEMU=0 ./build.sh  (default; use the separate run script)
#
# ============================================================================

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
BUILD_START_SECONDS=$SECONDS
# ARKM_PASST_LAUNCHER_GENERATOR_V1
# Generate a standalone Linux/WSL launcher without invoking the destructive build.
GENERATE_PASST_LAUNCHER_ONLY="${GENERATE_PASST_LAUNCHER_ONLY:-0}"
write_passt_launcher() {
    cat > "$ROOT_DIR/run-arkm-passt.sh" <<'PASST_LAUNCHER'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_PASST_IPV6_IFACE="${QEMU_PASST_IPV6_IFACE:-auto}"
QEMU_PASST_IPV6_GATEWAY="${QEMU_PASST_IPV6_GATEWAY:-auto}"
QEMU_PASST_PCAP_FILE="${QEMU_PASST_PCAP_FILE:-arkm_passt_ipv6.pcap}"
QEMU_PASST_TRACE="${QEMU_PASST_TRACE:-1}"
QEMU_QMP_PORT="${QEMU_QMP_PORT:-4452}"
OVMF_CODE_IMAGE="${OVMF_CODE_IMAGE:-arkm_ovmf_code.fd}"
OVMF_VARS_IMAGE="${OVMF_VARS_IMAGE:-arkm_uefi_vars.fd}"

for f in arkm-uefi-only-test.iso hdd.img swap.img "$OVMF_CODE_IMAGE" "$OVMF_VARS_IMAGE"; do
    [[ -f "$f" ]] || { echo "Missing $f in $ROOT_DIR" >&2; exit 1; }
done
for cmd in "$QEMU_BIN" passt ip awk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done
[[ "$(uname -s)" == Linux ]] || { echo "Run this helper in Linux/WSL, not MSYS2/Windows." >&2; exit 1; }
[[ "$QEMU_PASST_TRACE" == 0 || "$QEMU_PASST_TRACE" == 1 ]] || { echo "QEMU_PASST_TRACE must be 0 or 1" >&2; exit 1; }
[[ -n "$QEMU_PASST_PCAP_FILE" && "$QEMU_PASST_PCAP_FILE" != *,* ]] || { echo "PCAP filename must be non-empty and cannot contain commas" >&2; exit 1; }
[[ "$QEMU_QMP_PORT" =~ ^[0-9]+$ && "$QEMU_QMP_PORT" -ge 1024 && "$QEMU_QMP_PORT" -le 65535 ]] || { echo "QEMU_QMP_PORT must be between 1024 and 65535" >&2; exit 1; }

help_text="$("$QEMU_BIN" -netdev help 2>&1 || true)"
grep -Eq '(^|[^[:alnum:]_])passt([^[:alnum:]_]|$)' <<<"$help_text" || { echo "This QEMU build has no passt backend" >&2; exit 1; }

if [[ "$QEMU_PASST_IPV6_IFACE" == auto ]]; then
    route="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1 || true)"
    QEMU_PASST_IPV6_IFACE="$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route")"
    if [[ -z "$QEMU_PASST_IPV6_IFACE" ]]; then
        route="$(ip -6 route show default 2>/dev/null | head -n 1 || true)"
        QEMU_PASST_IPV6_IFACE="$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route")"
    fi
fi
[[ -n "$QEMU_PASST_IPV6_IFACE" && "$QEMU_PASST_IPV6_IFACE" != auto ]] || { echo "Cannot detect IPv6 interface; set QEMU_PASST_IPV6_IFACE explicitly." >&2; exit 1; }
ip link show dev "$QEMU_PASST_IPV6_IFACE" >/dev/null 2>&1 || { echo "Interface does not exist: $QEMU_PASST_IPV6_IFACE" >&2; exit 1; }

if [[ "$QEMU_PASST_IPV6_GATEWAY" == auto ]]; then
    default_route="$(ip -6 route show default dev "$QEMU_PASST_IPV6_IFACE" 2>/dev/null | head -n 1 || true)"
    QEMU_PASST_IPV6_GATEWAY="$(awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$default_route")"
fi
[[ -n "$QEMU_PASST_IPV6_GATEWAY" && "$QEMU_PASST_IPV6_GATEWAY" != auto ]] || {
    echo "Cannot detect IPv6 gateway on $QEMU_PASST_IPV6_IFACE." >&2
    echo "Run: ip -6 route show default dev $QEMU_PASST_IPV6_IFACE" >&2
    exit 1
}
[[ "$QEMU_PASST_IPV6_GATEWAY" != *,* ]] || { echo "IPv6 gateway cannot contain commas" >&2; exit 1; }

QEMU_NETDEV="passt,id=net0,ipv4=on,ipv6=on,icmp=on,ndp=on,ra=on,quiet=off,outbound-if6=${QEMU_PASST_IPV6_IFACE},gateway=${QEMU_PASST_IPV6_GATEWAY},param=--pcap,param=${QEMU_PASST_PCAP_FILE}"
if [[ "$QEMU_PASST_TRACE" == 1 ]]; then QEMU_NETDEV+=",param=--trace"; fi

printf 'IPv6 egress interface: %s\n' "$QEMU_PASST_IPV6_IFACE"
printf 'IPv6 gateway source : %s\n' "$QEMU_PASST_IPV6_GATEWAY"
printf 'Passt PCAP          : %s\n' "$QEMU_PASST_PCAP_FILE"
printf 'Existing ISO and disk images are used as-is; no build or format is performed.\n'

exec "$QEMU_BIN" \
    -machine q35,acpi=on,hpet=on \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE_IMAGE}" \
    -drive "if=pflash,format=raw,unit=1,file=${OVMF_VARS_IMAGE}" \
    -cdrom arkm-uefi-only-test.iso -boot order=d \
    -drive file=hdd.img,format=raw,index=0,media=disk \
    -vga std -m 512 -smp 12 \
    -netdev "$QEMU_NETDEV" \
    -device e1000,netdev=net0,bus=pcie.0,addr=0x3 \
    -no-reboot \
    -serial file:serial.log \
    -d guest_errors,unimp -D qemu.log \
    -drive file=swap.img,format=raw,index=3,media=disk \
    -accel tcg,thread=multi -cpu max \
    -device qemu-xhci,id=arkm-xhci,bus=pcie.0,addr=0x5 \
    -device usb-kbd,bus=arkm-xhci.0,port=1 \
    -device usb-mouse,bus=arkm-xhci.0,port=2 \
    -audiodev driver=none,id=arkm-audio \
    -device intel-hda,id=arkm-hda,bus=pcie.0,addr=0x6 \
    -device hda-duplex,id=arkm-codec,audiodev=arkm-audio \
    -qmp "tcp:127.0.0.1:${QEMU_QMP_PORT},server=on,wait=off" \
    -monitor none
PASST_LAUNCHER
    chmod +x "$ROOT_DIR/run-arkm-passt.sh"
    echo "Generated: $ROOT_DIR/run-arkm-passt.sh"
}

# Default behavior is unchanged except that the helper is refreshed on builds.
# Use GENERATE_PASST_LAUNCHER_ONLY=1 to create it and exit before toolchain checks,
# disk creation/formatting, compilation, or ISO regeneration.
write_passt_launcher
if [[ "$GENERATE_PASST_LAUNCHER_ONLY" == "1" ]]; then
    echo "Launcher-only mode: no build, ISO update, or disk modification performed."
    exit 0
fi


# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SMP_CPUS="${SMP_CPUS:-12}"
RAM_MB="${RAM_MB:-512}"
DISK_MB="${DISK_MB:-32}"
SWAP_DISK_MB="${SWAP_DISK_MB:-8}"
HOST_WEB_PORT="${HOST_WEB_PORT:-8080}"
KERNEL_SOURCE="${KERNEL_SOURCE:-kernel.c}"
RUN_QEMU="${RUN_QEMU:-0}"
# Keep user/production runtime disks untouched unless explicitly requested.
UPDATE_RUNTIME_DISK="${UPDATE_RUNTIME_DISK:-0}"
RUNTIME_DISK_ACTION="preserved"
if [[ "$UPDATE_RUNTIME_DISK" == "1" ]]; then RUNTIME_DISK_ACTION="rebuilt"; fi
PRODUCTION_REQUIRE="${PRODUCTION_REQUIRE:-1}"
QEMU_LOG="${QEMU_LOG:-qemu_log.txt}"
QEMU_SERIAL_LOG="${QEMU_SERIAL_LOG:-qemu_serial.log}"
QEMU_HOST_LOG="${QEMU_HOST_LOG:-qemu_host.log}"
CERT_REPORT="${CERT_REPORT:-arkm_production_report.txt}"
CERT_MANIFEST="${CERT_MANIFEST:-arkm_build_manifest.txt}"
ERROR_REPORT="${ERROR_REPORT:-arkm_error_tracker.txt}"
# Keep low-volume boot diagnostics enabled by default. These flags capture CPU resets,
# guest errors and unimplemented operations without tracing every instruction/IRQ.
# Override QEMU_TRACE_FLAGS for a deeper (potentially much larger) trace.
QEMU_TRACE_FLAGS="${QEMU_TRACE_FLAGS:-cpu_reset,guest_errors,unimp}"
# QEMU virtual-network packet capture is opt-in. Enable it for the IPv6 ping
# diagnosis with: QEMU_NET_CAPTURE=1 ./build.sh
QEMU_NET_CAPTURE="${QEMU_NET_CAPTURE:-0}"
QEMU_NET_CAPTURE_FILE="arkm_net6_diag.pcap"
# Network backends:
#   user  - portable QEMU SLIRP backend (default; preserves existing workflow)
#   tap   - real L2, requires a preconfigured TAP adapter
#   passt - Linux/WSL passt backend, preferred for real host IPv6 egress tests
QEMU_NET_BACKEND="${QEMU_NET_BACKEND:-user}"
QEMU_TAP_IFNAME="${QEMU_TAP_IFNAME:-}"
# For passt, auto-select the interface used by the host IPv6 route to Cloudflare.
# Override with QEMU_PASST_IPV6_IFACE=enP13248p0s0 if autodetection is unsuitable.
QEMU_PASST_IPV6_IFACE="${QEMU_PASST_IPV6_IFACE:-auto}"
QEMU_PASST_IPV6_GATEWAY="${QEMU_PASST_IPV6_GATEWAY:-auto}"
QEMU_PASST_PCAP_FILE="${QEMU_PASST_PCAP_FILE:-arkm_passt_ipv6.pcap}"
QEMU_PASST_TRACE="${QEMU_PASST_TRACE:-1}"
QEMU_PROFILE="${QEMU_PROFILE:-part2}"
# Prefer hardware virtualization when this QEMU build supports it; fall back to multi-threaded TCG.
QEMU_ACCEL="${QEMU_ACCEL:-auto}"
# Watchdogs are deliberately removed for interactive ARKM sessions.
# QEMU runs until the user closes it or the guest/QEMU exits on its own.
# QEMU_TIMEOUT is informational only and is hard-set to zero; environment
# overrides cannot cause the launcher to terminate an interactive session.
QEMU_TIMEOUT=0
QEMU_QMP_PORT="${QEMU_QMP_PORT:-4450}"
# Use a host-appropriate audio backend by default. `none` keeps the emulated
# HDA device present while avoiding Windows-only dsound failures under WSL.
QEMU_AUDIO_DRIVER_DEFAULT="none"
QEMU_HOST_OS_FOR_DEFAULTS="$(uname -s 2>/dev/null || echo unknown)"
case "$QEMU_HOST_OS_FOR_DEFAULTS" in
    MINGW*|MSYS*|CYGWIN*) QEMU_AUDIO_DRIVER_DEFAULT="dsound" ;;
    Darwin*) QEMU_AUDIO_DRIVER_DEFAULT="coreaudio" ;;
esac
QEMU_AUDIO_DRIVER="${QEMU_AUDIO_DRIVER:-$QEMU_AUDIO_DRIVER_DEFAULT}"

# Keep current ARKM output names so existing workflows do not break.
KERNEL_OBJ="kernel.o"
BOOT_OBJ="boot.o"
IDT_OBJ="idt.o"
KERNEL_ELF="arkm.elf"
ISO_IMAGE="${ISO_IMAGE:-arkm-uefi-only-test.iso}"
# Build and validate to a temporary path, then atomically publish the ISO.
# A failed GRUB/ISO build must not erase a previously working UEFI image.
ISO_BUILD_IMAGE="${ISO_IMAGE}.building"
HDD_IMAGE="hdd.img"
SWAP_IMAGE="swap.img"
# One EFI El Torito image; no BIOS El Torito entry is built.
UEFI_ESP_IMAGE="iso/efi.img"
UEFI_ESP_MB="${UEFI_ESP_MB:-16}"
# The UEFI ISO must use the project's patched GRUB 2.14 source tree.
# On MSYS2, GRUB host utilities are built and run inside native Linux WSL;
# the source is staged into WSL /tmp so neither DrvFs nor MinGW host APIs
# affect GRUB's configure/make process.
GRUB_WORK_DIR="${GRUB_WORK_DIR:-$ROOT_DIR/.grub-2.14-relocator-fix-work}"
GRUB_SOURCE_DIR="${GRUB_SOURCE_DIR:-$GRUB_WORK_DIR/grub-2.14}"
GRUB_FONT_SOURCE="${GRUB_FONT_SOURCE:-/usr/share/grub/unicode.pf2}"
# auto = reuse the cached native-Linux GRUB build when its patched inputs match; otherwise build once.
# Set ARKM_REUSE_PATCHED_GRUB=0 to force a clean GRUB rebuild.
ARKM_REUSE_PATCHED_GRUB="${ARKM_REUSE_PATCHED_GRUB:-auto}"
ARKM_WSL_GRUB_CACHE="${ARKM_WSL_GRUB_CACHE:-/tmp/arkm-grub-2.14-relocator-fix}"
ARKM_WSL_DISTRO="${ARKM_WSL_DISTRO:-}"
GRUB_UEFI_MODULES="normal configfile echo halt multiboot2 search search_fs_file iso9660 fat part_gpt part_msdos efi_gop all_video gfxterm font serial terminal terminfo"
# Firmware is staged under project-local names so MSYS2 path conversion does
# not corrupt the paths embedded in comma-separated QEMU -drive arguments.
OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS="${OVMF_VARS:-}"
OVMF_CODE_IMAGE="${OVMF_CODE_IMAGE:-arkm_ovmf_code.fd}"
OVMF_VARS_IMAGE="${OVMF_VARS_IMAGE:-arkm_uefi_vars.fd}"

APP_SRC="app.c"
APP_OBJ="app.o"
APP_ELF="app.elf"
DAEMON_SRC="daemon.c"
DAEMON_OBJ="daemon.o"
DAEMON_ELF="daemon.elf"
WEB_SRC="webserver.c"
WEB_OBJ="webserver.o"
WEB_ELF="web.elf"

COMMON_APP_FLAGS=(
    -target x86_64-unknown-elf
    -ffreestanding
    -O2
    -nostdlib
    -fno-stack-protector
    -fno-pie
    -fno-pic
    -fno-builtin
    -mno-red-zone
)

KERNEL_FLAGS=(
    -target x86_64-unknown-elf
    -ffreestanding
    -O2
    -g
    -fno-omit-frame-pointer
    -Wall
    -Wextra
    -Werror
    -fno-exceptions
    -fno-stack-protector
    -fno-pie
    -fno-pic
    -fno-builtin
    -fno-strict-aliasing
    -mno-mmx
    -mno-sse
    -mno-sse2
    -mno-red-zone
)

APP_STRICT_FLAGS=(
    -Wall
    -Wextra
    -Werror
)

REQUIRED_INTERRUPT_STUBS=(
    timer_stub
    keyboard_stub
    mouse_stub
    syscall_stub
    isr8_stub
    isr13_stub
    isr14_stub
)

# These are the architectural anchors required by the current production
# ARKM design. They are checked in the selected kernel source before compile.
REQUIRED_KERNEL_SYMBOLS=(
    amp_foundation_init
    amp_rebalance_tasks
    amp_dispatch_once
    luna_init
    luna_mount
    luna_self_test
    sys_luna_query
    advanced_kernel_init
    aegis_validate_extended
    validate_user_pointer
    scheduler_tick
    timer_handler
    kernel_main
)

# Current production pass adds this state/command path. We treat it as a
# required source feature when PRODUCTION_REQUIRE=1.
REQUIRED_PRODUCTION_SYMBOLS=(
    arkm_prod_state
    PROD
)

# ----------------------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------------------
log() {
    printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    echo ""
    echo "============================================================"
    echo "ARKM BUILD: FATAL ERROR"
    echo "============================================================"
    echo "$*" >&2
    exit 1
}

trap 'rc=$?; if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then echo ""; echo "ARKM BUILD FAILED (exit ${rc})" >&2; fi; exit "${rc}"' ERR

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "Required file not found: $1"
}

contains_literal() {
    local needle="$1"
    local file="$2"
    grep -Fq "$needle" "$file"
}

check_kernel_symbol() {
    local symbol="$1"
    if ! grep -Eq "(^|[^A-Za-z0-9_])${symbol}([^A-Za-z0-9_]|$)" "$KERNEL_SOURCE"; then
        fail "Production source check failed: missing kernel symbol/anchor '${symbol}' in ${KERNEL_SOURCE}"
    fi
    echo "  PASS  source: ${symbol}"
}

checksum_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    else
        if command -v shasum >/dev/null 2>&1; then
            shasum -a 256 "$1"
        else
            echo "SHA256 unavailable: $1"
        fi
    fi
}


# ----------------------------------------------------------------------------
# OVMF firmware discovery and project-local pflash preparation
# ----------------------------------------------------------------------------
discover_ovmf_pair() {
    local qemu_path qemu_prefix root i code_size vars_size copy_size
    local -a candidate_codes=()
    local -a candidate_vars=()

    if [[ -n "$OVMF_CODE" || -n "$OVMF_VARS" ]]; then
        [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]] || fail "Set both OVMF_CODE and OVMF_VARS, not just one."
        [[ -s "$OVMF_CODE" ]] || fail "OVMF_CODE does not exist or is empty: $OVMF_CODE"
        [[ -s "$OVMF_VARS" ]] || fail "OVMF_VARS does not exist or is empty: $OVMF_VARS"
    else
        qemu_path="$(command -v qemu-system-x86_64)"
        qemu_prefix="$(cd "$(dirname "$qemu_path")/.." 2>/dev/null && pwd || true)"
        # Current MSYS2 QEMU packages carry this matching split firmware pair.
        for root in "${MINGW_PREFIX:-}" "$qemu_prefix" /ucrt64 /mingw64 /usr; do
            [[ -n "$root" ]] || continue
            candidate_codes+=("$root/share/qemu/edk2-x86_64-code.fd")
            candidate_vars+=("$root/share/qemu/edk2-i386-vars.fd")
        done
        candidate_codes+=(
            /usr/share/OVMF/OVMF_CODE.fd
            /usr/share/OVMF/OVMF_CODE_4M.fd
            /usr/share/edk2/ovmf/OVMF_CODE.fd
            /usr/share/edk2/ovmf/OVMF_CODE_4M.fd
            /usr/share/edk2/x64/OVMF_CODE.4m.fd
        )
        candidate_vars+=(
            /usr/share/OVMF/OVMF_VARS.fd
            /usr/share/OVMF/OVMF_VARS_4M.fd
            /usr/share/edk2/ovmf/OVMF_VARS.fd
            /usr/share/edk2/ovmf/OVMF_VARS_4M.fd
            /usr/share/edk2/x64/OVMF_VARS.4m.fd
        )
        candidate_codes+=(/usr/share/qemu/edk2-x86_64-code.fd)
        candidate_vars+=(/usr/share/qemu/edk2-i386-vars.fd)

        for i in "${!candidate_codes[@]}"; do
            if [[ -s "${candidate_codes[$i]}" && -s "${candidate_vars[$i]}" ]]; then
                OVMF_CODE="${candidate_codes[$i]}"
                OVMF_VARS="${candidate_vars[$i]}"
                break
            fi
        done
        [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]] || fail "Cannot find an x86_64 OVMF CODE/VARS pair. On MSYS2 install mingw-w64-ucrt-x86_64-qemu (or mingw-w64-x86_64-qemu), or set OVMF_CODE and OVMF_VARS explicitly."
    fi

    code_size="$(wc -c < "$OVMF_CODE" | tr -d ' ')"
    vars_size="$(wc -c < "$OVMF_VARS" | tr -d ' ')"
    # Split OVMF firmware images are separate pflash devices and are not
    # required to have equal sizes (the VARS store is commonly much smaller).
    cp -f "$OVMF_CODE" "$OVMF_CODE_IMAGE"
    if [[ ! -s "$OVMF_VARS_IMAGE" ]]; then cp "$OVMF_VARS" "$OVMF_VARS_IMAGE"; fi
    copy_size="$(wc -c < "$OVMF_VARS_IMAGE" | tr -d ' ')"
    [[ "$copy_size" == "$vars_size" ]] || fail "Persistent VARS image size ($copy_size) does not match the selected OVMF VARS template ($vars_size). Back up/remove '$OVMF_VARS_IMAGE' to recreate it from the selected template."

    echo "OVMF CODE bytes   : $code_size"
    echo "OVMF VARS bytes   : $vars_size"
    echo "OVMF x86_64 CODE : $OVMF_CODE"
    echo "OVMF VARS template: $OVMF_VARS"
    echo "OVMF CODE image  : $OVMF_CODE_IMAGE"
    echo "OVMF VARS image  : $OVMF_VARS_IMAGE (persistent writable copy)"
}

# ----------------------------------------------------------------------------
# Runtime error tracker
# ----------------------------------------------------------------------------
count_match() {
    local pattern="$1"
    local file="$2"
    [[ -f "$file" ]] || { echo 0; return; }
    grep -ciE "$pattern" "$file" 2>/dev/null || true
}

first_match_line() {
    local pattern="$1"
    local file="$2"
    [[ -f "$file" ]] || return 0
    grep -Einm1 "$pattern" "$file" 2>/dev/null | cut -d: -f1 || true
}

emit_context() {
    local label="$1"
    local file="$2"
    local line="$3"
    local radius="${4:-20}"
    [[ -f "$file" && -n "$line" ]] || return 0
    local start=$((line-radius));
    local end=$((line+radius));
    (( start < 1 )) && start=1
    echo "---- ${label} (${file}:${line}) ----"
    sed -n "${start},${end}p" "$file"
    echo "---- end ${label} ----"
}

resolve_rip() {
    local rip="$1"
    [[ -n "$ADDR2LINE_CMD" && -n "$rip" && -f "$KERNEL_ELF" ]] || return 0
    rip="${rip#0x}"
    rip="${rip#0X}"
    if [[ "$rip" =~ ^[0-9A-Fa-f]+$ ]]; then
        echo "RIP symbol resolution:"
        "$ADDR2LINE_CMD" -e "$KERNEL_ELF" -f -C "0x$rip" 2>/dev/null || true
    fi
}

extract_nearby_rip() {
    local file="$1"
    local line="$2"
    [[ -f "$file" && -n "$line" ]] || return 0
    local start=$((line-30)); (( start < 1 )) && start=1
    local end=$((line+30))
    sed -n "${start},${end}p" "$file" | grep -Eio 'RIP[=:][[:space:]]*0x?[0-9A-Fa-f]{8,16}|EIP[=:][[:space:]]*0x?[0-9A-Fa-f]{1,8}' | head -n 4 | sed -E 's/.*[=:][[:space:]]*//' || true
}

extract_nearby_cr2() {
    local file="$1"
    local line="$2"
    [[ -f "$file" && -n "$line" ]] || return 0
    local start=$((line-30)); (( start < 1 )) && start=1
    local end=$((line+30))
    sed -n "${start},${end}p" "$file" | grep -Eio 'CR2[=:][[:space:]]*0x?[0-9A-Fa-f]{8,16}' | head -n 4 | sed -E 's/.*[=:][[:space:]]*//' || true
}

write_error_tracker() {
    local root_reason="$1"
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    local qemu_faults serial_faults first_qemu first_serial
    local timer_irq keyboard_irq mouse_irq page_irq gp_irq df_irq
    local ap_enter ap_release smp_online
    local luna_pass amp_pass prod_pass

    qemu_faults="$(count_match 'Triple fault|check_exception|guest_errors|qemu: fatal|assertion.*failed|Aborted' "$QEMU_LOG")"
    serial_faults="$(count_match 'EXCEPTION TRAPPED|FATAL MICROKERNEL EXCEPTION|TRIPLE FAULT GUARDRAIL|SYSTEM PANICKED|SYSTEM HALTED|Page fault|General protection|Invalid opcode|Divide error|stack overflow|kernel panic|BUG:' "$QEMU_SERIAL_LOG")"
    first_qemu="$(first_match_line 'check_exception|Triple fault|qemu: fatal|guest_errors|assertion.*failed|Aborted' "$QEMU_LOG")"
    first_serial="$(first_match_line 'EXCEPTION TRAPPED|FATAL MICROKERNEL EXCEPTION|TRIPLE FAULT GUARDRAIL|SYSTEM PANICKED|SYSTEM HALTED|Page fault|General protection|Invalid opcode|Divide error|stack overflow|kernel panic|BUG:' "$QEMU_SERIAL_LOG")"

    timer_irq="$(count_match 'Servicing hardware INT=0x20|hardware INT=0x20|INT=0x20' "$QEMU_LOG")"
    keyboard_irq="$(count_match 'Servicing hardware INT=0x21|hardware INT=0x21|INT=0x21' "$QEMU_LOG")"
    mouse_irq="$(count_match 'Servicing hardware INT=0x2[Cc]|hardware INT=0x2[Cc]|INT=0x2[Cc]' "$QEMU_LOG")"
    page_irq="$(count_match 'INT=0x0[Ee]|check_exception.*0x[eE]|Page Fault' "$QEMU_LOG")"
    gp_irq="$(count_match 'INT=0x0[Dd]|check_exception.*0x[dD]|General Protection' "$QEMU_LOG")"
    df_irq="$(count_match 'INT=0x08|Double Fault|Triple fault' "$QEMU_LOG")"

    ap_enter="$(count_match '\[SMP\][[:space:]]*AP entered ap_main' "$QEMU_SERIAL_LOG")"
    ap_release="$(count_match '\[SMP\][[:space:]]*AP runtime release' "$QEMU_SERIAL_LOG")"
    smp_online="$(count_match '\[SMP\][[:space:]]*all discovered CPUs online' "$QEMU_SERIAL_LOG")"
    luna_pass="$(count_match 'LUNA SELF-TEST: PASS|LUNA.*PASS' "$QEMU_SERIAL_LOG")"
    amp_pass="$(count_match 'AMP.*PASS|AMP FOUNDATION.*READY' "$QEMU_SERIAL_LOG")"
    prod_pass="$(count_match 'PROD.*PASS|PROD TEST.*PASS' "$QEMU_SERIAL_LOG")"

    {
        echo "============================================================"
        echo "                    ARKM ERROR TRACKER"
        echo "============================================================"
        echo "Timestamp UTC       : $now"
        echo "Kernel source       : $KERNEL_SOURCE"
        echo "Kernel ELF          : $KERNEL_ELF"
        echo "QEMU CPUs           : $SMP_CPUS"
echo "QEMU profile        : $QEMU_PROFILE (device profile; firmware is always UEFI)"
        echo "QEMU firmware       : OVMF x86_64 UEFI only"
        echo "QEMU QMP port       : $QEMU_QMP_PORT"
        echo "QEMU timeout        : 0 (watchdog removed)"
        echo "Root reason         : $root_reason"
        echo "QEMU exit code      : $QEMU_EXIT"
        echo "QEMU host output log: $QEMU_HOST_LOG"
        echo "QEMU trace log      : $QEMU_LOG"
        echo ""
        echo "[INTERRUPT DELIVERY]"
        echo "  timer IRQ/vector 0x20 : $timer_irq"
        echo "  keyboard IRQ/vector 0x21 : $keyboard_irq"
        echo "  mouse IRQ/vector 0x2c  : $mouse_irq"
        echo ""
        echo "[SMP EVIDENCE]"
        echo "  AP entered ap_main     : $ap_enter"
        echo "  AP runtime release     : $ap_release"
        echo "  all CPUs online marker : $smp_online"
        echo ""
        echo "[GUEST FAULTS]"
        echo "  serial fatal/exception markers : $serial_faults"
        echo "  page-fault indicators           : $page_irq"
        echo "  GP-fault indicators             : $gp_irq"
        echo "  double/triple fault indicators  : $df_irq"
        echo ""
        echo "[QEMU FAULTS]"
        echo "  QEMU exception/fatal markers : $qemu_faults"
        echo "  CPU resets (diagnostic only)  : $CPU_RESET_COUNT"
        echo ""
        echo "[FEATURE EVIDENCE]"
        echo "  LUNA evidence : $luna_pass"
        echo "  AMP evidence  : $amp_pass"
        echo "  PROD evidence : $prod_pass"
        echo ""
        echo "[PRIMARY DIAGNOSIS]"

        if [[ "$serial_faults" -gt 0 ]]; then
            echo "  CLASS: GUEST_EXCEPTION"
            echo "  The guest emitted an explicit exception/panic marker."
        elif [[ "$qemu_faults" -gt 0 ]]; then
            echo "  CLASS: QEMU_EXCEPTION"
            echo "  QEMU reported an exception/fatal condition."
        elif [[ "$(count_match 'Unimplemented handler.*CMOV' "$QEMU_HOST_LOG")" -gt 0 ]]; then
            echo "  CLASS: QEMU_WHPX_UNIMPLEMENTED_CMOV"
            echo "  QEMU host output reports an unimplemented CMOV handler; inspect the host-output tail above and resolve its RIP against arkm.elf."
        elif [[ ",$QEMU_TRACE_FLAGS," == *,int,* && "$timer_irq" -eq 0 ]]; then
            echo "  CLASS: TIMER_INTERRUPT_MISSING"
            echo "  INT tracing was enabled but no timer-vector 0x20 delivery was observed."
        elif [[ ",$QEMU_TRACE_FLAGS," == *,int,* && "$keyboard_irq" -eq 0 && "$mouse_irq" -eq 0 ]]; then
            echo "  CLASS: LEGACY_INPUT_INTERRUPTS_MISSING"
            echo "  INT tracing was enabled but neither keyboard IRQ1 nor mouse IRQ12 evidence was observed."
        elif [[ ",$QEMU_TRACE_FLAGS," == *,int,* && "$keyboard_irq" -eq 0 ]]; then
            echo "  CLASS: KEYBOARD_INTERRUPT_MISSING"
            echo "  INT tracing was enabled but IRQ1 evidence is absent."
        elif [[ ",$QEMU_TRACE_FLAGS," == *,int,* && "$mouse_irq" -eq 0 ]]; then
            echo "  CLASS: MOUSE_INTERRUPT_MISSING"
            echo "  INT tracing was enabled but IRQ12 evidence is absent."
        elif [[ "$(count_match 'Unimplemented handler' "$QEMU_HOST_LOG")" -gt 0 ]]; then
            echo "  CLASS: QEMU_UNIMPLEMENTED_HANDLER"
            echo "  QEMU wrote an unimplemented-handler diagnostic to its host output log."
        elif [[ ! -s "$QEMU_SERIAL_LOG" && "${KERNEL_ACTIVITY_COUNT:-0}" -eq 0 ]]; then
            echo "  CLASS: NO_GUEST_SERIAL_OR_KERNEL_ACTIVITY"
            echo "  No serial bytes and no observed kernel-range execution records were captured. Check the host-output and QEMU trace tails below to locate the stop point."
        elif [[ "$SMP_CPUS" -gt 1 && "$smp_online" -eq 0 ]]; then
            echo "  CLASS: SMP_BRINGUP_INCOMPLETE"
            echo "  Expected multi-CPU runtime but the all-online marker was not observed."
        elif [[ "$QEMU_EXIT" -eq 124 ]]; then
            echo "  CLASS: QEMU_EXIT_STATUS_124"
            echo "  QEMU returned status 124; no watchdog wrapper is enabled."
        else
            echo "  CLASS: NO_EXPLICIT_FATAL_ERROR"
            echo "  No direct fatal signature was found; inspect interrupt counters and the contexts below."
        fi
        echo ""

        if [[ -n "$first_qemu" ]]; then
            emit_context "FIRST QEMU FAULT CONTEXT" "$QEMU_LOG" "$first_qemu" 24
        fi
        if [[ -n "$first_serial" ]]; then
            emit_context "FIRST GUEST FAULT CONTEXT" "$QEMU_SERIAL_LOG" "$first_serial" 24
        fi

        if [[ -n "$first_qemu" ]]; then
            local rip cr2
            while read -r rip; do
                [[ -n "$rip" ]] || continue
                resolve_rip "$rip"
            done < <(extract_nearby_rip "$QEMU_LOG" "$first_qemu")
            while read -r cr2; do
                [[ -n "$cr2" ]] || continue
                echo "QEMU CR2 (faulting virtual address): 0x${cr2#0x}"
            done < <(extract_nearby_cr2 "$QEMU_LOG" "$first_qemu")
        fi

        if [[ -n "$first_serial" ]]; then
            local srip scr2
            while read -r srip; do
                [[ -n "$srip" ]] || continue
                echo "Guest RIP observed near first serial fault: 0x${srip#0x}"
                resolve_rip "$srip"
            done < <(extract_nearby_rip "$QEMU_SERIAL_LOG" "$first_serial")
            while read -r scr2; do
                [[ -n "$scr2" ]] || continue
                echo "Guest CR2 (faulting virtual address): 0x${scr2#0x}"
            done < <(extract_nearby_cr2 "$QEMU_SERIAL_LOG" "$first_serial")
        fi

        echo "[LAST SERIAL OUTPUT]"
        if [[ -f "$QEMU_SERIAL_LOG" ]]; then
            tail -n 120 "$QEMU_SERIAL_LOG"
        else
            echo "qemu_serial.log not found"
        fi
        echo ""
        echo "[LAST QEMU HOST OUTPUT (WHPX/QEMU stderr/stdout)]"
        if [[ -f "$QEMU_HOST_LOG" ]]; then
            tail -n 100 "$QEMU_HOST_LOG"
        else
            echo "qemu_host.log not found"
        fi
        echo ""
        echo "[LAST QEMU TRACE]"
        if [[ -f "$QEMU_LOG" ]]; then
            tail -n 120 "$QEMU_LOG"
        else
            echo "qemu_log.txt not found"
        fi
        echo "============================================================"
    } > "$ERROR_REPORT"
}

# ----------------------------------------------------------------------------
# Validate configuration
# ----------------------------------------------------------------------------
if ! [[ "$SMP_CPUS" =~ ^[0-9]+$ ]] || [[ "$SMP_CPUS" -lt 1 ]]; then
    fail "SMP_CPUS must be a positive integer."
fi

if ! [[ "$RAM_MB" =~ ^[0-9]+$ ]] || [[ "$RAM_MB" -lt 128 ]]; then
    fail "RAM_MB must be an integer >= 128."
fi

if ! [[ "$DISK_MB" =~ ^[0-9]+$ ]] || [[ "$DISK_MB" -lt 8 ]]; then
    fail "DISK_MB must be an integer >= 8."
fi

if ! [[ "$UEFI_ESP_MB" =~ ^[0-9]+$ ]] || [[ "$UEFI_ESP_MB" -lt 8 ]] || [[ "$UEFI_ESP_MB" -gt 31 ]]; then
    fail "UEFI_ESP_MB must be an integer from 8 through 31 MiB."
fi

if [[ "$QEMU_PROFILE" == "part2" ]]; then
    if ! [[ "$SWAP_DISK_MB" =~ ^[0-9]+$ ]] || [[ "$SWAP_DISK_MB" -lt 1 ]]; then
        fail "SWAP_DISK_MB must be an integer >= 1 for the part2 profile."
    fi
fi

if ! [[ "$RUN_QEMU" =~ ^[01]$ ]]; then
    fail "RUN_QEMU must be 0 or 1."
fi

if ! [[ "$UPDATE_RUNTIME_DISK" =~ ^[01]$ ]]; then
    fail "UPDATE_RUNTIME_DISK must be 0 or 1. Default 0 preserves hdd.img and swap.img."
fi

if ! [[ "$QEMU_NET_CAPTURE" =~ ^[01]$ ]]; then
    fail "QEMU_NET_CAPTURE must be 0 or 1. Use QEMU_NET_CAPTURE=1 to capture QEMU network traffic."
fi

case "$QEMU_NET_BACKEND" in
    user|tap|passt) ;;
    *) fail "QEMU_NET_BACKEND must be user, tap, or passt." ;;
esac
if [[ "$QEMU_NET_BACKEND" == "tap" ]]; then
    if [[ -z "$QEMU_TAP_IFNAME" ]]; then
        fail "QEMU_NET_BACKEND=tap requires QEMU_TAP_IFNAME to name an existing TAP adapter."
    fi
    if [[ "$QEMU_TAP_IFNAME" == *,* ]]; then
        fail "QEMU_TAP_IFNAME must not contain commas (QEMU network option separator)."
    fi
fi
if [[ "$QEMU_NET_BACKEND" == "passt" ]]; then
    if [[ "$QEMU_PASST_TRACE" != "0" && "$QEMU_PASST_TRACE" != "1" ]]; then
        fail "QEMU_PASST_TRACE must be 0 or 1."
    fi
    if [[ -z "$QEMU_PASST_PCAP_FILE" || "$QEMU_PASST_PCAP_FILE" == *,* ]]; then
        fail "QEMU_PASST_PCAP_FILE must be a non-empty path without commas."
    fi
    if [[ "$QEMU_PASST_IPV6_IFACE" == *,* ]]; then
        fail "QEMU_PASST_IPV6_IFACE must not contain commas."
    fi
    if [[ "$QEMU_PASST_IPV6_GATEWAY" == *,* ]]; then
        fail "QEMU_PASST_IPV6_GATEWAY must not contain commas."
    fi
fi

if ! [[ "$PRODUCTION_REQUIRE" =~ ^[01]$ ]]; then
    fail "PRODUCTION_REQUIRE must be 0 or 1."
fi

if ! [[ "$QEMU_TIMEOUT" =~ ^[0-9]+$ ]]; then
    fail "Internal configuration error: QEMU_TIMEOUT must remain 0 because watchdogs are disabled."
fi

case "$QEMU_PROFILE" in
    legacy|part1|part1-hda4|part2)
        ;;
    *)
        fail "QEMU_PROFILE must be one of: legacy, part1, part1-hda4, part2."
        ;;
esac

if ! [[ "$QEMU_QMP_PORT" =~ ^[0-9]+$ ]] || [[ "$QEMU_QMP_PORT" -lt 1024 ]] || [[ "$QEMU_QMP_PORT" -gt 65535 ]]; then
    fail "QEMU_QMP_PORT must be an integer between 1024 and 65535."
fi

# ----------------------------------------------------------------------------
# Toolchain checks
# ----------------------------------------------------------------------------
echo "============================================================"
echo "              ARKM PRODUCTION BUILD SYSTEM"
echo "============================================================"
echo "Root directory       : $ROOT_DIR"
echo "Kernel source        : $KERNEL_SOURCE"
echo "Boot firmware        : UEFI ONLY (patched x86_64 GRUB EFI + OVMF runner)"
echo "QEMU CPUs            : $SMP_CPUS"
echo "QEMU RAM             : ${RAM_MB} MiB"
echo "Disk image           : ${DISK_MB} MiB"
if [[ "$QEMU_PROFILE" == "part2" ]]; then
    echo "Swap disk image      : ${SWAP_DISK_MB} MiB ($SWAP_IMAGE, Q35 AHCI SATA port 2)"
fi
echo "Run QEMU             : $RUN_QEMU"
echo "QEMU net capture     : $QEMU_NET_CAPTURE"
echo "QEMU accelerator     : $QEMU_ACCEL"
echo "QEMU trace flags     : $QEMU_TRACE_FLAGS"
echo "Production source gate: $PRODUCTION_REQUIRE"
echo "QEMU watchdog        : DISABLED (interactive; no timeout wrapper)"
echo "Error tracker        : $ERROR_REPORT"
echo "============================================================"

require_cmd clang
require_cmd ld.lld
require_cmd nm
require_cmd dd
if [[ "$RUN_QEMU" == "1" ]]; then require_cmd qemu-system-x86_64; fi

# Prefer host acceleration for interactive UI latency. If it is not compiled
# into QEMU, use multi-threaded TCG as a safer fallback than single-thread TCG.
QEMU_ACCEL_AUTO_SELECTED=0
if [[ "$QEMU_PROFILE" != "legacy" ]]; then
    if [[ "$QEMU_ACCEL" == "auto" ]]; then
        QEMU_ACCEL_AUTO_SELECTED=1
        QEMU_ACCEL_HELP="$(qemu-system-x86_64 -accel help 2>&1 || true)"
        QEMU_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
        case "$QEMU_HOST_OS" in
            MINGW*|MSYS*|CYGWIN*)
                if grep -Eq '(^|[^[:alnum:]_])whpx([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                    QEMU_ACCEL="whpx"
                else
                    QEMU_ACCEL="tcg,thread=multi"
                fi
                ;;
            Linux*)
                if [[ -r /dev/kvm && -w /dev/kvm ]] && grep -Eq '(^|[^[:alnum:]_])kvm([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                    QEMU_ACCEL="kvm"
                else
                    QEMU_ACCEL="tcg,thread=multi"
                fi
                ;;
            Darwin*)
                if grep -Eq '(^|[^[:alnum:]_])hvf([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                    QEMU_ACCEL="hvf"
                else
                    QEMU_ACCEL="tcg,thread=multi"
                fi
                ;;
            *) QEMU_ACCEL="tcg,thread=multi" ;;
        esac
    fi
    case "$QEMU_ACCEL" in
        whpx|kvm|hvf|tcg|tcg,thread=multi) ;;
        *) fail "Unsupported QEMU_ACCEL='$QEMU_ACCEL'. Use auto, whpx, kvm, hvf, tcg, or tcg,thread=multi." ;;
    esac
    if [[ "$QEMU_ACCEL" != "tcg" && "$QEMU_ACCEL" != "tcg,thread=multi" ]] &&
       ! grep -Eq "(^|[^[:alnum:]_])${QEMU_ACCEL}([^[:alnum:]_]|$)" <<<"$(qemu-system-x86_64 -accel help 2>&1 || true)"; then
        fail "QEMU accelerator '$QEMU_ACCEL' is not available in this QEMU build. Try QEMU_ACCEL=tcg,thread=multi."
    fi
fi

# QEMU supports several -accel entries, trying the next one if the first
# accelerator cannot initialize. Auto mode prefers WHPX/KVM/HVF, then falls
# back to multi-threaded TCG without requiring another user command.
QEMU_ACCEL_ARGS=()
if [[ "$QEMU_ACCEL_AUTO_SELECTED" == "1" && "$QEMU_ACCEL" != "tcg,thread=multi" ]]; then
    QEMU_ACCEL_ARGS+=( -accel "$QEMU_ACCEL" -accel "tcg,thread=multi" )
else
    QEMU_ACCEL_ARGS+=( -accel "$QEMU_ACCEL" )
fi

require_cmd mformat
require_cmd mcopy
require_cmd mmd
if command -v llvm-addr2line >/dev/null 2>&1; then
    ADDR2LINE_CMD="llvm-addr2line"
elif command -v addr2line >/dev/null 2>&1; then
    ADDR2LINE_CMD="addr2line"
else
    ADDR2LINE_CMD=""
fi

if command -v readelf >/dev/null 2>&1; then
    HAVE_READELF=1
else
    HAVE_READELF=0
fi

if command -v grub-file >/dev/null 2>&1; then
    GRUB_FILE_MODE="local"
elif command -v wsl.exe >/dev/null 2>&1 && \
     wsl.exe sh -lc 'command -v grub-file >/dev/null 2>&1'; then
    # In MSYS2, discover the Linux-side command through a WSL shell.
    # Do not probe `grub-file --version`: GRUB 2.14 on this WSL install
    # does not accept that option even though grub-file is fully available.
    GRUB_FILE_MODE="wsl"
else
    GRUB_FILE_MODE="none"
fi

# UEFI boot is built from the patched GRUB source tree used by the
# ARKM relocator/firmware-CR3 work, or reuses the repository's prebuilt
# ARKM-patched iso/EFI/BOOT/BOOTX64.EFI when the GRUB source tree is absent
# (e.g. in CI or a fresh clone). Never fall back to distro GRUB.
ARKM_PREBUILT_GRUB_EFI=0
require_cmd xorriso
if [[ -f "$GRUB_SOURCE_DIR/configure" ]]; then
    require_cmd python3
    if [[ "$(uname -s 2>/dev/null || echo unknown)" == MINGW* ||
          "$(uname -s 2>/dev/null || echo unknown)" == MSYS* ||
          "$(uname -s 2>/dev/null || echo unknown)" == CYGWIN* ]]; then
        require_cmd wsl.exe
        require_cmd cygpath
    else
        for grub_tool in make gcc g++ flex bison; do
            require_cmd "$grub_tool"
        done
    fi
elif [[ -s "$ROOT_DIR/iso/EFI/BOOT/BOOTX64.EFI" ]]; then
    ARKM_PREBUILT_GRUB_EFI=1
    echo "  NOTE  GRUB source tree absent; using prebuilt ARKM-patched iso/EFI/BOOT/BOOTX64.EFI"
else
    fail "Patched GRUB 2.14 source is missing: $GRUB_SOURCE_DIR (and no prebuilt iso/EFI/BOOT/BOOTX64.EFI found)"
fi

require_cmd clang
require_cmd ld.lld
require_cmd nm
require_file "$KERNEL_SOURCE"
require_file "$APP_SRC"
require_file "$DAEMON_SRC"
require_file "$WEB_SRC"
require_file boot.S
require_file idt.s
require_file linker.ld
require_file app_linker.ld

# ----------------------------------------------------------------------------
# 1. Clean build artifacts
# ----------------------------------------------------------------------------
log "[1/12] Cleaning build artifacts"
if [[ "$ARKM_PREBUILT_GRUB_EFI" == "1" ]]; then
    rm -f iso/boot/arkm.elf iso/efi.img
else
    rm -rf iso
fi
rm -f \
    "$BOOT_OBJ" \
    "$IDT_OBJ" \
    "$KERNEL_OBJ" \
    "$KERNEL_ELF" \
    "$ISO_BUILD_IMAGE" \
    "$APP_OBJ" \
    "$APP_ELF" \
    "$DAEMON_OBJ" \
    "$DAEMON_ELF" \
    "$WEB_OBJ" \
    "$WEB_ELF" \
    arkm_state.bin \
    arkm_traffic.pcap \
    "$QEMU_LOG" \
    "$QEMU_SERIAL_LOG" \
    "$QEMU_HOST_LOG" \
    error_report.txt \
    "$ERROR_REPORT" \
    "$CERT_REPORT" \
    "$CERT_MANIFEST"

if [[ "$UPDATE_RUNTIME_DISK" == "1" ]]; then
    rm -f "$HDD_IMAGE" "$SWAP_IMAGE"
fi

# ----------------------------------------------------------------------------
# 2. Source architecture gate
# ----------------------------------------------------------------------------
log "[2/12] Checking ARKM architecture/source gates"

for symbol in "${REQUIRED_KERNEL_SYMBOLS[@]}"; do
    check_kernel_symbol "$symbol"
done

if [[ "$PRODUCTION_REQUIRE" == "1" ]]; then
    for symbol in "${REQUIRED_PRODUCTION_SYMBOLS[@]}"; do
        check_kernel_symbol "$symbol"
    done
fi

# Explicitly verify the three top-level execution personalities.
for feature in "AMP_MODE_HYBRID" "LUNA_ABI_MAJOR" "LUNA_FEATURE_LUNAFS"; do
    if ! contains_literal "$feature" "$KERNEL_SOURCE"; then
        fail "Architecture gate failed: '${feature}' is absent from ${KERNEL_SOURCE}"
    fi
    echo "  PASS  architecture: ${feature}"
done

# ----------------------------------------------------------------------------
# 3. Application binaries
# ----------------------------------------------------------------------------
log "[3/12] Building Ring-3 applications"

clang "${COMMON_APP_FLAGS[@]}" "${APP_STRICT_FLAGS[@]}" \
    -c "$APP_SRC" -o "$APP_OBJ"
ld.lld -m elf_x86_64 "$APP_OBJ" -o "$APP_ELF" -T app_linker.ld

clang "${COMMON_APP_FLAGS[@]}" "${APP_STRICT_FLAGS[@]}" \
    -c "$DAEMON_SRC" -o "$DAEMON_OBJ"
ld.lld -m elf_x86_64 "$DAEMON_OBJ" -o "$DAEMON_ELF" -T app_linker.ld

clang "${COMMON_APP_FLAGS[@]}" "${APP_STRICT_FLAGS[@]}" \
    -c "$WEB_SRC" -o "$WEB_OBJ"
ld.lld -m elf_x86_64 "$WEB_OBJ" -o "$WEB_ELF" -T app_linker.ld

# ----------------------------------------------------------------------------
# 4. Runtime disk handling (safe by default)
# ----------------------------------------------------------------------------
log "[4/12] Runtime disk handling"

if [[ "$UPDATE_RUNTIME_DISK" == "1" ]]; then
    log "Rebuilding FAT32 runtime disk (${DISK_MB} MiB)"
    if ! dd if=/dev/zero of="$HDD_IMAGE" bs=1M count="$DISK_MB" status=none; then
        fail "Unable to create FAT32 disk image."
    fi
    mformat -i "$HDD_IMAGE" -F
    mcopy -i "$HDD_IMAGE" "$APP_ELF" ::/APP.ELF
    mcopy -i "$HDD_IMAGE" "$DAEMON_ELF" ::/DAEMON.ELF
    mcopy -i "$HDD_IMAGE" "$WEB_ELF" ::/WEB.ELF
    dd if=/dev/zero of=arkm_state.bin bs=512 count=1 status=none
    mcopy -i "$HDD_IMAGE" arkm_state.bin ::/STATE.BIN
    rm -f arkm_state.bin

    if [[ "$QEMU_PROFILE" == "part2" ]]; then
        log "Creating dedicated swap disk (${SWAP_DISK_MB} MiB)"
        if ! dd if=/dev/zero of="$SWAP_IMAGE" bs=1M count="$SWAP_DISK_MB" status=none; then
            fail "Unable to create dedicated swap disk image."
        fi
    fi
else
    require_file "$HDD_IMAGE"
    echo "  PRESERVED  $HDD_IMAGE (no reformat/copy performed)"
    if [[ -f "$SWAP_IMAGE" ]]; then
        echo "  PRESERVED  $SWAP_IMAGE (no reformat/copy performed)"
    else
        echo "  NOTE  $SWAP_IMAGE not present; the supplied UEFI-only test runner does not attach swap."
    fi
fi

# ----------------------------------------------------------------------------
# 5. Low-level objects
# ----------------------------------------------------------------------------
log "[5/12] Compiling boot and interrupt objects"

clang \
    -target x86_64-unknown-elf \
    -c boot.S \
    -o "$BOOT_OBJ"

if nm "$BOOT_OBJ" | grep -E \
    ' [Tt] (timer_stub|keyboard_stub|mouse_stub|syscall_stub|isr8_stub|isr13_stub|isr14_stub)$'; then
    fail "boot.o illegally defines an interrupt stub. Stub ownership must remain in idt.o."
fi

echo "  PASS  boot.o owns no interrupt stubs"

clang \
    -target x86_64-unknown-elf \
    -c idt.s \
    -o "$IDT_OBJ"

for symbol in "${REQUIRED_INTERRUPT_STUBS[@]}"; do
    if ! nm "$IDT_OBJ" | grep -qE " [Tt] ${symbol}$"; then
        fail "idt.o is missing interrupt stub: ${symbol}"
    fi
done

echo "  PASS  idt.o owns all seven required interrupt stubs"

# ----------------------------------------------------------------------------
# 6. Kernel compilation
# ----------------------------------------------------------------------------
log "[6/12] Compiling production ARKM kernel"

clang "${KERNEL_FLAGS[@]}" \
    -c "$KERNEL_SOURCE" \
    -o "$KERNEL_OBJ"

# ----------------------------------------------------------------------------
# 7. Kernel link
# ----------------------------------------------------------------------------
log "[7/12] Linking native 64-bit ARKM ELF"

ld.lld \
    -m elf_x86_64 \
    -z max-page-size=4096 \
    -T linker.ld \
    -o "$KERNEL_ELF" \
    "$BOOT_OBJ" \
    "$IDT_OBJ" \
    "$KERNEL_OBJ"

# ----------------------------------------------------------------------------
# 8. ELF + symbol certification
# ----------------------------------------------------------------------------
log "[8/12] Validating ELF architecture and required symbols"

if [[ "$HAVE_READELF" == "1" ]]; then
    ELF_CLASS="$(readelf -h "$KERNEL_ELF" | awk -F: '/Class:/ {gsub(/[[:space:]]+/,"",$2); print $2}')"
    ELF_MACHINE="$(readelf -h "$KERNEL_ELF" | awk -F: '/Machine:/ {sub(/^ +/,"",$2); print $2}')"
    ELF_TYPE="$(readelf -h "$KERNEL_ELF" | awk -F: '/Type:/ {sub(/^ +/,"",$2); print $2}')"
    ELF_ENTRY="$(readelf -h "$KERNEL_ELF" | awk -F: '/Entry point address:/ {sub(/^ +/,"",$2); print $2}')"

    echo "  ELF class   : $ELF_CLASS"
    echo "  ELF machine : $ELF_MACHINE"
    echo "  ELF type    : $ELF_TYPE"
    echo "  ELF entry   : $ELF_ENTRY"

    [[ "$ELF_CLASS" == "ELF64" ]] || fail "Kernel is not ELF64."
    grep -qi 'X86-64' <<<"$ELF_MACHINE" || fail "Kernel is not x86-64."
    [[ -n "$ELF_ENTRY" ]] || fail "Kernel entry address could not be read."
else
    echo "WARNING: readelf unavailable; deep ELF-header certification skipped."
fi

REQUIRED_ELF_SYMBOLS=(
    efi64_start
    arkm_efi_prepare_multiboot2
    _start
    kernel_main
    amp_foundation_init
    amp_dispatch_once
    amp_rebalance_tasks
    luna_init
    luna_self_test
    advanced_kernel_init
    timer_handler
    scheduler_tick
)

for symbol in "${REQUIRED_ELF_SYMBOLS[@]}"; do
    if ! nm "$KERNEL_ELF" | grep -qE " [TtDdBb] ${symbol}$"; then
        fail "Linked ELF is missing required symbol: ${symbol}"
    fi
done

echo "  PASS  linked ELF contains required ARKM/SMP/AMP/LUNA symbols"

# ----------------------------------------------------------------------------
# 9. UEFI-only ISO (patched GRUB 2.14 x86_64 EFI -> Multiboot2 kernel payload)
# ----------------------------------------------------------------------------
log "[9/12] Building UEFI-only ISO with the ARKM-patched GRUB 2.14 tree"

if [[ "$ARKM_PREBUILT_GRUB_EFI" == "0" ]]; then
# Verify the exact relocator/PML4 preservation changes required by the current
# ARKM UEFI handoff. Never substitute the system GRUB binary here.
for grub_file in \
    grub-core/lib/i386/relocator16.S \
    grub-core/lib/i386/relocator32.S \
    grub-core/lib/i386/relocator64.S \
    grub-core/lib/i386/relocator_asm.S \
    grub-core/lib/x86_64/relocator_asm.S; do
    grep -Fq '.section .text.relocator, "awx", %progbits' "$GRUB_SOURCE_DIR/$grub_file" \
        || fail "Missing ARKM writable relocator section in $grub_file"
done
grep -q 'firmware_cr3' "$GRUB_SOURCE_DIR/grub-core/lib/i386/relocator_common_c.c" \
    || fail "Patched GRUB firmware_cr3 preservation change is missing."
grep -q 'grub_memcpy (pt4' "$GRUB_SOURCE_DIR/grub-core/lib/i386/relocator_common_c.c" \
    || fail "Patched GRUB PML4 copy operation is missing."
echo "  PASS  five relocator sections + firmware PML4 preservation verified"

# Apply the console-less EFI multiboot video guard exactly as in the known-good
# ARKM UEFI builder. It is idempotent and writes a backup before changing source.
python3 - "$GRUB_SOURCE_DIR/grub-core/loader/multiboot.c" <<'PYGRUB'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
s = p.read_text()
guard = "if (!accepts_video && !console_required)"
if guard in s:
    print("GRUB no-console video guard already present.")
    raise SystemExit(0)
pattern = re.compile(r"grub_err_t\s+GRUB_MULTIBOOT\s*\(set_video_mode\)\s*\(void\)\s*\{")
matches = list(pattern.finditer(s))
if len(matches) != 1:
    raise SystemExit(f"STOP: expected exactly one set_video_mode function; found {len(matches)}")
start = matches[0].start()
end = s.find("\n}", matches[0].end())
if end < 0:
    raise SystemExit("STOP: cannot locate end of set_video_mode function")
func = s[start:end]
anchor = "  const char *modevar;"
if func.count(anchor) != 1:
    raise SystemExit("STOP: unexpected set_video_mode local-variable layout")
insert = (anchor + "\n\n" +
          "#if !GRUB_MACHINE_HAS_VGA_TEXT\n"
          "  /* Console-less EFI payloads do not require a graphics mode. */\n"
          "  if (!accepts_video && !console_required)\n"
          "    return GRUB_ERR_NONE;\n"
          "#endif")
new_func = func.replace(anchor, insert, 1)
new_s = s[:start] + new_func + s[end:]
if new_s.count(guard) != 1:
    raise SystemExit("STOP: generated GRUB guard failed verification")
backup = p.with_name(p.name + ".pre-arkm-uefi-only")
if not backup.exists():
    backup.write_text(s)
p.write_text(new_s)
print(f"Inserted GRUB no-console video guard: {p}")
PYGRUB

grep -Fq 'if (!accepts_video && !console_required)' "$GRUB_SOURCE_DIR/grub-core/loader/multiboot.c" \
    || fail "GRUB no-console video guard is not present after patching."
fi


mkdir -p iso/EFI/BOOT iso/boot/grub/fonts
cp "$KERNEL_ELF" iso/boot/arkm.elf
# The WSL/Linux GRUB helper copies the Linux-side Unicode font into this tree.

cat > iso/boot/grub/grub.cfg <<'GRUBCFG'
set pager=0
set timeout=0
set default=0

insmod serial
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
echo "ARKM-GRUB-DIAG: configuration loaded; platform=$grub_platform"

if [ "$grub_platform" = "efi" ]; then
    insmod efi_gop
    insmod all_video
    insmod font
    if loadfont unicode; then
        set gfxmode=1280x720x32,1280x720x24,1280x720,auto
        set gfxpayload=keep
        insmod gfxterm
        terminal_output gfxterm serial
        echo "ARKM-GRUB-DIAG: graphics terminal setup attempted"
    else
        echo "ARKM-GRUB-DIAG: FONT_LOAD_FAILED; serial console retained"
        terminal_output console serial
    fi
else
    terminal_output console serial
fi

menuentry "ARKM UEFI-only" {
    echo "ARKM-GRUB-DIAG: menu entry started; locating ELF..."
    if search --no-floppy --file --set=root /boot/arkm.elf; then
        echo "ARKM: ELF found; loading Multiboot2 image..."
        if multiboot2 /boot/arkm.elf; then
            echo "GRUB: Multiboot2 load succeeded; transferring control."
            echo "ARKM-GRUB-DIAG: invoking boot now"
            boot
        else
            echo "GRUB ERROR: multiboot2 rejected the ELF."
            halt
        fi
    else
        echo "GRUB ERROR: cannot find /boot/arkm.elf on ISO."
        halt
    fi
}
GRUBCFG

if [[ "$ARKM_PREBUILT_GRUB_EFI" == "0" ]]; then
# Build/reuse patched x86_64-efi GRUB using a native Linux host toolchain.
# MinGW's configure host is x86_64-w64-mingw32 and its Gnulib build fails on
# reallocarray/other POSIX host APIs. Never compile GRUB host tools with MSYS2.
# On a native Linux build this helper runs locally; on MSYS2 it runs via WSL.
GRUB_LINUX_HELPER="$ROOT_DIR/.arkm-grub-linux-build.${BASHPID}.sh"
cat > "$GRUB_LINUX_HELPER" <<'GRUBLINUX'
#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_IN="$1"
GRUB_CFG="$2"
OUTPUT_EFI="$3"
FONT_COPY_PATH="$4"
FONT_SOURCE="$5"
MODULES="$6"
JOBS="$7"
REUSE="$8"
CACHE_ROOT="${9}"

fail() { printf 'GRUB/WSL BUILD ERROR: %s\n' "$*" >&2; exit 1; }

for cmd in bash make gcc g++ flex bison cp mkdir rm chmod sha256sum awk; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required Linux command is missing: $cmd"
done
[[ -f "$SOURCE_IN/configure" ]] || fail "Patched GRUB configure not found: $SOURCE_IN/configure"
[[ -s "$GRUB_CFG" ]] || fail "GRUB configuration missing: $GRUB_CFG"
[[ -s "$FONT_SOURCE" ]] || fail "Unicode font missing in Linux/WSL: $FONT_SOURCE"
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || fail "JOBS must be a positive integer"
[[ "$REUSE" == auto || "$REUSE" == 0 || "$REUSE" == 1 ]] || fail "REUSE must be auto, 0, or 1"

HOST_TRIPLET="$(gcc -dumpmachine 2>/dev/null || true)"
printf 'GRUB native build host: %s\n' "${HOST_TRIPLET:-unknown}"
case "$HOST_TRIPLET" in
    *mingw*|*w64*|*windows*)
        fail "Refusing Windows/MinGW host compiler '$HOST_TRIPLET'. Build GRUB in WSL/Linux."
        ;;
esac
[[ "$HOST_TRIPLET" == *linux* ]] || fail "Expected a Linux GCC host triplet, got '$HOST_TRIPLET'."

CACHE_ROOT="${CACHE_ROOT%/}"
SRC="$CACHE_ROOT/source"
BUILD="$CACHE_ROOT/build"
PREFIX="$CACHE_ROOT/install"
mkdir -p "$CACHE_ROOT"

# Fingerprint every GRUB source file carrying an ARKM-specific modification.
# This avoids recompiling the complete GRUB host toolchain on every kernel/ISO
# build, while still invalidating the cache when any relocator/firmware/video
# patch or the configure script changes.
FINGERPRINT_FILES=(
    configure
    grub-core/lib/i386/relocator16.S
    grub-core/lib/i386/relocator32.S
    grub-core/lib/i386/relocator64.S
    grub-core/lib/i386/relocator_asm.S
    grub-core/lib/x86_64/relocator_asm.S
    grub-core/lib/i386/relocator_common_c.c
    grub-core/loader/multiboot.c
)
source_fingerprint() {
    local root="$1" rel
    (
        cd "$root" || exit 1
        for rel in "${FINGERPRINT_FILES[@]}"; do
            [[ -s "$rel" ]] || exit 1
            sha256sum "$rel" || exit 1
        done
    ) | sha256sum | awk '{print $1}'
}

CACHE_READY=1
[[ -x "$PREFIX/bin/grub-mkstandalone" && -f "$SRC/configure" ]] || CACHE_READY=0
for mod in multiboot2 relocator serial; do
    [[ -s "$PREFIX/lib/grub/x86_64-efi/$mod.mod" ]] || CACHE_READY=0
done
if [[ "$CACHE_READY" == 1 ]]; then
    INPUT_FINGERPRINT="$(source_fingerprint "$SOURCE_IN")" || CACHE_READY=0
    CACHED_FINGERPRINT="$(source_fingerprint "$SRC")" || CACHE_READY=0
    [[ -n "${INPUT_FINGERPRINT:-}" && "$INPUT_FINGERPRINT" == "${CACHED_FINGERPRINT:-}" ]] || CACHE_READY=0
fi

case "$REUSE" in
    1)
        [[ "$CACHE_READY" == 1 ]] || fail "Requested GRUB cache reuse, but the cached patched sources/tools are missing or stale. Run ARKM_REUSE_PATCHED_GRUB=0 ./build.sh once to refresh it."
        BUILD_GRUB=0
        ;;
    0)
        BUILD_GRUB=1
        ;;
    auto)
        BUILD_GRUB=$((1 - CACHE_READY))
        ;;
esac

if [[ "$BUILD_GRUB" == 0 ]]; then
    printf 'PASS: reusing native Linux patched GRUB cache at %s (source fingerprint matched)\n' "$PREFIX"
else
    printf 'GRUB cache miss or forced refresh: rebuilding patched GRUB once.\n'
    rm -rf "$SRC" "$BUILD" "$PREFIX"
    mkdir -p "$SRC" "$BUILD"
    # Copy out of the MSYS2/DrvFs tree: build on Linux's native filesystem.
    cp -a "$SOURCE_IN/." "$SRC/"
    chmod u+rwX,go+rX "$SRC" "$SRC/configure"

    for f in \
        grub-core/lib/i386/relocator16.S \
        grub-core/lib/i386/relocator32.S \
        grub-core/lib/i386/relocator64.S \
        grub-core/lib/i386/relocator_asm.S \
        grub-core/lib/x86_64/relocator_asm.S; do
        grep -Fq '.section .text.relocator, "awx", %progbits' "$SRC/$f" \
            || fail "Copied source is missing the ARKM relocator patch: $f"
    done
    grep -q 'firmware_cr3' "$SRC/grub-core/lib/i386/relocator_common_c.c" \
        || fail "Copied source is missing firmware_cr3 preservation patch"
    grep -q 'grub_memcpy (pt4' "$SRC/grub-core/lib/i386/relocator_common_c.c" \
        || fail "Copied source is missing firmware PML4 copy patch"
    grep -Fq 'if (!accepts_video && !console_required)' "$SRC/grub-core/loader/multiboot.c" \
        || fail "Copied source is missing the EFI no-console video guard"

    (
        cd "$BUILD"
        # Relative srcdir has no whitespace. GCC/G++ are explicitly native Linux.
        CC=gcc CXX=g++ ../source/configure \
            --with-platform=efi \
            --target=x86_64 \
            --prefix="$PREFIX" \
            --disable-werror
        make -j"$JOBS"
        make install
    )
fi

GRUB_STANDALONE="$PREFIX/bin/grub-mkstandalone"
GRUB_MODDIR="$PREFIX/lib/grub/x86_64-efi"
[[ -x "$GRUB_STANDALONE" ]] || fail "Native Linux grub-mkstandalone was not installed"
for mod in multiboot2 relocator serial; do
    [[ -s "$GRUB_MODDIR/$mod.mod" ]] || fail "Native Linux GRUB module missing: $mod.mod"
done
mkdir -p "$(dirname "$OUTPUT_EFI")" "$(dirname "$FONT_COPY_PATH")"
cp -- "$FONT_SOURCE" "$FONT_COPY_PATH"
"$GRUB_STANDALONE" \
    -O x86_64-efi \
    -d "$GRUB_MODDIR" \
    -o "$OUTPUT_EFI" \
    --modules="$MODULES" \
    "boot/grub/grub.cfg=$GRUB_CFG" \
    "boot/grub/fonts/unicode.pf2=$FONT_SOURCE"
[[ -s "$OUTPUT_EFI" ]] || fail "grub-mkstandalone did not produce the EFI application"
printf 'PASS: native Linux GRUB generated %s (%s bytes)\n' "$OUTPUT_EFI" "$(wc -c < "$OUTPUT_EFI" | tr -d ' ')"
GRUBLINUX

GRUB_STAGE_START_SECONDS=$SECONDS
GRUB_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
if [[ "$GRUB_HOST_OS" == MINGW* || "$GRUB_HOST_OS" == MSYS* || "$GRUB_HOST_OS" == CYGWIN* ]]; then
    # Translate paths only at the MSYS2/WSL boundary. Disable MSYS argument
    # rewriting so /mnt/c/... arguments remain Linux paths, including spaces.
    to_wsl_path() {
        local win_path
        win_path="$(cygpath -aw "$1")" || return 1
        MSYS2_ARG_CONV_EXCL='*' wsl.exe wslpath -u "$win_path" 2>/dev/null | tr -d '\r\n'
    }
    WSL_GRUB_SOURCE="$(to_wsl_path "$GRUB_SOURCE_DIR")" || fail "Cannot translate GRUB source path into WSL."
    WSL_GRUB_HELPER="$(to_wsl_path "$GRUB_LINUX_HELPER")" || fail "Cannot translate Linux GRUB helper path into WSL."
    WSL_GRUB_CFG="$(to_wsl_path "$ROOT_DIR/iso/boot/grub/grub.cfg")" || fail "Cannot translate GRUB config path into WSL."
    WSL_GRUB_EFI="$(to_wsl_path "$ROOT_DIR/iso/EFI/BOOT/BOOTX64.EFI")" || fail "Cannot translate EFI output path into WSL."
    WSL_GRUB_FONT_COPY="$(to_wsl_path "$ROOT_DIR/iso/boot/grub/fonts/unicode.pf2")" || fail "Cannot translate GRUB font destination into WSL."
    [[ -n "$WSL_GRUB_SOURCE" && -n "$WSL_GRUB_HELPER" && -n "$WSL_GRUB_CFG" && -n "$WSL_GRUB_EFI" && -n "$WSL_GRUB_FONT_COPY" ]] \
        || fail "WSL path conversion returned an empty path."

    WSL_ARGS=(--exec bash "$WSL_GRUB_HELPER" \
        "$WSL_GRUB_SOURCE" "$WSL_GRUB_CFG" "$WSL_GRUB_EFI" \
        "$WSL_GRUB_FONT_COPY" "$GRUB_FONT_SOURCE" "$GRUB_UEFI_MODULES" "${JOBS:-2}" \
        "$ARKM_REUSE_PATCHED_GRUB" "$ARKM_WSL_GRUB_CACHE")
    if [[ -n "$ARKM_WSL_DISTRO" ]]; then
        WSL_ARGS=(-d "$ARKM_WSL_DISTRO" "${WSL_ARGS[@]}")
    fi
    echo "  GRUB host build: WSL native Linux (not MSYS2/MinGW)"
    if ! MSYS2_ARG_CONV_EXCL='*' wsl.exe "${WSL_ARGS[@]}"; then
        fail "Patched GRUB build failed inside WSL. Inspect the GRUB configure/make error above; ARKM kernel compilation already passed."
    fi
else
    echo "  GRUB host build: native Linux"
    if ! bash "$GRUB_LINUX_HELPER" \
        "$GRUB_SOURCE_DIR" "$ROOT_DIR/iso/boot/grub/grub.cfg" \
        "$ROOT_DIR/iso/EFI/BOOT/BOOTX64.EFI" "$ROOT_DIR/iso/boot/grub/fonts/unicode.pf2" \
        "$GRUB_FONT_SOURCE" "$GRUB_UEFI_MODULES" "${JOBS:-2}" \
        "$ARKM_REUSE_PATCHED_GRUB" "$ARKM_WSL_GRUB_CACHE"; then
        fail "Patched GRUB native Linux build failed."
    fi
fi
rm -f "$GRUB_LINUX_HELPER"
[[ -s iso/EFI/BOOT/BOOTX64.EFI ]] || fail "UEFI BOOTX64.EFI was not generated by the Linux GRUB builder."
printf '[TIMING] Patched GRUB configure/build/package stage: %ss (cache mode=%s)\n' "$((SECONDS - GRUB_STAGE_START_SECONDS))" "$ARKM_REUSE_PATCHED_GRUB"
else
    echo "  REUSE  prebuilt ARKM-patched iso/EFI/BOOT/BOOTX64.EFI"
fi


# BOOTX64.EFI was generated by native Linux grub-mkstandalone above.
[[ -s iso/EFI/BOOT/BOOTX64.EFI ]] || fail "UEFI EFI application is missing before ESP packaging."

# This is the same 16 MiB FAT EFI image and single-entry El Torito layout used
# by build-arkm-uefi-permanent.sh. No i386-pc/BIOS boot image is emitted.
dd if=/dev/zero of="$UEFI_ESP_IMAGE" bs=1M count="$UEFI_ESP_MB" status=none
mformat -i "$UEFI_ESP_IMAGE" ::
mmd -i "$UEFI_ESP_IMAGE" ::/EFI
mmd -i "$UEFI_ESP_IMAGE" ::/EFI/BOOT
mcopy -i "$UEFI_ESP_IMAGE" iso/EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

xorriso -as mkisofs \
    -R -J -V ARKM_UEFI_ONLY \
    -o "$ISO_BUILD_IMAGE" \
    -eltorito-alt-boot -e efi.img -no-emul-boot \
    iso

# Explicitly reject any BIOS boot image in the temporary ISO catalog before
# replacing the last known-good output image.
UEFI_ELTORITO_REPORT="$(xorriso -indev "$ISO_BUILD_IMAGE" -report_el_torito as_mkisofs 2>&1)" \
    || fail "xorriso could not inspect generated UEFI ISO."
grep -Eq '(^|[[:space:]])-e([[:space:]]|$)' <<<"$UEFI_ELTORITO_REPORT" \
    || fail "Generated ISO has no EFI El Torito image."
if grep -Eq '(^|[[:space:]])-b([[:space:]]|$)' <<<"$UEFI_ELTORITO_REPORT"; then
    fail "Generated ISO contains a BIOS El Torito entry; UEFI-only requirement violated."
fi
printf '%s\n' "$UEFI_ELTORITO_REPORT" > arkm_uefi_only_el_torito_report.txt
echo "  PASS  UEFI-only El Torito catalog: EFI entry found; BIOS entry absent"

validate_uefi_pe() {
    local file="$1" py=""
    if command -v python >/dev/null 2>&1; then py="python"
    elif command -v python3 >/dev/null 2>&1; then py="python3"
    else return 127
    fi
    "$py" - "$file" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
if len(data) < 0x40 or data[:2] != b"MZ":
    raise SystemExit("EFI loader is not a PE image")
pe = struct.unpack_from("<I", data, 0x3C)[0]
if pe + 0x1A > len(data) or data[pe:pe+4] != b"PE\0\0":
    raise SystemExit("EFI loader has an invalid PE signature")
machine = struct.unpack_from("<H", data, pe+4)[0]
magic = struct.unpack_from("<H", data, pe+24)[0]
if machine != 0x8664 or magic != 0x20B:
    raise SystemExit(f"EFI loader is not x86_64 PE32+ (machine=0x{machine:04x}, magic=0x{magic:04x})")
print(f"x86_64 PE32+ EFI application OK: {path} ({len(data)} bytes)")
PY
}

validate_uefi_el_torito() {
    local file="$1" py=""
    if command -v python >/dev/null 2>&1; then py="python"
    elif command -v python3 >/dev/null 2>&1; then py="python3"
    else return 127
    fi
    "$py" - "$file" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
sector = 2048
catalog_lba = None
for lba in range(16, min(len(data)//sector, 80)):
    vd = data[lba*sector:(lba+1)*sector]
    if len(vd) == sector and vd[0] == 0 and vd[1:6] == b"CD001" and b"EL TORITO SPECIFICATION" in vd[7:39]:
        catalog_lba = struct.unpack_from("<I", vd, 71)[0]
        break
if catalog_lba is None:
    raise SystemExit("ISO has no El Torito boot record")
cat = data[catalog_lba*sector:(catalog_lba+1)*sector]
if len(cat) < 64 or cat[0] != 1 or cat[30:32] != b"\x55\xaa":
    raise SystemExit("Malformed El Torito validation entry")
platform, boot, media = cat[1], cat[32], cat[33] & 0x0F
if platform != 0xEF:
    raise SystemExit(f"El Torito platform is not EFI: 0x{platform:02x}")
if boot != 0x88 or media != 0:
    raise SystemExit(f"EFI boot entry is not bootable/no-emulation (indicator=0x{boot:02x}, media={media})")
print(f"UEFI El Torito catalog OK: platform=EFI(0x{platform:02x}), no-emulation, catalog LBA={catalog_lba}")
PY
}

validate_uefi_pe iso/EFI/BOOT/BOOTX64.EFI || fail "UEFI EFI application validation failed (requires python or python3)."
echo "  PASS  UEFI EFI application: x86_64 PE32+ verified"

validate_multiboot2_embedded() {
    local file="$1"
    local py=""

    if command -v python >/dev/null 2>&1; then
        py="python"
    elif command -v python3 >/dev/null 2>&1; then
        py="python3"
    else
        return 127
    fi

    "$py" - "$file" <<'PY'
import struct
import sys

path = sys.argv[1]
MAGIC = 0xE85250D6
MAX_SCAN = 32768

with open(path, "rb") as f:
    data = f.read(MAX_SCAN)

for off in range(0, max(0, len(data) - 16 + 1), 8):
    magic, architecture, header_length, checksum = struct.unpack_from("<IIII", data, off)
    if magic != MAGIC:
        continue

    if ((magic + architecture + header_length + checksum) & 0xFFFFFFFF) != 0:
        print(f"invalid Multiboot2 checksum at file offset 0x{off:x}")
        sys.exit(1)

    if architecture != 0:
        print(f"unsupported Multiboot2 architecture field: {architecture}")
        sys.exit(1)

    if header_length < 16 or (header_length % 8) != 0 or off + header_length > len(data):
        print(f"invalid Multiboot2 header length: {header_length}")
        sys.exit(1)

    pos = off + 16
    end = off + header_length
    found_end_tag = False

    while pos < end:
        tag_type, tag_size = struct.unpack_from("<II", data, pos)
        if tag_size < 8 or (tag_size % 8) != 0 or pos + tag_size > end:
            print(f"invalid Multiboot2 tag at file offset 0x{pos:x}")
            sys.exit(1)

        if tag_type == 0:
            if tag_size != 8 or pos + tag_size != end:
                print("invalid Multiboot2 end tag")
                sys.exit(1)
            found_end_tag = True
            break

        pos += tag_size

    if not found_end_tag:
        print("Multiboot2 end tag missing")
        sys.exit(1)

    print(
        f"Multiboot2 embedded header OK: offset=0x{off:x} "
        f"length={header_length} architecture={architecture}"
    )
    sys.exit(0)

print("Multiboot2 magic not found within first 32768 bytes")
sys.exit(1)
PY
}

if [[ "$GRUB_FILE_MODE" == "local" ]]; then
    grub-file --is-x86-multiboot2 "$KERNEL_ELF"
    echo "  PASS  Multiboot2 kernel payload header: OK (grub-file/local)"
elif [[ "$GRUB_FILE_MODE" == "wsl" ]]; then
    # WSL command-line argument translation can be unreliable from MSYS2,
    # especially for paths containing spaces.  Do not invoke grub-file with
    # an empty/mis-translated path.  The embedded validator remains the
    # deterministic fallback and is a real Multiboot2 header check.
    WSL_KERNEL_PATH=""
    if command -v cygpath >/dev/null 2>&1; then
        WINDOWS_KERNEL_PATH="$(cygpath -aw "$KERNEL_ELF" 2>/dev/null || true)"
        if [[ -n "$WINDOWS_KERNEL_PATH" ]]; then
            WSL_KERNEL_PATH="$(wsl.exe wslpath -u "$WINDOWS_KERNEL_PATH" 2>/dev/null | tr -d '\r\n' || true)"
        fi
    fi

    if [[ -n "$WSL_KERNEL_PATH" ]]; then
        # Build one shell command so the Linux path is passed intact to the
        # WSL shell even when the project path contains spaces.
        WSL_GRUB_CMD="grub-file --is-x86-multiboot2 $(printf '%q' "$WSL_KERNEL_PATH")"
    else
        WSL_GRUB_CMD=""
    fi

    if [[ -n "$WSL_GRUB_CMD" ]] && wsl.exe sh -lc "$WSL_GRUB_CMD" >/dev/null 2>&1; then
        echo "  PASS  Multiboot2 kernel payload header: OK (grub-file/WSL)"
    elif validate_multiboot2_embedded "$KERNEL_ELF"; then
        echo "  PASS  Multiboot2 kernel payload header: OK (embedded structural validation)"
    else
        fail "Multiboot2 validation failed: both WSL grub-file and embedded header validation failed."
    fi
else
    if validate_multiboot2_embedded "$KERNEL_ELF"; then
        echo "  PASS  Multiboot2 kernel payload header: OK (embedded structural validation; grub-file unavailable)"
    else
        fail "grub-file unavailable and embedded Multiboot2 header validation failed."
    fi
fi

# Publish only after the UEFI PE, El Torito catalog, and kernel Multiboot2
# payload have all passed validation. A failed build preserves the previous ISO.
mv -f "$ISO_BUILD_IMAGE" "$ISO_IMAGE"
echo "  PASS  UEFI-only ISO: EFI El Torito platform 0xEF; no BIOS entry requested"
echo "  PUBLISHED  $ISO_IMAGE (previous ISO preserved until validation completed)"

# The UEFI ISO can be built without a local firmware package, but a real QEMU
# launch must stage the OVMF firmware now, before the build manifest is written.
if [[ "$RUN_QEMU" == "1" ]]; then
    discover_ovmf_pair
fi

# ----------------------------------------------------------------------------
# 10. Build manifest
# ----------------------------------------------------------------------------
log "[10/12] Writing build manifest"
{
    echo "ARKM PRODUCTION BUILD MANIFEST"
    echo "================================"
    echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "root=$ROOT_DIR"
    echo "kernel_source=$KERNEL_SOURCE"
    echo "smp_cpus=$SMP_CPUS"
    echo "ram_mb=$RAM_MB"
    echo "disk_mb=$DISK_MB"
    echo "update_runtime_disk=$UPDATE_RUNTIME_DISK"
    echo "runtime_disk_action=$RUNTIME_DISK_ACTION"
    if [[ "$QEMU_PROFILE" == "part2" ]]; then
        echo "swap_disk_mb=$SWAP_DISK_MB"
        echo "swap_image=$SWAP_IMAGE"
    else
        echo "swap_disk_mb=0"
        echo "swap_image=none"
    fi
    echo "production_require=$PRODUCTION_REQUIRE"
    echo "boot_firmware_mode=UEFI_ONLY"
    echo "uefi_esp_image=$UEFI_ESP_IMAGE"
    echo "uefi_application=iso/EFI/BOOT/BOOTX64.EFI"
    echo "ovmf_code_image=$OVMF_CODE_IMAGE"
    echo "ovmf_vars_image=$OVMF_VARS_IMAGE"
    echo "qemu_profile=$QEMU_PROFILE"
    echo "qemu_accel_preference=$QEMU_ACCEL"
    echo "qemu_qmp_port=$QEMU_QMP_PORT"
    echo "qemu_net_capture=$QEMU_NET_CAPTURE"
    echo "qemu_net_capture_file=$QEMU_NET_CAPTURE_FILE"
    echo ""
    echo "FILES / SHA256"
    checksum_file "$KERNEL_SOURCE"
    checksum_file "$KERNEL_ELF"
    checksum_file "$ISO_IMAGE"
    checksum_file "$UEFI_ESP_IMAGE"
    checksum_file "iso/EFI/BOOT/BOOTX64.EFI"
    checksum_file "$HDD_IMAGE"
    if [[ -f "$OVMF_CODE_IMAGE" ]]; then checksum_file "$OVMF_CODE_IMAGE"; fi
    if [[ -f "$OVMF_VARS_IMAGE" ]]; then checksum_file "$OVMF_VARS_IMAGE"; fi
    checksum_file "$APP_ELF"
    checksum_file "$DAEMON_ELF"
    checksum_file "$WEB_ELF"
    echo ""
    echo "REQUIRED ARCHITECTURE"
    printf '%s\n' "${REQUIRED_KERNEL_SYMBOLS[@]}"
    echo ""
    echo "PRODUCTION NOTE"
    echo "This manifest proves the selected source was compiled, linked and packaged."
    echo "It does not by itself prove runtime certification of every production gate."
} > "$CERT_MANIFEST"

# ----------------------------------------------------------------------------
# 11. QEMU runtime / diagnostics
# ----------------------------------------------------------------------------
BOOT_RESULT="NOT_RUN"
QEMU_EXIT=0
CPU_RESET_COUNT=0
TRIPLE_FAULT_COUNT=0
EXCEPTION_COUNT=0
KERNEL_ACTIVITY_COUNT=0
GUEST_FATAL_COUNT=0
QEMU_FATAL_COUNT=0

if [[ "$RUN_QEMU" == "1" ]]; then
    # No SeaBIOS fallback is permitted: OVMF was staged before the manifest.
    if [[ "$QEMU_NET_BACKEND" == "passt" ]]; then
        QEMU_NET_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
        [[ "$QEMU_NET_HOST_OS" == "Linux" ]] || fail "QEMU_NET_BACKEND=passt requires Linux/WSL; use QEMU_NET_BACKEND=user in MSYS2/Windows."
        require_cmd ip
        require_cmd passt
        QEMU_PASST_HELP="$(qemu-system-x86_64 -netdev help 2>&1 || true)"
        grep -Eq '(^|[^[:alnum:]_])passt([^[:alnum:]_]|$)' <<<"$QEMU_PASST_HELP" || fail "This QEMU build does not support the passt netdev."
        if [[ "$QEMU_PASST_IPV6_IFACE" == "auto" ]]; then
            QEMU_PASST_ROUTE="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)"
            QEMU_PASST_IPV6_IFACE="$(sed -nE 's/.*(^|[[:space:]])dev[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$QEMU_PASST_ROUTE" | head -n 1)"
            # The first sed expression above is intentionally followed by a
            # conservative fallback for iproute2 output with a leading route token.
            if [[ -z "$QEMU_PASST_IPV6_IFACE" ]]; then
                QEMU_PASST_IPV6_IFACE="$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$QEMU_PASST_ROUTE")"
            fi
        fi
        [[ -n "$QEMU_PASST_IPV6_IFACE" && "$QEMU_PASST_IPV6_IFACE" != "auto" ]] || fail "Could not determine host IPv6 egress interface. Set QEMU_PASST_IPV6_IFACE explicitly (e.g. enP13248p0s0)."
        ip link show dev "$QEMU_PASST_IPV6_IFACE" >/dev/null 2>&1 || fail "IPv6 egress interface does not exist: $QEMU_PASST_IPV6_IFACE"
        if [[ "$QEMU_PASST_IPV6_GATEWAY" == "auto" ]]; then
            QEMU_PASST_ROUTE6="$(ip -6 route show default dev "$QEMU_PASST_IPV6_IFACE" 2>/dev/null | head -n 1)"
            QEMU_PASST_IPV6_GATEWAY="$(awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$QEMU_PASST_ROUTE6")"
        fi
        [[ -n "$QEMU_PASST_IPV6_GATEWAY" && "$QEMU_PASST_IPV6_GATEWAY" != "auto" ]] || fail "Could not determine IPv6 default gateway on $QEMU_PASST_IPV6_IFACE. Set QEMU_PASST_IPV6_GATEWAY explicitly."
        echo "  passt IPv6 egress  : $QEMU_PASST_IPV6_IFACE"
        echo "  passt IPv6 gateway : $QEMU_PASST_IPV6_GATEWAY"
        echo "  passt PCAP         : $QEMU_PASST_PCAP_FILE"
    fi
    log "[11/12] Launching ARKM in QEMU"

    echo ""
    echo "QEMU configuration:"
    echo "  CPUs              : $SMP_CPUS"
    echo "  Memory            : ${RAM_MB} MiB"
    echo "  Firmware          : OVMF x86_64 (UEFI only; SeaBIOS disabled)"
    echo "  OVMF CODE image   : $OVMF_CODE_IMAGE"
    echo "  OVMF VARS image   : $OVMF_VARS_IMAGE"
    echo "  VGA               : StdVGA EDID preference 1280x720"
    if [[ "$QEMU_NET_BACKEND" == "user" ]]; then
        echo "  Host port         : ${HOST_WEB_PORT} -> guest 80"
    else
        echo "  Host port         : no user-mode hostfwd (use guest network address)"
    fi
    echo "  Network backend   : $QEMU_NET_BACKEND"
    if [[ "$QEMU_NET_BACKEND" == "tap" ]]; then
        echo "  TAP adapter       : $QEMU_TAP_IFNAME"
    elif [[ "$QEMU_NET_BACKEND" == "passt" ]]; then
        echo "  passt IPv6 egress : $QEMU_PASST_IPV6_IFACE"
        echo "  passt IPv6 gateway: $QEMU_PASST_IPV6_GATEWAY"
        echo "  passt PCAP        : $QEMU_PASST_PCAP_FILE"
        echo "  passt trace       : $QEMU_PASST_TRACE"
    fi
    echo "  Kernel source     : $KERNEL_SOURCE"
    echo "  Kernel SMP        : retained"
    echo "  AMP foundation    : required"
    echo "  LUNA architecture : retained"
    echo "  POSIX layer       : retained"
    echo "  Production source : $PRODUCTION_REQUIRE"
    echo "  QEMU timeout      : 0 (watchdog removed)"
    echo "  QEMU net capture  : $QEMU_NET_CAPTURE"
    echo "  QEMU profile      : $QEMU_PROFILE"
    if [[ "$QEMU_PROFILE" != "legacy" ]]; then
        echo "  QEMU acceleration : $QEMU_ACCEL"
        echo "  QEMU trace flags  : $QEMU_TRACE_FLAGS"
    fi
    if [[ "$QEMU_PROFILE" == "part2" ]]; then
        echo "  Swap disk         : ${SWAP_DISK_MB} MiB at Q35 AHCI SATA port 2"
    fi
    if [[ "$QEMU_PROFILE" != "legacy" ]]; then
        case "$QEMU_NET_BACKEND" in
            user) echo "  DNS / DHCP        : QEMU user network (10.0.2.0/24; DNS 10.0.2.3; IPv6 fec0::/64)" ;;
            tap) echo "  DNS / DHCP        : supplied by the bridged physical network (if available)" ;;
            passt) echo "  DNS / DHCP        : passt virtual DHCP + IPv6 RA/NDP (host-backed)" ;;
        esac
        echo "  Audio backend     : $QEMU_AUDIO_DRIVER"
        echo "  QEMU QMP port     : $QEMU_QMP_PORT"
    fi

    case "$QEMU_PROFILE" in
        legacy)
            echo "  Devices           : E1000 (E1000-only device profile; still UEFI boot)"
            ;;
        part1)
            echo "  Devices           : E1000 + xHCI + USB keyboard/mouse + Intel HDA"
            echo "  PCI layout        : E1000=00:03.0 xHCI=00:05.0 HDA=00:06.0"
            ;;
        part1-hda4)
            echo "  Devices           : E1000 + xHCI + USB keyboard/mouse + Intel HDA"
            echo "  PCI layout        : E1000=00:03.0 HDA=00:04.0 xHCI=00:05.0"
            ;;
        part2)
            echo "  Devices           : E1000 + xHCI + USB keyboard/mouse + Intel HDA + dedicated swap disk"
            echo "  PCI layout        : ICH9 AHCI=00:1f.2; E1000=00:03.0 xHCI=00:05.0 HDA=00:06.0; swap=SATA port 2"
            ;;
    esac

    echo ""
    echo "Guest manual certification sequence after boot:"
    echo "  SMP"
    echo "  AMP"
    echo "  LUNA"
    echo "  LUNA TEST"
    echo "  LUNA LS"
    echo "  PROD"
    echo "  PROD TEST"
    if [[ "$QEMU_PROFILE" != "legacy" ]]; then
        echo "  ARKM PCI MCFG"
        echo "  ARKM PCI TARGETS"
        echo "  ARKM PCI PART1"
        echo "  ARKM USB DEBUG"
        echo "  ARKM USB ENUM"
        echo "  ARKM USB HID"
        echo "  ARKM AUDIO"
        echo "  ARKM AUDIO PLAY"
        echo "  ARKM AUDIO STOP"
        echo "  ARKM DHCP"
        echo "  ARKM DNS google.com"
        echo "  ARKM NET6 STATUS"
        echo "  ARKM NET6 RS"
        echo "  ARKM NET6 PING"
        if [[ "$QEMU_PROFILE" == "part2" ]]; then
            echo "  ARKM SWAP STATUS"
            echo "  ARKM SWAP TEST"
            echo "  ARKM RECLAIM TEST"
        fi
    fi
    echo ""
    echo "Runtime diagnosis is written to: $ERROR_REPORT"
    echo "Separate UEFI QEMU runner   : ./run-arkm-uefi-only-qemu.sh"
    echo "QEMU host output is written to: $QEMU_HOST_LOG"
    echo "QEMU trace is written to: $QEMU_LOG"
    echo ""

    # Fail early if this QEMU build lacks one of the emulated devices required
    # by Part 1. This prevents a launch error from being mistaken for a guest
    # driver failure.
    if [[ "$QEMU_PROFILE" != "legacy" ]]; then
        QEMU_DEVICE_HELP="$(qemu-system-x86_64 -device help 2>&1 || true)"
        for required_device in qemu-xhci usb-kbd usb-mouse intel-hda hda-duplex e1000; do
            if ! grep -Fq "$required_device" <<<"$QEMU_DEVICE_HELP"; then
                fail "QEMU profile '$QEMU_PROFILE' requires device model '$required_device', but it was not listed by qemu-system-x86_64 -device help."
            fi
        done
    fi

    # Select the network backend.  "user" remains the default, preserving
    # the existing deterministic IPv4/DNS workflow.  TAP is an opt-in layer-2
    # path for real-router IPv6 RA/SLAAC/routing tests; the host TAP adapter
    # must already be installed and attached to a suitable network/bridge.
    if [[ "$QEMU_NET_BACKEND" == "tap" ]]; then
        QEMU_NETDEV="tap,id=net0,ifname=${QEMU_TAP_IFNAME},script=no,downscript=no"
    elif [[ "$QEMU_NET_BACKEND" == "passt" ]]; then
        # Use the real WSL/Linux host IPv6 egress interface. This avoids the
        # previous hard-coded eth0 assumption (the detected WSL interface here
        # is enP13248p0s0). Enable ICMP explicitly for the guest echo diagnostic.
        QEMU_NETDEV="passt,id=net0,ipv4=on,ipv6=on,icmp=on,ndp=on,ra=on,quiet=off,outbound-if6=${QEMU_PASST_IPV6_IFACE},gateway=${QEMU_PASST_IPV6_GATEWAY},param=--pcap,param=${QEMU_PASST_PCAP_FILE}"
        if [[ "$QEMU_PASST_TRACE" == "1" ]]; then
            QEMU_NETDEV+=",param=--trace"
        fi
    elif [[ "$QEMU_PROFILE" == "legacy" ]]; then
        QEMU_NETDEV="user,id=net0,hostfwd=tcp::${HOST_WEB_PORT}-:80"
    else
        QEMU_NETDEV="user,id=net0,ipv4=on,ipv6=on,net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15,dns=10.0.2.3,ipv6-prefix=fec0::,ipv6-prefixlen=64,ipv6-host=fec0::2,ipv6-dns=fec0::3,hostfwd=tcp::${HOST_WEB_PORT}-:80"
    fi

    # OVMF CODE + writable VARS force UEFI for all device profiles. The ISO
    # itself contains a single EFI El Torito boot entry and no BIOS entry.
    QEMU_ARGS=(
        -machine q35,acpi=on,hpet=on
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE_IMAGE}"
        -drive "if=pflash,format=raw,unit=1,file=${OVMF_VARS_IMAGE}"
        -drive "if=none,id=arkm_uefi_iso,file=$ISO_IMAGE,format=raw,media=cdrom,readonly=on"
        -device "ide-cd,drive=arkm_uefi_iso,bus=ide.1"
        -boot order=d
        -drive "if=none,id=arkm_system_disk,file=$HDD_IMAGE,format=raw"
        # Q35 provides the ICH9 AHCI controller at 00:1f.2. ide.0 is its
        # first SATA port; ide-hd is the disk endpoint, not a legacy IDE controller.
        -device "ide-hd,drive=arkm_system_disk,bus=ide.0"
        -device VGA,edid=on,xres=1280,yres=720
        -m "$RAM_MB"
        -smp "$SMP_CPUS"
        -netdev "$QEMU_NETDEV"
    )

    # Capture the QEMU virtual NIC's packets only when explicitly requested.
    # filter-dump writes a libpcap file readable by Wireshark/tcpdump.
    if [[ "$QEMU_NET_CAPTURE" == "1" ]]; then
        rm -f "$QEMU_NET_CAPTURE_FILE"
        QEMU_ARGS+=(
            -object "filter-dump,id=arkm_net6_capture,netdev=net0,file=${QEMU_NET_CAPTURE_FILE}"
        )
    fi

    QEMU_ARGS+=(
        -device "e1000,netdev=net0,bus=pcie.0,addr=0x3"
        -no-reboot
        -serial "file:${QEMU_SERIAL_LOG}"
    )

    # Trace logging can significantly slow a software-emulated guest. Keep it
    # disabled by default; opt in with QEMU_TRACE_FLAGS when debugging.
    if [[ -n "$QEMU_TRACE_FLAGS" ]]; then
        QEMU_ARGS+=( -d "$QEMU_TRACE_FLAGS" -D "$QEMU_LOG" )
    fi

    if [[ "$QEMU_PROFILE" == "part2" ]]; then
        # Q35 ICH9 AHCI port 2 is the dedicated swap disk. SATA port 0
        # holds the system disk and port 1 holds the UEFI optical image.
        QEMU_ARGS+=(
            -drive "if=none,id=arkm_swap_disk,file=$SWAP_IMAGE,format=raw"
            -device "ide-hd,drive=arkm_swap_disk,bus=ide.2"
        )
    fi

    case "$QEMU_PROFILE" in
        legacy)
            QEMU_ARGS+=(
                -monitor stdio
            )
            ;;
        part1|part2)
            QEMU_ARGS+=(
                "${QEMU_ACCEL_ARGS[@]}"
                -cpu max
                -device "qemu-xhci,id=arkm-xhci,bus=pcie.0,addr=0x5"
                -device "usb-kbd,bus=arkm-xhci.0,port=1"
                -device "usb-mouse,bus=arkm-xhci.0,port=2"
                -audiodev "driver=${QEMU_AUDIO_DRIVER},id=arkm-audio,out.frequency=48000,out.channels=2,out.format=s16"
                -device "intel-hda,id=arkm-hda,bus=pcie.0,addr=0x6"
                -device "hda-duplex,id=arkm-codec,audiodev=arkm-audio"
                -qmp "tcp:127.0.0.1:${QEMU_QMP_PORT},server=on,wait=off"
                -monitor none
            )
            ;;
        part1-hda4)
            QEMU_ARGS+=(
                "${QEMU_ACCEL_ARGS[@]}"
                -cpu max
                -device "intel-hda,id=arkm-hda,bus=pcie.0,addr=0x4"
                -device "qemu-xhci,id=arkm-xhci,bus=pcie.0,addr=0x5"
                -device "usb-kbd,bus=arkm-xhci.0,port=1"
                -device "usb-mouse,bus=arkm-xhci.0,port=2"
                -audiodev "driver=${QEMU_AUDIO_DRIVER},id=arkm-audio,out.frequency=48000,out.channels=2,out.format=s16"
                -device "hda-duplex,id=arkm-codec,audiodev=arkm-audio"
                -qmp "tcp:127.0.0.1:${QEMU_QMP_PORT},server=on,wait=off"
                -monitor none
            )
            ;;
    esac

    # Deliberately no timeout(1) wrapper: keep this interactive VM alive until
    # the user closes its QEMU window or QEMU exits naturally.
    set +e
    qemu-system-x86_64 "${QEMU_ARGS[@]}" 2>&1 | tee "$QEMU_HOST_LOG"
    QEMU_PIPE_STATUS=("${PIPESTATUS[@]}")
    QEMU_EXIT="${QEMU_PIPE_STATUS[0]:-0}"
    set -e
    QEMU_WATCHDOG_TIMEOUT=0

    if [[ "$QEMU_NET_CAPTURE" == "1" ]]; then
        if [[ -s "$QEMU_NET_CAPTURE_FILE" ]]; then
            echo "QEMU network capture saved: $QEMU_NET_CAPTURE_FILE ($(wc -c < "$QEMU_NET_CAPTURE_FILE" | tr -d ' ') bytes)"
        else
            echo "WARNING: QEMU network capture is missing or empty: $QEMU_NET_CAPTURE_FILE"
        fi
    fi

    if [[ -f "$QEMU_LOG" ]]; then
        CPU_RESET_COUNT="$(count_match 'CPU Reset|CPU reset' "$QEMU_LOG")"
        TRIPLE_FAULT_COUNT="$(count_match 'Triple fault|triple fault' "$QEMU_LOG")"
        EXCEPTION_COUNT="$(count_match 'check_exception' "$QEMU_LOG")"
        KERNEL_ACTIVITY_COUNT="$(count_match 'RIP=000000000010[0-9a-fA-F]{4}|RIP=000000000011[0-9a-fA-F]{4}|IP=0008:000000000010[0-9a-fA-F]{4}|IP=0008:000000000011[0-9a-fA-F]{4}' "$QEMU_LOG")"

        GUEST_FATAL_COUNT=0
        if [[ -f "$QEMU_SERIAL_LOG" ]]; then
            GUEST_FATAL_COUNT="$(count_match 'FATAL MICROKERNEL EXCEPTION|TRIPLE FAULT GUARDRAIL|SYSTEM PANICKED|SYSTEM HALTED TO PREVENT HARDWARE DAMAGE|EXCEPTION TRAPPED|Page fault|General protection|Invalid opcode|Divide error' "$QEMU_SERIAL_LOG")"
        fi

        QEMU_FATAL_COUNT="$(count_match 'Triple fault|qemu: fatal|KVM:.*fatal|assertion.*failed|Aborted' "$QEMU_LOG")"
        QEMU_UNIMPLEMENTED_COUNT="$(count_match 'Unimplemented handler' "$QEMU_HOST_LOG")"

        if [[ "$TRIPLE_FAULT_COUNT" -gt 0 || "$GUEST_FATAL_COUNT" -gt 0 || "$QEMU_FATAL_COUNT" -gt 0 || "$QEMU_UNIMPLEMENTED_COUNT" -gt 0 ]]; then
            BOOT_RESULT="FAIL"
        elif [[ "$QEMU_WATCHDOG_TIMEOUT" -eq 1 ]]; then
            BOOT_RESULT="TIMEOUT"
        elif [[ "$QEMU_EXIT" -ne 0 ]]; then
            BOOT_RESULT="FAIL"
        elif [[ "$KERNEL_ACTIVITY_COUNT" -gt 0 ]]; then
            BOOT_RESULT="PASS"
        elif [[ ! -s "$QEMU_SERIAL_LOG" && "$QEMU_EXIT" -eq 0 ]]; then
            BOOT_RESULT="FAIL"
        else
            BOOT_RESULT="WARN"
        fi
    else
        BOOT_RESULT="FAIL"
    fi

    # Always generate the exact-error artifact after a QEMU run, including a
    # nominally successful run.  This lets us diagnose input/timer/SMP stalls
    # instead of only panics.
    if [[ "$QEMU_WATCHDOG_TIMEOUT" -eq 1 ]]; then
        write_error_tracker "QEMU watchdog timeout"
elif [[ "$GUEST_FATAL_COUNT" -gt 0 || "$QEMU_FATAL_COUNT" -gt 0 || "$TRIPLE_FAULT_COUNT" -gt 0 ]]; then
        write_error_tracker "Fatal/exception signature detected"
elif [[ "${QEMU_EXIT}" -ne 0 ]]; then
        write_error_tracker "QEMU exited with non-zero status"
    else
        write_error_tracker "Post-run diagnostic snapshot"
    fi
else
    echo ""
    echo "QEMU launch disabled: RUN_QEMU=0"
    echo ""
    BOOT_RESULT="NOT_RUN"
fi

# ----------------------------------------------------------------------------
# 12. Certification report
# ----------------------------------------------------------------------------
log "[12/12] Writing production certification report"

{
    echo "============================================================"
    echo "              ARKM PRODUCTION CERTIFICATION"
    echo "============================================================"
    echo "Timestamp (UTC)       : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Kernel source         : $KERNEL_SOURCE"
    echo "QEMU CPUs             : $SMP_CPUS"
    echo "QEMU RAM              : ${RAM_MB} MiB"
    echo "QEMU profile          : $QEMU_PROFILE (device profile)"
    echo "QEMU firmware         : OVMF x86_64 UEFI only"
    echo "QEMU QMP port         : $QEMU_QMP_PORT"
    echo "Disk                  : ${DISK_MB} MiB FAT32 (update=${UPDATE_RUNTIME_DISK})"
    echo ""
    echo "SOURCE / BUILD GATES"
    echo "  source architecture gates : PASS"
    echo "  compiler (-Werror)        : PASS"
    echo "  interrupt ownership      : PASS"
    echo "  ELF architecture          : PASS"
    echo "  required ELF symbols      : PASS"
    echo "  UEFI x86_64 EFI application: PASS"
    echo "  UEFI-only El Torito catalog: PASS (EFI platform 0xEF; no BIOS entry)"
    echo "  Multiboot2 kernel payload : PASS (loaded by UEFI GRUB)"
    echo "  BIOS/SeaBIOS boot path   : DISABLED"
    echo "  GRUB source              : ARKM-patched GRUB 2.14 x86_64-efi"
    echo ""
    echo "RUNTIME DIAGNOSTICS"
    echo "  QEMU boot result          : $BOOT_RESULT"
    echo "  QEMU exit code            : $QEMU_EXIT"
    echo "  CPU reset count (diagnostic): $CPU_RESET_COUNT"
    echo "  triple fault count          : $TRIPLE_FAULT_COUNT"
    echo "  check_exception count       : $EXCEPTION_COUNT"
    echo "  QEMU fatal markers         : $QEMU_FATAL_COUNT"
    echo "  guest fatal markers        : $GUEST_FATAL_COUNT"
    echo "  kernel activity records    : $KERNEL_ACTIVITY_COUNT"
    echo "  QEMU watchdog timeout      : DISABLED (${QEMU_WATCHDOG_TIMEOUT:-0})"
    echo "  error tracker              : $ERROR_REPORT"
    echo "  NOTE: CPU Reset records can be normal during SMP AP INIT bring-up."
    echo ""
    echo "GUEST CERTIFICATION"
    echo "  IMPORTANT: The following require the guest shell/test harness."
    echo "  The build script does not fabricate PASS values for them."
    echo ""
    echo "  SMP 12/12                  : RUN GUEST: SMP"
    echo "  AMP foundation             : RUN GUEST: AMP"
    echo "  LUNA native filesystem    : RUN GUEST: LUNA TEST"
    echo "  LUNA namespace             : RUN GUEST: LUNA LS"
    echo "  Aegis security             : RUN GUEST: AEGIS TEST (when available)"
    echo "  production invariants      : RUN GUEST: PROD TEST"
    echo "  POSIX compatibility        : RUN POSIX TEST"
    echo "  scheduler migration        : RUN AMP MIGRATION TEST"
    echo "  memory stress              : RUN MEMTEST"
    echo "  network stress             : controlled external test matrix"
    echo "  driver recovery            : controlled fault-injection tests"
    echo "  endurance                  : repeated/long-duration test harness"
    echo ""
    echo "RELEASE RULE"
    echo "  ARKM is not production-certified solely by this build script."
    echo "  Runtime gates must be observed and recorded from the guest."
    echo "============================================================"
} > "$CERT_REPORT"

# ----------------------------------------------------------------------------
# Final result
# ----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "                    ARKM BUILD SUMMARY"
echo "============================================================"
echo "Kernel source       : $KERNEL_SOURCE"
echo "Kernel ELF          : $KERNEL_ELF"
echo "Boot ISO            : $ISO_IMAGE (UEFI only; patched GRUB 2.14)"
echo "UEFI boot app       : iso/EFI/BOOT/BOOTX64.EFI"
echo "UEFI ESP image      : $UEFI_ESP_IMAGE"
echo "Runtime disk        : $HDD_IMAGE (update=${UPDATE_RUNTIME_DISK})"
echo "Build manifest      : $CERT_MANIFEST"
echo "Certification report: $CERT_REPORT"
echo "QEMU CPUs           : $SMP_CPUS"
echo "QEMU firmware       : OVMF x86_64 (UEFI only)"
echo "QEMU boot result    : $BOOT_RESULT"
echo "QEMU exit code      : $QEMU_EXIT"
echo "CPU resets (diag)    : $CPU_RESET_COUNT"
echo "Triple faults        : $TRIPLE_FAULT_COUNT"
echo "QEMU fatal markers   : $QEMU_FATAL_COUNT"
echo "QEMU unimplemented handlers: ${QEMU_UNIMPLEMENTED_COUNT:-0}"
echo "Guest fatal markers  : $GUEST_FATAL_COUNT"
echo "QEMU host output log : $QEMU_HOST_LOG"
if [[ "$QEMU_NET_CAPTURE" == "1" ]]; then echo "QEMU net capture file: $QEMU_NET_CAPTURE_FILE"; fi
if [[ "$QEMU_NET_BACKEND" == "passt" ]]; then echo "passt IPv6 capture file: $QEMU_PASST_PCAP_FILE"; fi
echo "QEMU trace log       : $QEMU_LOG"
echo "QEMU watchdog       : DISABLED (${QEMU_WATCHDOG_TIMEOUT:-0})"
echo "Error tracker       : $ERROR_REPORT"
echo "Total build elapsed : $((SECONDS - BUILD_START_SECONDS)) seconds"
echo "============================================================"

if [[ "$RUN_QEMU" == "1" && ( "$BOOT_RESULT" == "FAIL" || "$BOOT_RESULT" == "TIMEOUT" ) ]]; then
    echo "ARKM BUILD RESULT: FAIL"
    echo "Inspect $ERROR_REPORT, $QEMU_HOST_LOG, $QEMU_LOG, $QEMU_SERIAL_LOG and $CERT_REPORT."
    exit 1
fi

if [[ "$RUN_QEMU" == "0" ]]; then
    echo "ARKM BUILD RESULT: UEFI BUILD/IMAGE PASS (runtime not executed)"
elif [[ "$BOOT_RESULT" == "PASS" ]]; then
    echo "ARKM BUILD RESULT: BUILD + QEMU BOOT DIAGNOSTIC PASS"
    echo "Runtime production gates still require guest-side certification."
elif [[ "$BOOT_RESULT" == "TIMEOUT" ]]; then
    echo "ARKM BUILD RESULT: QEMU WATCHDOG TIMEOUT"
    echo "Inspect $ERROR_REPORT, $QEMU_HOST_LOG, $QEMU_LOG and $QEMU_SERIAL_LOG."
else
    echo "ARKM BUILD RESULT: BUILD PASS, QEMU BOOT EVIDENCE INCONCLUSIVE"
fi

echo "============================================================"
exit 0
