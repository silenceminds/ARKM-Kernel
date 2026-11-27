# Contributing to ARKM Kernel

Thank you for your interest in **ARKM Kernel**. This repository publishes the prototype codebase demonstrating the bootable `x86_64` kernel, Ring 3 applications, and QEMU UEFI workflow.

## Development Workflow

1. **Build locally**:
   ```bash
   UPDATE_RUNTIME_DISK=1 ./build.sh
   ```
   `build.sh` compiles with `-Wall -Wextra -Werror` and enforces symbol and interrupt-stub ownership checks.

2. **Run the automated smoke test**:
   ```bash
   ./tests/qemu_smoke_test.sh
   ```

3. **Run interactively in QEMU**:
   ```bash
   ./run-arkm-uefi-only-qemu.sh
   ```

## Guidelines
- **Line Endings**: Keep `LF` (`\n`) line endings on all `.sh`, `.S`, `.s`, `.c`, `.ld`, and `.cfg` files (enforced by `.gitattributes`).
- **Interrupt Stub Ownership**: All interrupt/exception stubs (`*_stub`) belong in `idt.s`, never in `boot.S`.
- **Clean Pull Requests**: Do not commit generated `.o`, `.elf`, `.img`, `.iso`, or `.log` artifacts (see `.gitignore`).
- **PR Checklist**: Complete the Pull Request template and confirm both `./build.sh` and `./tests/qemu_smoke_test.sh` pass.
