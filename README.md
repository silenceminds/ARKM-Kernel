# ARKM Kernel (`arkm-kernel`)

[![Codebase](https://img.shields.io/badge/codebase-prototype%20showcase-orange.svg)](#quick-start-building--launching-live-in-qemu)
[![Kernel Status](https://img.shields.io/badge/ARKM%20kernel-driver%20expansion%20%26%20AI%20phase-blueviolet.svg)](#architecture-overview)
[![Architecture](https://img.shields.io/badge/arch-x86__64-blue.svg)](#architecture-overview)
[![Boot](https://img.shields.io/badge/boot-UEFI--Only%20%7C%20Multiboot2-informational.svg)](#boot--low-level-entry)
[![QEMU](https://img.shields.io/badge/tested%20on-QEMU%20Q35%20%2B%20OVMF-brightgreen.svg)](#how-to-test-inside-qemu)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](./LICENSE)

> **Repository Notice:** This repository contains a **prototype codebase** published to demonstrate that the ARKM kernel source and bootable implementation exist and run. The **actual ARKM Kernel** itself is beyond the prototype stage and is actively in its **driver expansion phase** and **AI model implementation phase**, alongside ongoing testing.
>
## Live Demo & Video Showcase

[![Watch ARKM Kernel Live Demo on YouTube](https://img.youtube.com/vi/sQ-p2lf3CV0/maxresdefault.jpg)](https://www.youtube.com/watch?v=sQ-p2lf3CV0 "Watch ARKM Kernel on YouTube")

Watch the full video on YouTube: [https://www.youtube.com/watch?v=sQ-p2lf3CV0](https://www.youtube.com/watch?v=sQ-p2lf3CV0)

A custom 64-bit (`x86_64`) microkernel and operating system environment built in C and x86-64 assembly, featuring a UEFI-only Multiboot2 boot flow (via a patched GRUB 2.14 `x86_64-efi` loader), SMP multi-core bring-up, Ring 3 user-space ELF execution, a graphical compositor/dashboard, storage (AHCI/SATA, NVMe, FAT32, LunaFS), networking (E1000, IPv4/IPv6 SLAAC, TCP/HTTP), and USB xHCI HID input.

---


## Architecture Overview

### Boot & Low-Level Entry
- **`boot.S`**: Defines the Multiboot2 header (`0xE85250D6`) with optional EFI `amd64` boot-services and entry (`efi64_start`) tags, plus framebuffer (`1280x720x32` requested) and ACPI RSDP information tags. Handles `_start` (32-bit protected mode Multiboot2 entry), CPUID feature validation (PAE, PSE, FXSR, SSE, SSE2, Long Mode), initial 4-level page tables (`p4_table`, `p3_table`, `p2_table`, etc., including high identity maps for LAPIC `0xfee00000`, framebuffer, and PCI ECAM), long-mode transition, BSP stack setup, and the SMP AP trampoline (`ap_trampoline`).
- **`idt.s`**: Owns `idt_flush` and all 64-bit interrupt/exception stubs (`timer_stub`, `keyboard_stub`, `mouse_stub`, `syscall_stub`, `isr8_stub`, `isr13_stub`, `isr14_stub`, plus vector stubs). Preserves full GPR state, aligns C-call stacks, and executes `clac` when `CR4.SMAP` is enabled.
- **`gdt.s`**: Defines `gdt_flush` for loading the Global Descriptor Table and flushing code (`0x08`) and data (`0x10`) segments.
- **`linker.ld`**: Links the kernel ELF at physical/virtual `1M`, placing `.multiboot` first (8-byte aligned), followed by `.text` (with `.text.boot*`), `.rodata`, `.data`, and `.bss` (4 KiB aligned).

### Kernel Core (`kernel.c`)
`kernel.c` implements the monolithic/hybrid microkernel core and its subsystems, including:
- **Boot & Firmware Handoff**: Multiboot2 GOP framebuffer setup, UEFI `ExitBootServices` handling, ACPI RSDP/MCFG discovery, and serial debug logging (`COM1` / QEMU `debugcon`).
- **Memory Management & Security (`Aegis`)**:
  - Physical Memory Manager (`pmm_init`, `pmm_free_page`), Virtual Memory Manager (`init_vmm_and_sandbox`, `vmm_map_page`, `vmm_is_mapped`), kernel heap (`kmalloc_init` with `HEAP_CANARY` checks), and TSS (`init_tss`).
  - `aegis_cpu_security_init` / `aegis_validate_extended` / `validate_user_pointer` for CPU hardening (e.g., SMAP/SMEP/NX) and Ring 3 pointer validation.
  - Resource Manager (`arkm_rm_*`) tracking per-process memory, storage, handles, IPC, DMA, child processes, and sockets with PID/generation identity.
- **SMP & Scheduling (`AMP`)**:
  - ACPI core discovery (`acpi_probe_cores`) and AP startup via `INIT`/`SIPI` (`wake_up_cores` -> `ap_main`, verified up to 12 CPUs in QEMU).
  - Hybrid Asymmetric Multiprocessing (`AMP_MODE_HYBRID`: `amp_foundation_init`, `amp_rebalance_tasks`, `amp_dispatch_once`) and preemptive `timer_handler` / `scheduler_tick`.
- **Storage & Filesystems (`VFS` & `LUNA`)**:
  - AHCI/SATA (`ata_*`) and PCIe NVMe (`nvme_init`, `nvme_read_blocks`, `nvme_write_blocks`) block drivers, plus optional swap (`swap.img`).
  - FAT32 VFS (`vfs_init`, `vfs_get_file_info`, `vfs_find_file`) for loading Ring 3 ELFs (`APP.ELF`, `DAEMON.ELF`, `WEB.ELF`) and `STATE.BIN`.
  - **LunaFS** (`LUNA_ABI_MAJOR`, `LUNA_FEATURE_LUNAFS`, `luna_init`, `luna_mount`, `luna_self_test`, `sys_luna_query`), backed by `LUNA.VOL` on the FAT32 disk.
- **Hardware & Buses**:
  - PCI Express ECAM (`ecam_init`, `pci_probe`, `pci_enable_msi`) mapped in a dedicated 4–5 GiB virtual aperture, plus IOMMU discovery (`arkm_iommu_discover`).
  - USB xHCI controller driver and HID enumeration (`usb-kbd`, `usb-mouse`) with PS/2 `i8042` fallback (`IRQ1`/`IRQ12`).
- **Networking**:
  - Intel `e1000` NIC driver (`e1000_stub`) and BSD-style socket table (`MAX_SOCKETS`).
  - IPv4, IPv6 (with SLAAC and DAD), ARP cache, TCP, and HTTP server support.
- **Graphics & Window Compositor**:
  - Dynamic RGB GOP framebuffer with a split-screen window compositor (`window_create`, `window_set_active`, `draw_dashboard`, `draw_rect`, `print_string`) providing a console window and a live system dashboard.
- **System Calls (`int $0x80`)**:
  - Supports memory/page allocation, disk read/write proxies, Ring 3 ELF execution (`SYS_RUN_APP`), IPC (`SYS_IPC_SEND`, `SYS_IPC_RECV`), process exit/yield, UI drawing (`SYS_DRAW_RECT`, `SYS_DRAW_TEXT`), and POSIX-like networking (`socket`, `bind`, `listen`, `accept`, `recv`, `send`, `close`).

---

## Ring 3 User-Space Applications

User-space programs are compiled freestanding and linked with `app_linker.ld` (or `app.ld`), then copied onto the FAT32 disk image (`hdd.img`):

| Source | Binary (on `hdd.img`) | Purpose |
| :--- | :--- | :--- |
| `app.c` | `APP.ELF` | **VYOM** Ring 3 test suite (e.g., Aegis pointer breach checks, physical memory guardrails, IPC, UI drawing, and network syscall tests). |
| `daemon.c` | `DAEMON.ELF` | Ring 3 AI Intent Supervisor daemon that announces itself via syscall and polls/replies to IPC messages (`SYS_IPC_RECV` / `SYS_IPC_SEND`). |
| `web.c` | `WEB.ELF` | Single-connection Ring 3 HTTP server listening on port `80` via `int $0x80` socket syscalls (`socket`, `bind`, `listen`, `accept`, `recv`, `send`). |
| `webserver.c` | — | Extended multi-worker (`MAX_WORKERS = 8`) Ring 3 HTTP server implementation using non-blocking/queued `SYS_ACCEPT_NEXT` and `SYS_RECV_FD`. |
| `lib.c` | — | Minimal user-space C library (`libc`) stubs (`malloc`, `open`, `creat`, `close`, `read`, `write`, `lseek`, `puts`, `printf`, `exit`). |

---

## Directory & Key File Layout

```text
arkm-kernel/
├── kernel.c                      # Main 64-bit kernel source (all core subsystems)
├── boot.S                        # Multiboot2 header, _start, long mode, page tables, AP trampoline
├── idt.s                         # idt_flush and all interrupt/exception stubs
├── gdt.s                         # gdt_flush segment loader
├── linker.ld                     # Kernel ELF linker script (linked at 1M)
├── app.c / daemon.c / web.c      # Ring 3 user-space applications
├── webserver.c / lib.c           # Extended Ring 3 web server & minimal libc stubs
├── app_linker.ld / app.ld        # User-space ELF linker scripts
├── build.sh                      # Production build, validation & ISO packaging script
├── run-arkm-uefi-only-qemu.sh    # Primary UEFI-only QEMU diagnostic launcher
├── run-arkm-passt.sh             # Generated Linux/WSL launcher using QEMU passt networking
├── arkm_build_manifest.txt       # Latest build manifest & SHA-256 checksums
├── iso/
│   ├── boot/grub/grub.cfg        # GRUB2 EFI configuration (1280x720x32 GOP + serial)
│   └── EFI/BOOT/BOOTX64.EFI      # ARKM-patched GRUB 2.14 UEFI loader
├── firmware/ovmf/                # OVMF_CODE.fd and OVMF_VARS templates for QEMU
└── hdd.img / swap.img            # 32 MiB FAT32 runtime disk & 8 MiB swap image
```

*(Other `build-*.sh`, `arkm-x5-part1-*.sh`, `.arkm-*-verify/`, and `.grub-2.14-relocator-fix-work/` directories/scripts are diagnostic, GRUB relocator build, and verification artifacts.)*

---

## Quick Start: Building & Launching Live in QEMU

### Prerequisites
The build and runner scripts target an **MSYS2 (UCRT64) / Linux / WSL** environment with:
- `clang` and `ld.lld` (targeting `x86_64-unknown-elf`)
- `nm`, `od`, `dd`, `tr`
- `mtools` (`mformat`, `mcopy`, `mdir`)
- `xorriso`
- `qemu-system-x86_64` with OVMF (`firmware/ovmf/OVMF_CODE.fd` and `firmware/ovmf/OVMF_VARS_TEMPLATE.fd`)
- *(Optional)* WSL with native Linux GCC (used by `build.sh` when building the patched GRUB 2.14 `x86_64-efi` loader from MSYS2) and `passt` (on Linux/WSL for `run-arkm-passt.sh`).

### Step 1: Build the Kernel, Ring 3 Apps, and UEFI ISO
Run the build script from the repository root:
```bash
./build.sh
```
By default, `build.sh`:
- Compiles the Ring 3 applications (`app.c`, `daemon.c`, `webserver.c`) into `app.elf`, `daemon.elf`, and `web.elf`.
- Preserves existing `hdd.img` and `swap.img` (`UPDATE_RUNTIME_DISK=0`). To rebuild and reformat the 32 MiB FAT32 `hdd.img` and 8 MiB `swap.img` with fresh ELFs, run:
  ```bash
  UPDATE_RUNTIME_DISK=1 ./build.sh
  ```
- Compiles `boot.S`, `idt.s`, and `kernel.c` (with `-Wall -Wextra -Werror`) and links `arkm.elf`.
- Verifies required architecture symbols (`AMP`, `LUNA`, `Aegis`, interrupt stub ownership) and packages `arkm-uefi-only-test.iso` with an EFI-only El Torito catalog.
- Writes `arkm_build_manifest.txt` and refreshes `run-arkm-passt.sh`.

Useful build environment overrides:
- `KERNEL_SOURCE=<file.c>` — compile an alternate kernel source file.
- `SMP_CPUS=1` — build/configure for single-CPU (BSP-only) diagnostics.
- `QEMU_PROFILE=legacy` — use the E1000-only device profile (still UEFI).
- `OVMF_CODE=/path/to/code.fd OVMF_VARS=/path/to/vars.fd` — override OVMF firmware paths.

### Step 2: Start the Kernel Live in QEMU (UEFI-Only)
Once `./build.sh` completes, launch the kernel live in QEMU with:
```bash
./run-arkm-uefi-only-qemu.sh
```
This runner:
- Verifies `arkm-uefi-only-test.iso` has an EFI El Torito entry (`-e`) and no legacy BIOS entry (`-b`).
- Copies `hdd.img` to a disposable `hdd-uefi-test.img` (if not already present) and initializes a persistent disposable `OVMF_VARS_arkm-test-persistent.fd` so your original `hdd.img` and OVMF template are never modified.
- Starts `qemu-system-x86_64` on a `q35` machine with `512 MiB` RAM, `12` SMP vCPUs, OVMF pflash, `1280x720` StdVGA graphics, `e1000` NIC (`hostfwd=tcp::8080-:80`), `qemu-xhci` USB keyboard/mouse, `intel-hda` audio, and an interactive QEMU monitor (`-monitor stdio`) in your terminal.

Useful runner environment overrides:
- `QEMU_ACCEL=whpx|kvm|hvf|tcg,thread=multi|auto` (defaults to `tcg,thread=multi` in `run-arkm-uefi-only-qemu.sh`)
- `RAM_MB=512` / `SMP_CPUS=12`
- `RESET_OVMF_VARS=1` — reset the disposable test UEFI variable store from `OVMF_VARS_TEMPLATE.fd`.

For real host IPv6 egress testing on Linux/WSL using `passt`, use the generated launcher:
```bash
./run-arkm-passt.sh
```

---

## How to Test Inside QEMU

Once `./run-arkm-uefi-only-qemu.sh` is running:

1. **Graphical Console & Live Dashboard (QEMU Window)**
   - The QEMU display opens at `1280x720` with the split-screen compositor: the interactive console on the left and the live system dashboard on the right.
   - Use the QEMU window to view kernel output and interact with USB HID keyboard/mouse input.

2. **Interactive QEMU Monitor (Terminal)**
   - Your launch terminal is attached to QEMU's HMP monitor (`-monitor stdio`).
   - Guest shutdown/panic pauses the VM (`-action shutdown=pause,panic=pause`) so you can inspect state in the monitor using commands such as `info cpus`, `info registers`, `info pci`, or `quit` to exit.

3. **Verify Boot & Hardware Milestones (Serial & Timing Logs)**
   - Each run creates timestamped logs in the root directory:
     - `arkm_uefi_serial_<timestamp>.log` — full serial console output. Look for:
       - `[BOOT-TRACE] EFI64 entry reached` and `[UEFI] ExitBootServices PASS`
       - `[BOOT-TRACE] kernel_main entered`
       - `[SMP] final online/discovered=12/12`
       - `[ARKM-QEMU] HAL online`
       - `[ARKM xHCI] enumeration summary` (`controller_ready=1`, `hid_devices=2`)
       - `[ARKM IPv6] SLAAC address passed DAD`
       - `[ARKM-HID] first keyboard usage received` / `first mouse motion report received`
     - `arkm_boot_timing_<timestamp>.log` — elapsed time to reach OVMF BDS, GRUB, `EFI64`, `ExitBootServices`, `kernel_main`, 12-CPU SMP, and LUNA mount.
     - `arkm_uefi_debug_<timestamp>.log`, `arkm_uefi_qemu_<timestamp>.log`, and `arkm_uefi_host_<timestamp>.log` — QEMU debugcon (`0x402`), `guest_errors`/`unimp`/`cpu_reset` trace, and host monitor output.

4. **Run the Ring 3 VYOM Security & Subsystem Tests (`APP.ELF`)**
   - When `APP.ELF` is active in Ring 3, keys `1`–`9` trigger individual VYOM test modules:
     - `1` — Aegis null-pointer and kernel-space pointer validation (`vyom_aegis_breach`)
     - `2` — Physical memory allocation guardrails (`vyom_ram_blast`)
     - `3` — IPC bus stress test (`vyom_apic_storm`)
     - `4` — Ring 3 privilege violation check via `cli` (`vyom_ring_break`)
     - `5` — Microkernel recovery loop via invalid memory dereference (`vyom_micro_supervisor`)
     - `6` — User stack overflow / IST handling (`vyom_stack_hammer`)
     - `7` — Unaligned storage buffer fuzzing (`vyom_disk_fuzzer`)
     - `8` — Ring 3 custom UI drawing via `SYS_DRAW_RECT` / `SYS_DRAW_TEXT` (`vyom_ui_test`)
     - `9` — Raw broadcast Ethernet packet transmission on E1000 (`vyom_net_test`)
   - Press `~` to trigger a disk write test, or `ESC` to exit the Ring 3 sandbox.

5. **Test Ring 3 HTTP Networking (`WEB.ELF`)**
   - `run-arkm-uefi-only-qemu.sh` forwards host TCP port `8080` to guest port `80` (`hostfwd=tcp::8080-:80`).
   - When the Ring 3 web server is running on port `80`, test it from a separate host terminal:
     ```bash
     curl http://localhost:8080
     ```

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](./LICENSE) file for details.
