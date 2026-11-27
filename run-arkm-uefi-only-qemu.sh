#!/usr/bin/env bash
# ARKM UEFI-only QEMU diagnostic runner.
# Keeps the graphical guest display and sends the interactive HMP monitor to the MSYS2 terminal.
# Guest shutdown/panic pauses the VM; reboot uses normal reset behavior.
# The original hdd.img is never formatted or modified; only hdd-uefi-test.img is used.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$ROOT_DIR"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
ISO_IMAGE="${ISO_IMAGE:-$ROOT_DIR/arkm-uefi-only-test.iso}"
HDD_IMAGE="${HDD_IMAGE:-$ROOT_DIR/hdd.img}"
OVMF_CODE="${OVMF_CODE:-$ROOT_DIR/firmware/ovmf/OVMF_CODE.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$ROOT_DIR/firmware/ovmf/OVMF_VARS_TEMPLATE.fd}"
RAM_MB="${RAM_MB:-512}"
SMP_CPUS="${SMP_CPUS:-12}"
# The known-good ARKM UEFI path was runtime-verified with multi-threaded TCG.
# Keep WHPX opt-in until it passes the same boot test on this host.
QEMU_ACCEL="${QEMU_ACCEL:-tcg,thread=multi}"
RESET_OVMF_VARS="${RESET_OVMF_VARS:-0}"
TEST_VARS_IMAGE="${TEST_VARS_IMAGE:-}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The MSYS2 shell uses POSIX paths, but qemu-system-x86_64.exe is a native
# Windows executable. Convert every path passed to QEMU to Windows form.
# Keep POSIX paths for shell utilities (xorriso, mtools, cp, tail, tee).
if [[ -n "${MSYSTEM:-}" ]] || [[ "$(uname -s 2>/dev/null || true)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null || true)" == MSYS* ]]; then
    command -v cygpath >/dev/null 2>&1 || fail "MSYS2 detected but cygpath is unavailable."
    qemu_path() { cygpath -m -- "$1"; }
else
    qemu_path() { printf '%s\n' "$1"; }
fi

fat32_superfloppy_bpb_ok() {
    local image="$1" sig bps spc reserved fats total16 total32 fatsz16 fatsz32 root_cluster data_start
    sig="$(od -An -tx1 -j510 -N2 "$image" | tr -d '[:space:]')" || return 1
    bps="$(od -An -tu2 -j11 -N2 "$image" | tr -d '[:space:]')" || return 1
    spc="$(od -An -tu1 -j13 -N1 "$image" | tr -d '[:space:]')" || return 1
    reserved="$(od -An -tu2 -j14 -N2 "$image" | tr -d '[:space:]')" || return 1
    fats="$(od -An -tu1 -j16 -N1 "$image" | tr -d '[:space:]')" || return 1
    total16="$(od -An -tu2 -j19 -N2 "$image" | tr -d '[:space:]')" || return 1
    fatsz16="$(od -An -tu2 -j22 -N2 "$image" | tr -d '[:space:]')" || return 1
    total32="$(od -An -tu4 -j32 -N4 "$image" | tr -d '[:space:]')" || return 1
    fatsz32="$(od -An -tu4 -j36 -N4 "$image" | tr -d '[:space:]')" || return 1
    root_cluster="$(od -An -tu4 -j44 -N4 "$image" | tr -d '[:space:]')" || return 1
    [[ "$sig" == "55aa" && "$bps" == "512" ]] || return 1
    (( spc > 0 && (spc & (spc - 1)) == 0 )) || return 1
    (( reserved > 0 && fats > 0 && total16 == 0 && fatsz16 == 0 )) || return 1
    (( total32 > 0 && fatsz32 > 0 && root_cluster >= 2 )) || return 1
    data_start=$((reserved + fats * fatsz32))
    (( total32 > data_start ))
}

for cmd in "$QEMU_BIN" xorriso od tr; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done
for file in "$ISO_IMAGE" "$HDD_IMAGE" "$OVMF_CODE" "$OVMF_VARS_TEMPLATE"; do
    [[ -f "$file" ]] || fail "Required file not found: $file"
done
[[ "$RAM_MB" =~ ^[0-9]+$ && "$RAM_MB" -ge 128 ]] || fail "RAM_MB must be an integer >= 128."
[[ "$SMP_CPUS" =~ ^[0-9]+$ && "$SMP_CPUS" -ge 1 && "$SMP_CPUS" -le 32 ]] || fail "SMP_CPUS must be in 1..32. Default is 12."
[[ "$RESET_OVMF_VARS" == 0 || "$RESET_OVMF_VARS" == 1 ]] || fail "RESET_OVMF_VARS must be 0 or 1."

# Prefer hardware virtualization on the host (WHPX on Windows/MSYS2,
# KVM on Linux, HVF on macOS). Fall back to multi-threaded TCG if the
# accelerator is unavailable or cannot initialize. Override with QEMU_ACCEL.
QEMU_ACCEL_ARGS=()
QEMU_ACCEL_SELECTED="$QEMU_ACCEL"
QEMU_ACCEL_AUTO_SELECTED=0
QEMU_ACCEL_HELP="$("$QEMU_BIN" -accel help 2>&1 || true)"
QEMU_HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
if [[ "$QEMU_ACCEL" == "auto" ]]; then
    QEMU_ACCEL_AUTO_SELECTED=1
    case "$QEMU_HOST_OS" in
        MINGW*|MSYS*|CYGWIN*)
            if grep -Eq '(^|[^[:alnum:]_])whpx([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                QEMU_ACCEL_SELECTED="whpx"
            else
                QEMU_ACCEL_SELECTED="tcg,thread=multi"
            fi
            ;;
        Linux*)
            if [[ -r /dev/kvm && -w /dev/kvm ]] && grep -Eq '(^|[^[:alnum:]_])kvm([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                QEMU_ACCEL_SELECTED="kvm"
            else
                QEMU_ACCEL_SELECTED="tcg,thread=multi"
            fi
            ;;
        Darwin*)
            if grep -Eq '(^|[^[:alnum:]_])hvf([^[:alnum:]_]|$)' <<<"$QEMU_ACCEL_HELP"; then
                QEMU_ACCEL_SELECTED="hvf"
            else
                QEMU_ACCEL_SELECTED="tcg,thread=multi"
            fi
            ;;
        *) QEMU_ACCEL_SELECTED="tcg,thread=multi" ;;
    esac
else
    case "$QEMU_ACCEL" in
        whpx|kvm|hvf|tcg|tcg,thread=multi|tcg,thread=single) ;;
        *) fail "Unsupported QEMU_ACCEL='$QEMU_ACCEL'. Use auto, whpx, kvm, hvf, tcg, tcg,thread=multi, or tcg,thread=single." ;;
    esac
    if [[ "$QEMU_ACCEL" != "tcg" && "$QEMU_ACCEL" != tcg,* ]] &&
       ! grep -Eq "(^|[^[:alnum:]_])${QEMU_ACCEL}([^[:alnum:]_]|$)" <<<"$QEMU_ACCEL_HELP"; then
        fail "QEMU accelerator '$QEMU_ACCEL' is not available in this QEMU build."
    fi
fi
if [[ "$QEMU_ACCEL_AUTO_SELECTED" == "1" && "$QEMU_ACCEL_SELECTED" != "tcg,thread=multi" ]]; then
    QEMU_ACCEL_ARGS+=( -accel "$QEMU_ACCEL_SELECTED" -accel "tcg,thread=multi" )
else
    QEMU_ACCEL_ARGS+=( -accel "$QEMU_ACCEL_SELECTED" )
fi

ISO_REPORT="$(xorriso -indev "$ISO_IMAGE" -report_el_torito as_mkisofs 2>&1)" \
    || fail "xorriso could not inspect $ISO_IMAGE"
printf '%s\n' "$ISO_REPORT"
grep -Eq '(^|[[:space:]])-e([[:space:]]|$)' <<<"$ISO_REPORT" \
    || fail "No EFI El Torito entry (-e) was reported; refusing to launch."
if grep -Eq '(^|[[:space:]])-b([[:space:]]|$)' <<<"$ISO_REPORT"; then
    fail "A BIOS El Torito entry was found; this runner requires a UEFI-only ISO."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
TEST_HDD="${TEST_HDD_IMAGE:-$ROOT_DIR/hdd-uefi-test.img}"
VARS_DIR="$(dirname -- "$OVMF_VARS_TEMPLATE")"
TEST_VARS="${TEST_VARS_IMAGE:-$VARS_DIR/OVMF_VARS_arkm-test-persistent.fd}"
SERIAL_LOG="$ROOT_DIR/arkm_uefi_serial_$STAMP.log"
DEBUG_LOG="$ROOT_DIR/arkm_uefi_debug_$STAMP.log"
QEMU_LOG="$ROOT_DIR/arkm_uefi_qemu_$STAMP.log"
HOST_LOG="$ROOT_DIR/arkm_uefi_host_$STAMP.log"

[[ "$TEST_HDD" != "$HDD_IMAGE" ]] || fail "TEST_HDD_IMAGE must not refer to the original HDD_IMAGE."
if [[ ! -f "$TEST_HDD" ]]; then
    cp -- "$HDD_IMAGE" "$TEST_HDD"
    printf 'Created persistent disposable test disk from: %s\n' "$HDD_IMAGE"
else
    printf 'Reusing persistent disposable test disk: %s\n' "$TEST_HDD"
fi

# Keep a separate persistent test NVRAM store. The old runner copied the OVMF
# template to a new timestamped file on every boot, discarding Boot####/BootOrder
# updates each time and forcing firmware to rediscover the optical boot path.
# RESET_OVMF_VARS=1 intentionally resets only this disposable test VARS file.
TEMPLATE_VARS_SIZE="$(wc -c < "$OVMF_VARS_TEMPLATE" | tr -d ' ')"
if [[ "$RESET_OVMF_VARS" == 1 || ! -s "$TEST_VARS" ]]; then
    cp -- "$OVMF_VARS_TEMPLATE" "$TEST_VARS"
    printf 'Initialized persistent disposable OVMF VARS from template: %s\n' "$TEST_VARS"
else
    TEST_VARS_SIZE="$(wc -c < "$TEST_VARS" | tr -d ' ')"
    [[ "$TEST_VARS_SIZE" == "$TEMPLATE_VARS_SIZE" ]] || \
        fail "Persistent test VARS size ($TEST_VARS_SIZE) differs from template ($TEMPLATE_VARS_SIZE). Use RESET_OVMF_VARS=1 to recreate the disposable VARS file."
    printf 'Reusing persistent OVMF test VARS: %s\n' "$TEST_VARS"
fi

command -v mdir >/dev/null 2>&1 || fail "mtools mdir is required to validate the test FAT32 volume."
if fat32_superfloppy_bpb_ok "$TEST_HDD" && mdir -i "$TEST_HDD" :: >/dev/null 2>&1; then
    printf 'Test disk filesystem : valid FAT32 superfloppy preserved on test copy\n'
else
    command -v mformat >/dev/null 2>&1 || fail "Invalid test FAT32 image and mformat unavailable; install mtools."
    printf 'Test disk filesystem : formatting disposable test copy as FAT32\n'
    mformat -i "$TEST_HDD" -F || fail "Could not format disposable test disk copy."
    fat32_superfloppy_bpb_ok "$TEST_HDD" || fail "FAT32 BPB validation failed after formatting."
    mdir -i "$TEST_HDD" :: >/dev/null 2>&1 || fail "FAT32 directory validation failed after formatting."
fi

printf '\n=== ARKM UEFI-ONLY QEMU DIAGNOSTIC RUN ===\n'
printf 'ISO              : %s\n' "$ISO_IMAGE"
printf 'OVMF CODE        : %s\n' "$OVMF_CODE"
printf 'QEMU CPU / RAM   : %s / %s MiB\n' "$SMP_CPUS" "$RAM_MB"
printf 'QEMU accelerator preference : %s%s\n' "$QEMU_ACCEL_SELECTED" "$(if [[ "$QEMU_ACCEL_AUTO_SELECTED" == 1 && "$QEMU_ACCEL_SELECTED" != "tcg,thread=multi" ]]; then printf ' (TCG fallback enabled)'; fi)"
printf 'Acceleration policy        : stable TCG default; set QEMU_ACCEL=whpx only for a separate WHPX test.\n'
printf 'Test disk        : %s\n' "$TEST_HDD"
printf 'Serial log       : %s\n' "$SERIAL_LOG"
printf 'Debugcon log     : %s\n' "$DEBUG_LOG"
printf 'QEMU trace       : %s\n' "$QEMU_LOG"
printf 'Host output      : %s\n' "$HOST_LOG"
printf '\nQEMU path mode   : %s\n' "$(if [[ -n "${MSYSTEM:-}" ]]; then printf 'Windows paths via cygpath'; else printf 'native host paths'; fi)"
printf 'QEMU event policy: guest reboot = normal reset; guest shutdown/panic = pause.\n'
printf 'Monitor mode     : interactive QEMU monitor in this terminal (-monitor stdio).\n'
printf 'Display mode     : StdVGA EDID requests 1280x720; graphical window remains enabled.\n'
printf 'Storage model    : Q35 ICH9 AHCI; system disk port 0, UEFI media port 1.\n'
printf 'Use this terminal for info commands; use the QEMU window only to view the guest display.\n'
printf 'When the VM is paused, the monitor remains available for inspection.\n\n'

# Create the artifacts before launch so they are visible in Explorer even if
# QEMU rejects a path or fails during device initialization.
: > "$SERIAL_LOG"
: > "$DEBUG_LOG"
: > "$QEMU_LOG"
: > "$HOST_LOG"

# Native Windows QEMU must receive C:/... paths, not /home/... MSYS paths.
QEMU_ISO_IMAGE="$(qemu_path "$ISO_IMAGE")"
QEMU_TEST_HDD="$(qemu_path "$TEST_HDD")"
QEMU_OVMF_CODE="$(qemu_path "$OVMF_CODE")"
QEMU_TEST_VARS="$(qemu_path "$TEST_VARS")"
QEMU_SERIAL_LOG="$(qemu_path "$SERIAL_LOG")"
QEMU_DEBUG_LOG="$(qemu_path "$DEBUG_LOG")"
QEMU_TRACE_LOG="$(qemu_path "$QEMU_LOG")"
BOOT_TIMING_LOG="$ROOT_DIR/arkm_boot_timing_$STAMP.log"
BOOT_WATCH_STOP="$ROOT_DIR/.arkm_boot_watch_stop_$STAMP"
: > "$BOOT_TIMING_LOG"
rm -f "$BOOT_WATCH_STOP"
QEMU_LAUNCH_EPOCH="$(date +%s)"
printf 'QEMU launch epoch: %s\n' "$QEMU_LAUNCH_EPOCH" >> "$BOOT_TIMING_LOG"

# Record firmware/GRUB/kernel milestones without injecting code into ARKM.
# The watcher reads the serial log and records first occurrence times.
(
    markers=(
        'BdsDxe: starting Boot'
        'ARKM-GRUB-DIAG: configuration loaded'
        '[BOOT-TRACE] EFI64 entry reached'
        '[UEFI] ExitBootServices PASS'
        '[BOOT-TRACE] kernel_main entered'
        '[SMP] final online/discovered=12/12'
        '[LUNA] filesystem mounted ONLINE'
    )
    labels=(
        'OVMF BDS began launching the selected boot device'
        'GRUB configuration started'
        'EFI64 kernel entry reached'
        'ExitBootServices completed'
        'kernel_main started'
        'all 12 CPUs online'
        'LUNA mounted'
    )
    declare -a seen=(0 0 0 0 0 0 0)
    while [[ ! -e "$BOOT_WATCH_STOP" ]]; do
        for i in "${!markers[@]}"; do
            if [[ "${seen[$i]}" == 0 ]] && grep -aFq -- "${markers[$i]}" "$SERIAL_LOG" 2>/dev/null; then
                seen[$i]=1
                now="$(date +%s)"
                elapsed=$((now - QEMU_LAUNCH_EPOCH))
                printf '[BOOT-TIMING] +%ss : %s\n' "$elapsed" "${labels[$i]}" >> "$BOOT_TIMING_LOG"
            fi
        done
        sleep 0.5
    done
) &
BOOT_WATCH_PID=$!

cleanup_boot_watcher() {
    touch "$BOOT_WATCH_STOP" 2>/dev/null || true
    if [[ -n "${BOOT_WATCH_PID:-}" ]]; then wait "$BOOT_WATCH_PID" 2>/dev/null || true; fi
    rm -f "$BOOT_WATCH_STOP"
}
trap cleanup_boot_watcher EXIT

set +e
# Q35's built-in ICH9 AHCI controller exposes SATA ports as ide.0..ide.5;
# ide-hd is the ATA disk endpoint on that AHCI SATA port, not a PIIX IDE controller.
"$QEMU_BIN" \
    -machine q35,acpi=on,hpet=on \
    "${QEMU_ACCEL_ARGS[@]}" \
    -cpu max \
    -m "$RAM_MB" \
    -smp "cpus=${SMP_CPUS},sockets=1,cores=${SMP_CPUS},threads=1" \
    -drive "if=pflash,format=raw,readonly=on,file=$QEMU_OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$QEMU_TEST_VARS" \
    -drive "if=none,id=arkm_hdd,file=$QEMU_TEST_HDD,format=raw" \
    -device ide-hd,drive=arkm_hdd,bus=ide.0 \
    -drive "if=none,id=arkm_uefi_iso,file=$QEMU_ISO_IMAGE,format=raw,media=cdrom,readonly=on" \
    -device ide-cd,drive=arkm_uefi_iso,bus=ide.1 \
    -boot order=d \
    -device VGA,edid=on,xres=1280,yres=720 \
    -monitor stdio \
    -netdev user,id=net0,ipv4=on,ipv6=on,hostfwd=tcp::8080-:80 \
    -device e1000,netdev=net0,bus=pcie.0,addr=0x3 \
    -device qemu-xhci,id=arkm-xhci,bus=pcie.0,addr=0x5 \
    -device usb-kbd,bus=arkm-xhci.0,port=1 \
    -device usb-mouse,bus=arkm-xhci.0,port=2 \
    -audiodev driver=none,id=arkm-audio,out.frequency=48000,out.channels=2,out.format=s16 \
    -device intel-hda,id=arkm-hda,bus=pcie.0,addr=0x6 \
    -device hda-duplex,id=arkm-codec,audiodev=arkm-audio \
    -serial "file:$QEMU_SERIAL_LOG" \
    -debugcon "file:$QEMU_DEBUG_LOG" \
    -global isa-debugcon.iobase=0x402 \
    -action shutdown=pause,panic=pause \
    -d guest_errors,unimp,cpu_reset -D "$QEMU_TRACE_LOG" \
    2>&1 | tee "$HOST_LOG"
QEMU_STATUS=${PIPESTATUS[0]}
set -e
cleanup_boot_watcher
trap - EXIT

printf '\nQEMU host process exit status: %s (not a guest boot certification)\n' "$QEMU_STATUS"
printf '\n===== BOOT STAGE TIMING =====\n'
cat "$BOOT_TIMING_LOG" 2>/dev/null || true
printf '\n===== SERIAL LOG (last 160 lines) =====\n'
tail -n 160 "$SERIAL_LOG" 2>/dev/null || true
printf '\n===== DEBUGCON LOG =====\n'
cat "$DEBUG_LOG" 2>/dev/null || true
printf '\n===== QEMU TRACE (last 120 lines) =====\n'
tail -n 120 "$QEMU_LOG" 2>/dev/null || true

if ! grep -aEq 'EFI64 entry reached|kernel_main entered|ARKM-GRUB-DIAG|Multiboot2 load succeeded' "$SERIAL_LOG" 2>/dev/null; then
    printf '\nDIAGNOSTIC: no GRUB-to-kernel serial marker was captured in this run.\n'
fi
printf '\nSaved artifacts:\n  %s\n  %s\n  %s\n  %s\n' "$SERIAL_LOG" "$DEBUG_LOG" "$QEMU_LOG" "$HOST_LOG"
printf '\nThe interactive monitor output is also captured in: %s\n' "$HOST_LOG"
printf 'Boot-stage timing log: %s\n' "$BOOT_TIMING_LOG"
exit "$QEMU_STATUS"
