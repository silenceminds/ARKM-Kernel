#!/usr/bin/env bash
# Headless QEMU UEFI boot smoke test for ARKM Kernel.
# Verifies that the UEFI-only ISO boots through OVMF + GRUB2 into kernel_main
# and brings up SMP cores without requiring an interactive graphical session.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT_DIR"

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
ISO_IMAGE="${ISO_IMAGE:-$ROOT_DIR/arkm-uefi-only-test.iso}"
HDD_IMAGE="${HDD_IMAGE:-$ROOT_DIR/hdd.img}"
OVMF_CODE="${OVMF_CODE:-$ROOT_DIR/firmware/ovmf/OVMF_CODE.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-$ROOT_DIR/firmware/ovmf/OVMF_VARS_TEMPLATE.fd}"
RAM_MB="${RAM_MB:-512}"
SMP_CPUS="${SMP_CPUS:-4}"
QEMU_TIMEOUT_SEC="${QEMU_TIMEOUT_SEC:-45}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for cmd in "$QEMU_BIN" timeout xorriso grep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done
for f in "$ISO_IMAGE" "$HDD_IMAGE" "$OVMF_CODE" "$OVMF_VARS_TEMPLATE"; do
    [[ -f "$f" ]] || fail "Required file not found: $f"
done

# Verify UEFI-only El Torito catalog
ISO_REPORT="$(xorriso -indev "$ISO_IMAGE" -report_el_torito as_mkisofs 2>&1)"
grep -Eq '(^|[[:space:]])-e([[:space:]]|$)' <<<"$ISO_REPORT" || fail "Missing EFI El Torito entry (-e)"
if grep -Eq '(^|[[:space:]])-b([[:space:]]|$)' <<<"$ISO_REPORT"; then
    fail "Unexpected BIOS El Torito entry (-b) in UEFI-only ISO"
fi

WORK_HDD="$(mktemp "$ROOT_DIR/smoke_hdd.XXXXXX.img")"
WORK_VARS="$(mktemp "$ROOT_DIR/smoke_vars.XXXXXX.fd")"
SERIAL_LOG="$ROOT_DIR/smoke_serial.log"
DEBUG_LOG="$ROOT_DIR/smoke_debugcon.log"

cleanup() {
    rm -f "$WORK_HDD" "$WORK_VARS"
}
trap cleanup EXIT

cp -- "$HDD_IMAGE" "$WORK_HDD"
cp -- "$OVMF_VARS_TEMPLATE" "$WORK_VARS"
: > "$SERIAL_LOG"
: > "$DEBUG_LOG"

if [[ -n "${MSYSTEM:-}" ]] || [[ "$(uname -s 2>/dev/null || true)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null || true)" == MSYS* ]]; then
    qemu_path() { cygpath -m -- "$1"; }
else
    qemu_path() { printf '%s\n' "$1"; }
fi

printf 'Running headless QEMU smoke test (SMP=%s, RAM=%sM, timeout=%ss)...\n' "$SMP_CPUS" "$RAM_MB" "$QEMU_TIMEOUT_SEC"

TARGET_MARKER="[SMP] final online/discovered=${SMP_CPUS}/${SMP_CPUS}"

set +e
"$QEMU_BIN" \
    -machine q35,acpi=on,hpet=on \
    -accel tcg,thread=multi \
    -cpu max \
    -m "$RAM_MB" \
    -smp "cpus=${SMP_CPUS},sockets=1,cores=${SMP_CPUS},threads=1" \
    -drive "if=pflash,format=raw,readonly=on,file=$(qemu_path "$OVMF_CODE")" \
    -drive "if=pflash,format=raw,file=$(qemu_path "$WORK_VARS")" \
    -drive "if=none,id=arkm_hdd,file=$(qemu_path "$WORK_HDD"),format=raw" \
    -device ide-hd,drive=arkm_hdd,bus=ide.0 \
    -drive "if=none,id=arkm_uefi_iso,file=$(qemu_path "$ISO_IMAGE"),format=raw,media=cdrom,readonly=on" \
    -device ide-cd,drive=arkm_uefi_iso,bus=ide.1 \
    -boot order=d \
    -display none \
    -monitor none \
    -netdev user,id=net0,ipv4=on,ipv6=on \
    -device e1000,netdev=net0,bus=pcie.0,addr=0x3 \
    -device qemu-xhci,id=arkm-xhci,bus=pcie.0,addr=0x5 \
    -device usb-kbd,bus=arkm-xhci.0,port=1 \
    -device usb-mouse,bus=arkm-xhci.0,port=2 \
    -serial "file:$(qemu_path "$SERIAL_LOG")" \
    -debugcon "file:$(qemu_path "$DEBUG_LOG")" \
    -global isa-debugcon.iobase=0x402 \
    -no-reboot &
QEMU_PID=$!

elapsed=0
while kill -0 "$QEMU_PID" 2>/dev/null; do
    if grep -aFq -- "$TARGET_MARKER" "$SERIAL_LOG" 2>/dev/null; then
        printf 'Detected %s after %ss; stopping QEMU.\n' "$TARGET_MARKER" "$elapsed"
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        break
    fi
    if (( elapsed >= QEMU_TIMEOUT_SEC )); then
        printf 'Timeout (%ss) reached; stopping QEMU.\n' "$QEMU_TIMEOUT_SEC" >&2
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
wait "$QEMU_PID" 2>/dev/null
QEMU_RC=$?
set -e

# timeout exits 124 (or 143 with --preserve-status SIGTERM) when the guest stays alive cleanly
if [[ "$QEMU_RC" -ne 0 && "$QEMU_RC" -ne 124 && "$QEMU_RC" -ne 143 ]]; then
    printf 'QEMU exited unexpectedly with status %s\n' "$QEMU_RC" >&2
fi

REQUIRED_MARKERS=(
    "ARKM-GRUB-DIAG: configuration loaded"
    "[BOOT-TRACE] EFI64 entry reached"
    "[UEFI] ExitBootServices PASS"
    "[BOOT-TRACE] kernel_main entered"
    "[SMP] final online/discovered=${SMP_CPUS}/${SMP_CPUS}"
)

MISSING=0
for marker in "${REQUIRED_MARKERS[@]}"; do
    if grep -aFq -- "$marker" "$SERIAL_LOG"; then
        printf '  PASS  %s\n' "$marker"
    else
        printf '  FAIL  missing marker: %s\n' "$marker" >&2
        MISSING=1
    fi
done

if [[ "$MISSING" -ne 0 ]]; then
    printf '\n--- Last 80 lines of %s ---\n' "$SERIAL_LOG" >&2
    tail -n 80 "$SERIAL_LOG" >&2 || true
    exit 1
fi

printf 'PASS: ARKM headless QEMU smoke test succeeded.\n'
