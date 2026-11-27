# Security Policy

## Scope
This repository hosts the prototype codebase showcase for **ARKM Kernel** (`x86_64`, UEFI-only). The main ARKM Kernel continues active development in its driver expansion, AI model implementation, and testing phases.

## Security Architecture Highlights
- **Aegis CPU Hardening**: Enables supervisor/user isolation (`SMAP`, `SMEP`, `NX`) and clears `AC` on interrupt/exception entry (`CLAC_IF_SMAP` in `idt.s`).
- **Syscall Pointer Validation**: Ring 3 pointers passed via `int $0x80` are checked through `validate_user_pointer` / `aegis_validate_extended` before kernel dereference.
- **Resource & Identity Accounting**: Per-process resource reservations and ownership checks (`arkm_rm_*`) track PID and generation identity.

## Reporting a Vulnerability
If you discover a security vulnerability (such as a Ring 3 → Ring 0 privilege escalation, pointer validation bypass, memory corruption, or DMA/IOMMU issue):

1. **Do not** open a public GitHub issue with exploit details.
2. Report it privately through **GitHub Security Advisories** ("Report a vulnerability" under the repository's **Security** tab).
3. Include:
   - Affected file(s) and function/symbol names
   - Reproduction steps (e.g., QEMU configuration, Ring 3 test case, or serial/debugcon logs)
   - Expected vs. observed behavior
