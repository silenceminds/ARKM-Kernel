.intel_syntax noprefix

/* Stable bootstrap constants. Keep symbol names below compatible with kernel.c. */
.equ ARKM_MB2_MAGIC,              0x36D76289
.equ ARKM_DEBUGCON_PORT,          0x0402
.equ ARKM_CPUID_LEAF_FEATURES,    0x00000001
.equ ARKM_CPUID_LEAF_EXT_MAX,     0x80000000
.equ ARKM_CPUID_LEAF_EXT_FEATURES,0x80000001
.equ ARKM_CPUID_PSE,              (1 << 3)
.equ ARKM_CPUID_PAE,              (1 << 6)
.equ ARKM_CPUID_PGE,              (1 << 13)
.equ ARKM_CPUID_FXSR,             (1 << 24)
.equ ARKM_CPUID_SSE,              (1 << 25)
.equ ARKM_CPUID_SSE2,             (1 << 26)
.equ ARKM_CPUID_NX,               (1 << 20)
.equ ARKM_CPUID_LONG_MODE,        (1 << 29)
.equ ARKM_EFER_MSR,               0xC0000080
.equ ARKM_EFER_LME,               (1 << 8)
.equ ARKM_EFER_NXE,               (1 << 11)
.equ ARKM_CR0_MP,                 (1 << 1)
.equ ARKM_CR0_EM,                 (1 << 2)
.equ ARKM_CR0_TS,                 (1 << 3)
.equ ARKM_CR0_WP,                 (1 << 16)
.equ ARKM_CR0_PG,                 (1 << 31)
.equ ARKM_CR4_PAE,                (1 << 5)
.equ ARKM_CR4_PGE,                (1 << 7)
.equ ARKM_CR4_OSFXSR,             (1 << 9)
.equ ARKM_CR4_OSXMMEXCPT,         (1 << 10)
.equ ARKM_PT_PTR_FLAGS,           0x003
.equ ARKM_PDE_WB_FLAGS,           0x083
.equ ARKM_PDE_UC_FLAGS,           0x09B
.equ ARKM_AP_STACK_SLOTS,         32
.equ ARKM_AP_STACK_SIZE,          8192

/*
 * ARKM x86-64 boot/low-level entry support
 *
 * Ownership:
 *   boot.S -> Multiboot2 header, _start, long-mode transition,
 *             BSP page tables/GDT/stack, AP trampoline.
 *
 *   idt.s  -> idt_flush and ALL interrupt stubs.
 *
 * IMPORTANT:
 *   This file intentionally defines NO *_stub symbols.
 *
 * Bootstrap virtual memory:
 *
 *   PML4[0] -> P3[0..4]
 *       P3[0] -> p2_table       0x00000000 - 0x3fffffff (WB, supervisor)
 *       P3[1] -> p2_mid1_table  0x40000000 - 0x7fffffff (WB, supervisor)
 *       P3[2] -> p2_mid2_table  0x80000000 - 0xbfffffff (WB, supervisor)
 *       P3[3] -> p2_high_table  0xc0000000 - 0xffffffff (UC, supervisor)
 *       P3[4] -> p2_ecam_table  0x100000000 - 0x13fffffff (reserved ECAM VA)
 *
 * These are bootstrap mappings, not the final cache policy. The 0..3-GiB
 * windows start WB for ordinary RAM/firmware data; a PCI BAR discovered inside
 * those ranges MUST be changed to UC with a 4-KiB mapping before its first
 * register access. The 3..4-GiB window starts UC. The boot assembly cannot
 * safely infer all BAR locations from address ranges alone; kernel PCI probing
 * must apply the device-specific mapping before touching registers.
 *
 * The high identity map is required because ARKM accesses:
 *
 *   Local APIC       0xfee00000
 *   Local APIC ID    0xfee00020
 *   Framebuffer      0xfd000000
 *
 * These addresses are outside the original first-1-GiB mapping.
 */

/* ====================================================================== */
/* MULTIBOOT2 HEADER                                                      */
/* ====================================================================== */

.section .multiboot, "a"
.align 8

.global multiboot_header
.type multiboot_header, @object

multiboot_header:
    .long 0xE85250D6
    .long 0                         /* Multiboot2 i386 architecture field. */
    .long multiboot_header_end - multiboot_header
    .long -(0xE85250D6 + (multiboot_header_end - multiboot_header))


    /*
     * The EFI amd64 entry tag is honored on x86-64 EFI only when the EFI
     * boot-services tag is also present.  Both tags are optional so BIOS
     * GRUB continues to enter through the existing i386 protected-mode path.
     */
    .word 7, 1                      /* EFI boot-services support */
    .long 8
    .balign 8

    .word 9, 1                      /* EFI amd64 entry address */
    .long 12
    .long efi64_start
    .balign 8

    /* Request framebuffer and ACPI RSDP information tags. */
    .word 1, 1                      /* Information request tag, optional */
    .long 20
    .long 8
    .long 14
    .long 15
    .balign 8

    /* Request a 1280x720x32 framebuffer; bootloader may choose a supported mode. */
    .word 5, 1                      /* Framebuffer request tag, optional */
    .long 20
    .long 1280                      /* Requested width */
    .long 720                       /* Requested height */
    .long 32                        /* Requested bits per pixel */
    .balign 8

    /* Required Multiboot2 end tag. */
    .word 0
    .word 0
    .long 8

multiboot_header_end:
.size multiboot_header, multiboot_header_end - multiboot_header

/* ====================================================================== */
/* BSP ENTRY                                                              */
/* Multiboot2 transfers control in 32-bit protected mode.                */
/* ====================================================================== */

.section .text.boot, "ax"
.code32

.global _start
.type _start, @function

_start:
    cli
    cld

    /* Validate the Multiboot2 entry contract before touching page tables. */
    cmp eax, ARKM_MB2_MAGIC
    jne .Lstart_bad_magic
    test ebx, ebx
    jz .Lstart_bad_mbi
    test ebx, 7
    jnz .Lstart_bad_mbi

    /* Preserve the boot arguments in registers not clobbered by CPUID. */
    mov edi, eax
    mov esi, ebx

    /* QEMU debugcon marker: BIOS/legacy Multiboot2 entry reached. */
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'B'
    out dx, al

    /*
     * Check every architectural feature used by this bootstrap before
     * installing CR4 bits or 2-MiB PDEs. Preserve CPUID.1:EDX in EBP because
     * subsequent CPUID leaves overwrite EDX.
     */
    mov eax, ARKM_CPUID_LEAF_FEATURES
    xor ecx, ecx
    cpuid
    mov ebp, edx
    test ebp, ARKM_CPUID_PAE
    jz .Lstart_unsupported_cpu
    test ebp, ARKM_CPUID_PSE
    jz .Lstart_unsupported_cpu
    test ebp, ARKM_CPUID_FXSR
    jz .Lstart_unsupported_cpu
    test ebp, ARKM_CPUID_SSE
    jz .Lstart_unsupported_cpu
    test ebp, ARKM_CPUID_SSE2
    jz .Lstart_unsupported_cpu

    mov eax, ARKM_CPUID_LEAF_EXT_MAX
    xor ecx, ecx
    cpuid
    cmp eax, ARKM_CPUID_LEAF_EXT_FEATURES
    jb .Lstart_unsupported_cpu

    mov eax, ARKM_CPUID_LEAF_EXT_FEATURES
    xor ecx, ecx
    cpuid
    test edx, ARKM_CPUID_LONG_MODE
    jz .Lstart_unsupported_cpu

    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'C'
    out dx, al

    /*
     * Temporary BSP stack.
     */
    mov esp, offset stack_top
    and esp, 0xFFFFFFF0

    /*
     * --------------------------------------------------------------
     * PML4[0] -> P3 table
     * --------------------------------------------------------------
     */
    mov eax, offset p3_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p4_table + 0], eax
    mov dword ptr [p4_table + 4], 0

    /*
     * --------------------------------------------------------------
     * P3[0] -> first page directory
     *
     * Covers:
     *      0x00000000 - 0x3fffffff
     *
     * = first 1 GiB
     * --------------------------------------------------------------
     */
    mov eax, offset p2_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p3_table + 0], eax
    mov dword ptr [p3_table + 4], 0

    /* P3[1] -> 1-GiB..2-GiB identity window. */
    mov eax, offset p2_mid1_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p3_table + 8], eax
    mov dword ptr [p3_table + 12], 0

    /* P3[2] -> 2-GiB..3-GiB identity window. */
    mov eax, offset p2_mid2_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p3_table + 16], eax
    mov dword ptr [p3_table + 20], 0

    /*
     * --------------------------------------------------------------
     * P3[3] -> high page directory
     *
     * Covers:
     *      0xc0000000 - 0xffffffff
     *
     * This is the critical MMIO mapping.
     * --------------------------------------------------------------
     */
    mov eax, offset p2_high_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p3_table + 24], eax
    mov dword ptr [p3_table + 28], 0

    /* P3[4] reserves the 4-5 GiB virtual aperture for ACPI MCFG/ECAM. */
    mov eax, offset p2_ecam_table
    or eax, ARKM_PT_PTR_FLAGS
    mov dword ptr [p3_table + 32], eax
    mov dword ptr [p3_table + 36], 0
    xor ecx, ecx
.Lclear_p2_ecam:
    mov dword ptr [p2_ecam_table + ecx*8], 0
    mov dword ptr [p2_ecam_table + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 512
    jb .Lclear_p2_ecam

    /*
     * --------------------------------------------------------------
     * Fill low 2-MiB identity map.
     *
     * PDE:
     *      physical = index * 2 MiB
     * --------------------------------------------------------------
     */
    xor ecx, ecx

.Lfill_p2_low:
    mov eax, ecx
    shl eax, 21

    /*
     * 0x083:
     *      Present | Read/write | Page Size (2 MiB)
     *      U/S is clear: this early identity map is supervisor-only.
     */
    or eax, ARKM_PDE_WB_FLAGS

    mov dword ptr [p2_table + ecx*8], eax
    mov dword ptr [p2_table + ecx*8 + 4], 0

    inc ecx
    cmp ecx, 512
    jb .Lfill_p2_low

    /* Fill 1-GiB..2-GiB with supervisor-only 2-MiB WB leaves. */
    xor ecx, ecx
.Lfill_p2_mid1:
    mov eax, ecx
    shl eax, 21
    add eax, 0x40000000
    or eax, ARKM_PDE_WB_FLAGS
    mov dword ptr [p2_mid1_table + ecx*8], eax
    mov dword ptr [p2_mid1_table + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 512
    jb .Lfill_p2_mid1

    /* Fill 2-GiB..3-GiB with supervisor-only 2-MiB WB leaves. */
    xor ecx, ecx
.Lfill_p2_mid2:
    mov eax, ecx
    shl eax, 21
    add eax, 0x80000000
    or eax, ARKM_PDE_WB_FLAGS
    mov dword ptr [p2_mid2_table + ecx*8], eax
    mov dword ptr [p2_mid2_table + ecx*8 + 4], 0
    inc ecx
    cmp ecx, 512
    jb .Lfill_p2_mid2

    /*
     * --------------------------------------------------------------
     * Fill high 3-GiB..4-GiB identity map.
     *
     * P3[3] represents virtual addresses:
     *
     *      0xc0000000 - 0xffffffff
     *
     * Each PDE covers 2 MiB.
     * --------------------------------------------------------------
     */
    xor ecx, ecx

.Lfill_p2_high:
    mov eax, 0xC0000000

    mov edx, ecx
    shl edx, 21

    add eax, edx
    /* UC bootstrap leaves: P | RW | PWT | PCD | PS; supervisor-only. */
    or eax, ARKM_PDE_UC_FLAGS

    mov dword ptr [p2_high_table + ecx*8], eax
    mov dword ptr [p2_high_table + ecx*8 + 4], 0

    inc ecx
    cmp ecx, 512
    jb .Lfill_p2_high

    /*
     * --------------------------------------------------------------
     * Enable PAE.
     * --------------------------------------------------------------
     */
    mov eax, cr4
    /* Do not carry stale global TLB entries into ARKM's new hierarchy. */
    and eax, ~(ARKM_CR4_PGE | ARKM_CR4_OSFXSR | ARKM_CR4_OSXMMEXCPT)
    or eax, ARKM_CR4_PAE | ARKM_CR4_OSFXSR | ARKM_CR4_OSXMMEXCPT
    mov cr4, eax

    /*
     * --------------------------------------------------------------
     * Load PML4 into CR3.
     * --------------------------------------------------------------
     */
    mov eax, offset p4_table
    mov cr3, eax

    /* PGE is optional; enable it only after the new root is active. */
    test ebp, ARKM_CPUID_PGE
    jz .Lbsp_pge_ready
    mov eax, cr4
    or eax, ARKM_CR4_PGE
    mov cr4, eax
.Lbsp_pge_ready:

    /*
     * --------------------------------------------------------------
     * Enable long mode in EFER.
     * --------------------------------------------------------------
     */
    /* Long mode is mandatory here; NXE is enabled only when CPUID advertises NX. */
    mov eax, ARKM_CPUID_LEAF_EXT_FEATURES
    xor ecx, ecx
    cpuid
    test edx, ARKM_CPUID_NX
    jz .Lbsp_enable_lme_only

    mov ecx, ARKM_EFER_MSR
    rdmsr
    or eax, ARKM_EFER_LME | ARKM_EFER_NXE
    wrmsr
    jmp .Lbsp_efer_ready

.Lbsp_enable_lme_only:
    mov ecx, ARKM_EFER_MSR
    rdmsr
    or eax, ARKM_EFER_LME
    wrmsr

.Lbsp_efer_ready:

    /*
     * --------------------------------------------------------------
     * Enable paging and supervisor write-protect semantics.
     *
     * Protected mode is already active.
     * --------------------------------------------------------------
     */
    mov eax, cr0
    and eax, ~(ARKM_CR0_EM | ARKM_CR0_TS) /* clear CR0.EM and CR0.TS */
    or eax, ARKM_CR0_MP | ARKM_CR0_PG | ARKM_CR0_WP
    mov cr0, eax

    /*
     * --------------------------------------------------------------
     * Load ARKM 64-bit GDT.
     * --------------------------------------------------------------
     */
    mov eax, offset gdt64_ptr
    lgdt [eax]

    /*
     * --------------------------------------------------------------
     * 32-bit protected-mode -> 64-bit long-mode far jump.
     *
     * This is intentionally encoded manually.
     * --------------------------------------------------------------
     */
    .byte 0xEA
    .long long_mode_start
    .word 0x0008

/* Early entry failures report one byte on QEMU debugcon, then park safely. */
.Lstart_bad_magic:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, '!'
    out dx, al
    jmp .Lstart_fail

.Lstart_bad_mbi:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'M'
    out dx, al
    jmp .Lstart_fail

.Lstart_unsupported_cpu:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'U'
    out dx, al

.Lstart_fail:
    cli
.Lstart_fail_halt:
    hlt
    jmp .Lstart_fail_halt

/* ====================================================================== */
/* BSP LONG MODE                                                          */
/* ====================================================================== */

.code64

.global long_mode_start
.type long_mode_start, @function

long_mode_start:

    /*
     * Explicit Ring-0 data selector.
     *
     * 0x10 = GDT entry 2 = kernel data.
     */
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    /*
     * FS/GS unused during early bootstrap.
     */
    xor eax, eax
    mov fs, ax
    mov gs, ax

    /* Enforce supervisor write-protect semantics as soon as the kernel runs. */
    mov rax, cr0
    and eax, ~(ARKM_CR0_EM | ARKM_CR0_TS) /* clear CR0.EM and CR0.TS */
    or eax, ARKM_CR0_MP | ARKM_CR0_WP
    mov cr0, rax

    /*
     * BSP stack.
     */
    mov rsp, offset stack_top
    and rsp, -16

    /* Non-invasive checkpoint: do not assume legacy VGA text memory exists. */
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'L'
    out dx, al

    /*
     * Enter the C kernel.
     */
    .extern kernel_main
    mov rax, offset kernel_main
    call rax

.Lbsp_halt:
    cli
    hlt
    jmp .Lbsp_halt

/* ====================================================================== */
/* EFI AMD64 ENTRY                                                        */
/* Multiboot2 EFI entry tag 9 transfers here in 64-bit mode.              */
/* EFI boot services are explicitly terminated before replacing CR3.      */
/* ====================================================================== */

.code64
.global efi64_start
.type efi64_start, @function

.extern arkm_efi_prepare_multiboot2

efi64_start:
    cli
    cld

    /* EAX is the Multiboot2 magic; RBX is the 64-bit MBI physical pointer. */
    cmp eax, ARKM_MB2_MAGIC
    jne .Lefi_entry_bad_magic
    test rbx, rbx
    jz .Lefi_entry_bad_mbi
    test rbx, 7
    jnz .Lefi_entry_bad_mbi

    /* Use the kernel-owned stack while UEFI identity mappings are active. */
    mov rsp, offset stack_top
    and rsp, -16
    mov rdi, rbx

    /* Initializes serial diagnostics, captures the GOP framebuffer tag,
       and calls ExitBootServices if Multiboot2 reports services still live. */
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'E'
    out dx, al
    call arkm_efi_prepare_multiboot2
    test eax, eax
    jz .Lefi_entry_halt

    /* Already executing in long mode; verify features needed by ARKM's
     * 2-MiB bootstrap leaves and its FPU/SSE control-register setup. */
    mov eax, ARKM_CPUID_LEAF_FEATURES
    xor ecx, ecx
    cpuid
    mov r12d, edx
    test r12d, ARKM_CPUID_PSE
    jz .Lefi_unsupported_cpu
    test r12d, ARKM_CPUID_FXSR
    jz .Lefi_unsupported_cpu
    test r12d, ARKM_CPUID_SSE
    jz .Lefi_unsupported_cpu
    test r12d, ARKM_CPUID_SSE2
    jz .Lefi_unsupported_cpu

    /* NXE is per logical CPU. Enable it on the BSP before kernel code creates
     * any page-table entry with the NX bit set. The kernel also checks NX support
     * before advertising/enabling NX policy. */
    mov eax, ARKM_CPUID_LEAF_EXT_MAX
    xor ecx, ecx
    cpuid
    cmp eax, ARKM_CPUID_LEAF_EXT_FEATURES
    jb .Lefi_nxe_checked
    mov eax, ARKM_CPUID_LEAF_EXT_FEATURES
    xor ecx, ecx
    cpuid
    test edx, ARKM_CPUID_NX
    jz .Lefi_nxe_checked
    mov ecx, ARKM_EFER_MSR
    rdmsr
    or eax, ARKM_EFER_NXE
    wrmsr
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'N'
    out dx, al
.Lefi_nxe_checked:

    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'P'
    out dx, al

    /*
     * Build the 0-4 GiB identity map with supervisor-only leaves and
     * reserve P3[4] as an empty 4-5 GiB ECAM virtual aperture.
     * The 3-GiB..4-GiB bootstrap window is UC; device helpers may refine
     * individual BARs and the framebuffer cache type later.
     * The firmware page tables are still active until this point, so all
     * EFI services and MBI reads have completed before CR3 is replaced.
     */
    lea rdi, [rip + p4_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p3_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p2_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p2_mid1_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p2_mid2_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p2_high_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rdi, [rip + p2_ecam_table]
    xor eax, eax
    mov ecx, 512
    rep stosq

    lea rax, [rip + p3_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p4_table], rax

    lea rax, [rip + p2_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p3_table], rax

    lea rax, [rip + p2_mid1_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p3_table + 8], rax

    lea rax, [rip + p2_mid2_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p3_table + 16], rax

    lea rax, [rip + p2_high_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p3_table + 24], rax

    /* Reserve P3[4] for the dedicated 4-5 GiB ECAM virtual aperture. */
    lea rax, [rip + p2_ecam_table]
    or rax, ARKM_PT_PTR_FLAGS
    mov qword ptr [rip + p3_table + 32], rax

    xor ecx, ecx
    lea rdi, [rip + p2_table]
.Lefi_fill_p2_low:
    mov rax, rcx
    shl rax, 21
    or rax, ARKM_PDE_WB_FLAGS
    mov qword ptr [rdi + rcx*8], rax
    inc ecx
    cmp ecx, 512
    jb .Lefi_fill_p2_low

    xor ecx, ecx
    lea rdi, [rip + p2_mid1_table]
.Lefi_fill_p2_mid1:
    mov rax, rcx
    shl rax, 21
    add rax, 0x40000000
    or rax, ARKM_PDE_WB_FLAGS
    mov qword ptr [rdi + rcx*8], rax
    inc ecx
    cmp ecx, 512
    jb .Lefi_fill_p2_mid1

    xor ecx, ecx
    lea rdi, [rip + p2_mid2_table]
.Lefi_fill_p2_mid2:
    mov rax, rcx
    shl rax, 21
    mov edx, 0x80000000
    add rax, rdx
    or rax, ARKM_PDE_WB_FLAGS
    mov qword ptr [rdi + rcx*8], rax
    inc ecx
    cmp ecx, 512
    jb .Lefi_fill_p2_mid2

    xor ecx, ecx
    lea rdi, [rip + p2_high_table]
.Lefi_fill_p2_high:
    mov rax, 0xC0000000
    mov edx, ecx
    shl rdx, 21
    add rax, rdx
    or rax, ARKM_PDE_UC_FLAGS
    mov qword ptr [rdi + rcx*8], rax
    inc ecx
    cmp ecx, 512
    jb .Lefi_fill_p2_high

    /*
     * Prepare CR4 before installing ARKM's hierarchy. Clear PGE first so
     * loading the new CR3 flushes any global translations inherited from
     * firmware; re-enable PGE only after the new hierarchy is active.
     */
    mov rax, cr4
    btr rax, 7
    or rax, ARKM_CR4_PAE | ARKM_CR4_OSFXSR | ARKM_CR4_OSXMMEXCPT
    mov cr4, rax
    lea rax, [rip + p4_table]
    mov cr3, rax
    test r12d, ARKM_CPUID_PGE
    jz .Lefi_pge_ready
    mov rax, cr4
    bts rax, 7
    mov cr4, rax
.Lefi_pge_ready:

    /* Install ARKM's GDT and reload CS before using selector 0x10. */
    lgdt [rip + gdt64_ptr]
    push 0x08
    lea rax, [rip + .Lefi_gdt_reloaded]
    push rax
    retfq

.Lefi_gdt_reloaded:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    /* Firmware services are finished and ARKM's page tables are active. */
    mov rax, cr0
    and eax, ~(ARKM_CR0_EM | ARKM_CR0_TS) /* clear CR0.EM and CR0.TS */
    or eax, ARKM_CR0_MP | ARKM_CR0_WP
    mov cr0, rax

    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'M'
    out dx, al

    /* EFI-specific continuation: do not touch legacy VGA text memory. */
    xor eax, eax
    mov fs, ax
    mov gs, ax
    mov rsp, offset stack_top
    and rsp, -16

    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'K'
    out dx, al
    .extern kernel_main
    mov rax, offset kernel_main
    call rax

.Lefi_kernel_return:
    cli
    hlt
    jmp .Lefi_kernel_return

.Lefi_unsupported_cpu:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'U'
    out dx, al
    jmp .Lefi_entry_halt

.Lefi_entry_bad_magic:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, '!'
    out dx, al
    jmp .Lefi_entry_halt
.Lefi_entry_bad_mbi:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'M'
    out dx, al
.Lefi_entry_halt:
    cli
    hlt
    jmp .Lefi_entry_halt

/* ====================================================================== */
/* AP TRAMPOLINE                                                          */
/* Copied byte-for-byte by kernel code to physical 0x8000.               */
/* ====================================================================== */

.section .text.trampoline, "ax"
.align 16

.code16

.global ap_trampoline
.global ap_trampoline_end
.type ap_trampoline, @function

/*
 * Relocated physical addresses after copying this block to 0x8000.
 *
 * AP_GDT_PTR_PHYS:
 *     Address of the 6-byte temporary GDT descriptor.
 *
 * AP_GDT_PHYS:
 *     Address of the actual temporary GDT.
 *
 * AP_PMODE_PHYS:
 *     Protected-mode entry point.
 *
 * AP_LM_PHYS:
 *     Long-mode entry point.
 */
.equ AP_GDT_PTR_PHYS, (ap_gdt_ptr_real - ap_trampoline + 0x8000)
.equ AP_GDT_PHYS,     (ap_gdt          - ap_trampoline + 0x8000)
.equ AP_PMODE_PHYS,   (ap_pmode       - ap_trampoline + 0x8000)
.equ AP_LM_PHYS,      (ap_long_mode   - ap_trampoline + 0x8000)

ap_trampoline:
    cli
    cld

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    /*
     * --------------------------------------------------------------
     * Load temporary relocated AP GDT.
     *
     * IMPORTANT:
     * OFFSET is required here.
     *
     * Without OFFSET:
     *
     *     mov bx, AP_GDT_PTR_PHYS
     *
     * was encoded as a memory load:
     *
     *     mov bx, [0x8088]
     *
     * which loaded the GDT LIMIT (0x17) into BX.
     *
     * With OFFSET:
     *
     *     BX = 0x8088
     *     LGDT [0x8088]
     *
     * --------------------------------------------------------------
     */
    mov bx, OFFSET AP_GDT_PTR_PHYS
    lgdt [bx]

    /*
     * Enter protected mode.
     */
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    /*
     * --------------------------------------------------------------
     * Real mode -> 32-bit protected mode.
     *
     * Operand-size override is required here because the AP starts
     * in 16-bit real mode and the target offset is 32-bit.
     * --------------------------------------------------------------
     */
    .byte 0x66, 0xEA
    .long AP_PMODE_PHYS
    .word 0x0008

/* ====================================================================== */
/* AP PROTECTED MODE                                                      */
/* ====================================================================== */

.code32
.align 4

ap_pmode:

    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    /* AP reached protected mode; useful when the AP fails before ap_main. */
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'a'
    out dx, al

    /* Verify architectural prerequisites before attempting long mode. */
    mov eax, ARKM_CPUID_LEAF_FEATURES
    xor ecx, ecx
    cpuid
    mov ebp, edx
    test ebp, ARKM_CPUID_PAE
    jz .Lap_unsupported
    test ebp, ARKM_CPUID_PSE
    jz .Lap_unsupported
    test ebp, ARKM_CPUID_FXSR
    jz .Lap_unsupported
    test ebp, ARKM_CPUID_SSE
    jz .Lap_unsupported
    test ebp, ARKM_CPUID_SSE2
    jz .Lap_unsupported

    mov eax, ARKM_CPUID_LEAF_EXT_MAX
    xor ecx, ecx
    cpuid
    cmp eax, ARKM_CPUID_LEAF_EXT_FEATURES
    jb .Lap_unsupported

    mov eax, ARKM_CPUID_LEAF_EXT_FEATURES
    xor ecx, ecx
    cpuid
    test edx, ARKM_CPUID_LONG_MODE
    jz .Lap_unsupported

    /* NX is a system-wide policy once the BSP initialized Aegis. If the BSP
     * requires NX but this AP cannot implement it, park this AP before it
     * adopts page tables that may contain NX PTEs. */
    .extern aegis_nxe_enabled
    test edx, ARKM_CPUID_NX
    jnz .Lap_nx_supported
    mov ebx, offset aegis_nxe_enabled
    cmp byte ptr [ebx], 0
    jne .Lap_nx_policy_mismatch
.Lap_nx_supported:

    /* Install feature-safe CR4 state, then activate the shared PAE hierarchy. */
    mov eax, cr4
    and eax, ~(ARKM_CR4_PGE | ARKM_CR4_OSFXSR | ARKM_CR4_OSXMMEXCPT)
    or eax, ARKM_CR4_PAE | ARKM_CR4_OSFXSR | ARKM_CR4_OSXMMEXCPT
    mov cr4, eax
    mov eax, offset p4_table
    mov cr3, eax

    /* Re-enable optional PGE only after the shared root has replaced old state. */
    test ebp, ARKM_CPUID_PGE
    jz .Lap_pge_ready
    mov eax, cr4
    or eax, ARKM_CR4_PGE
    mov cr4, eax
.Lap_pge_ready:

    /* EFER is per logical CPU; preserve its existing upper half. */
    test edx, ARKM_CPUID_NX
    jz .Lap_enable_lme_only

    mov ecx, ARKM_EFER_MSR
    rdmsr
    or eax, ARKM_EFER_LME | ARKM_EFER_NXE
    wrmsr
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'n'
    out dx, al
    jmp .Lap_efer_ready

.Lap_enable_lme_only:
    mov ecx, ARKM_EFER_MSR
    rdmsr
    or eax, ARKM_EFER_LME
    wrmsr
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'x'
    out dx, al
    jmp .Lap_efer_ready

.Lap_nx_policy_mismatch:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'X'
    out dx, al
    jmp .Lap_unsupported

.Lap_unsupported:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, '!'
    out dx, al
    cli
.Lap_unsupported_halt:
    hlt
    jmp .Lap_unsupported_halt

.Lap_efer_ready:
    /* Enter long mode with supervisor write protection enabled. */
    mov eax, cr0
    and eax, ~(ARKM_CR0_EM | ARKM_CR0_TS) /* clear CR0.EM and CR0.TS */
    or eax, ARKM_CR0_MP | ARKM_CR0_PG | ARKM_CR0_WP
    mov cr0, eax

    /*
     * Load BSP 64-bit GDT.
     */
    mov eax, offset gdt64_ptr
    lgdt [eax]

    /*
     * Protected mode -> long mode.
     */
    .byte 0xEA
    .long AP_LM_PHYS
    .word 0x0008

/* ====================================================================== */
/* AP TEMPORARY GDT                                                       */
/* ====================================================================== */

.align 8

ap_gdt:
    .quad 0x0000000000000000
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF

ap_gdt_end:

/*
 * 6-byte real-mode GDTR:
 *
 *   limit = 0x17
 *   base  = relocated physical address of ap_gdt
 *
 * For the current layout this becomes:
 *
 *   17 00 70 80 00 00
 */
ap_gdt_ptr_real:
    .word ap_gdt_end - ap_gdt - 1
    .long AP_GDT_PHYS

/* ====================================================================== */
/* AP LONG MODE                                                           */
/* ====================================================================== */

.code64

ap_long_mode:

    /* Explicit Ring-0 data selector. */
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'l'
    out dx, al

    xor eax, eax
    mov fs, ax
    mov gs, ax

    /*
     * Load kernel IDT.
     */
    .extern idtp
    mov rbx, offset idtp
    lidt [rbx]

    /*
     * Match the same APIC-ID source and logical-slot table as kernel.c:
     * CPUID.1:EBX[31:24] and local_apic_ids[slot]. Do not assume APIC IDs
     * are contiguous or use an ID as an array index. Kernel C must finish
     * populating these globals before sending INIT/SIPI to any AP.
     */
    mov eax, ARKM_CPUID_LEAF_FEATURES
    xor ecx, ecx
    cpuid
    mov r8d, ebx
    shr r8d, 24
    and r8d, 0xFF

    .extern local_apic_ids
    .extern total_cpu_cores
    /* This block is copied to 0x8000, so use linked absolute symbols rather
     * than RIP-relative addresses whose displacement would be wrong after copy. */
    mov rdi, offset local_apic_ids
    mov rdx, offset total_cpu_cores
    mov ecx, dword ptr [rdx]
    test ecx, ecx
    jz .Lap_bad_apic_id
    cmp ecx, ARKM_AP_STACK_SLOTS
    ja .Lap_bad_apic_id

    xor r10d, r10d
.Lap_find_logical_slot:
    movzx edx, byte ptr [rdi + r10]
    cmp edx, r8d
    je .Lap_logical_slot_found
    inc r10d
    cmp r10d, ecx
    jb .Lap_find_logical_slot
    jmp .Lap_bad_apic_id

.Lap_logical_slot_found:
    /* Kernel ABI: ring0_stack_ap_array[logical_slot][8192]. */
    mov ecx, r10d
    imul ecx, ARKM_AP_STACK_SIZE
    mov rbx, offset ring0_stack_ap_array
    mov rsp, rbx
    add rsp, rcx
    add rsp, ARKM_AP_STACK_SIZE
    and rsp, -16

    /*
     * Enter AP C entry point.
     */
    .extern ap_main
    mov rax, offset ap_main
    call rax

.Lap_halt:
    cli
    hlt
    jmp .Lap_halt

.Lap_bad_apic_id:
    mov dx, ARKM_DEBUGCON_PORT
    mov al, 'I'
    out dx, al
    cli
.Lap_bad_apic_id_halt:
    hlt
    jmp .Lap_bad_apic_id_halt

/*
 * End of copied AP trampoline.
 */
ap_trampoline_end:
.size ap_trampoline, ap_trampoline_end - ap_trampoline
/* The build-time validator checks that this copied block stays below 4 KiB. */

/* ====================================================================== */
/* BSP PAGE TABLES / STACK                                                */
/* ====================================================================== */

.section .data.boot, "aw"

/*
 * PML4
 */
.align 4096
.global p4_table
.type p4_table, @object

p4_table:
    .skip 4096
.size p4_table, . - p4_table

/*
 * Page-directory-pointer table.
 */
.align 4096
.global p3_table
.type p3_table, @object

p3_table:
    .skip 4096
.size p3_table, . - p3_table

/*
 * Low page directory:
 *
 *     0x00000000 - 0x3fffffff
 */
.align 4096
.global p2_table
.type p2_table, @object

p2_table:
    .skip 4096
.size p2_table, . - p2_table

/* 1-GiB..2-GiB supervisor WB identity directory (P3[1]). */
.align 4096
.global p2_mid1_table
.type p2_mid1_table, @object
p2_mid1_table:
    .skip 4096
.size p2_mid1_table, . - p2_mid1_table

/* 2-GiB..3-GiB supervisor WB identity directory (P3[2]). */
.align 4096
.global p2_mid2_table
.type p2_mid2_table, @object
p2_mid2_table:
    .skip 4096
.size p2_mid2_table, . - p2_mid2_table

/*
 * High page directory:
 *
 *     0xc0000000 - 0xffffffff
 *
 * Required for:
 *
 *     0xfd000000 framebuffer
 *     0xfee00000 Local APIC
 */
.align 4096
.global p2_high_table
.type p2_high_table, @object

p2_high_table:
    .skip 4096
.size p2_high_table, . - p2_high_table

/*
 * Dedicated ECAM virtual page directory for P3[4]. The 4-5 GiB virtual
 * window is intentionally left unmapped here; kernel.c fills 2-MiB UC
 * leaves from validated ACPI MCFG physical ranges during ecam_init().
 */
.align 4096
.global p2_ecam_table
.type p2_ecam_table, @object
p2_ecam_table:
    .skip 4096
.size p2_ecam_table, . - p2_ecam_table

/* ====================================================================== */
/* BSP STACK                                                              */
/* ====================================================================== */

.align 4096
.global stack_bottom
.type stack_bottom, @object

stack_bottom:
    .skip 32768

.global stack_top
.type stack_top, @object

stack_top:

/*
 * Keep a page-aligned layout gap between the BSP stack and GDT.
 * IMPORTANT: the bootstrap 2-MiB identity PDEs still map this gap; it is
 * not a hardware-enforced guard page until a later VMM installs 4-KiB
 * mappings and leaves the guard page absent.
 */
.skip 4096

/* ====================================================================== */
/* ARKM GDT                                                               */
/* ====================================================================== */

.global gdt64_code
.equ gdt64_code, 0x08

.global gdt64_data
.equ gdt64_data, 0x10

.global gdt64_user_data
.equ gdt64_user_data, 0x18

.global gdt64_user_code
.equ gdt64_user_code, 0x20

.global gdt64_tss
.equ gdt64_tss, 0x28

/*
 * Put GDT on a completely separate 4-KiB page.
 */
.align 4096

gdt64:

    /* 0x00: null */
    .quad 0x0000000000000000

    /* 0x08: Ring-0 64-bit code */
    .quad 0x00209A0000000000

    /* 0x10: Ring-0 data */
    .quad 0x0000920000000000

    /* 0x18: Ring-3 data */
    .quad 0x0000F20000000000

    /* 0x20: Ring-3 64-bit code */
    .quad 0x0020FA0000000000

    /* 0x28: TSS low */
    .quad 0x0000890000000067

    /* 0x30: TSS high */
    .quad 0x0000000000000000

gdt64_end:

/*
 * 10-byte GDT pointer.
 */
.align 8

.global gdt64_ptr
.type gdt64_ptr, @object

gdt64_ptr:
    .word gdt64_end - gdt64 - 1
    .quad gdt64

/*
 * Compatibility alias.
 */
.global gdt64_pointer
gdt64_pointer = gdt64_ptr

/*
 * Compatibility alias retained for older kernel code.
 */
.global ap_stacks_bottom
.extern ring0_stack_ap_array

ap_stacks_bottom = ring0_stack_ap_array

/* ====================================================================== */
/* GNU STACK MARKER                                                       */
/* ====================================================================== */

.section .note.GNU-stack,"",@progbits
