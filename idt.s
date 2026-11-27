/*
 * ARKM interrupt/exception entry bridges.
 *
 * IRQ stubs preserve the full GPR set and align the stack before calling C.
 * Exception stubs preserve CPU-pushed error codes instead of popping them,
 * so a recoverable #PF can safely return through IRETQ.
 */
.code64
.section .text

.global idt_flush
.type idt_flush,@function
idt_flush:
    lidt (%rdi)
    ret

.macro SAVE_GPRS
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
.endm

.macro RESTORE_GPRS
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
.endm

/*
 * Align the C-call stack without depending on the interrupted RSP alignment.
 * After SAVE_GPRS, reserve 16 bytes; store the pre-alignment RSP at +8.  The
 * resulting RSP is 16-byte aligned at the CALL instruction and +8 at C entry.
 */
.macro ALIGN_CALL_FRAME
    movq %rsp, %r11
    andq $-16, %rsp
    subq $16, %rsp
    movq %r11, 8(%rsp)
.endm

.macro RESTORE_CALL_FRAME
    movq 8(%rsp), %rsp
.endm

/* Clear inherited user AC before entering any C handler.  The instruction is
 * executed only on CPUs where this kernel enabled CR4.SMAP.  RAX is preserved
 * because all stubs share the interrupted register ABI. */
.macro CLAC_IF_SMAP
    pushq %rax
    movq %cr4, %rax
    btq $21, %rax
    jnc 1f
    clac
1:
    popq %rax
.endm

.global keyboard_stub
.type keyboard_stub,@function
.extern keyboard_handler
keyboard_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    ALIGN_CALL_FRAME
    call keyboard_handler
    RESTORE_CALL_FRAME
    RESTORE_GPRS
    iretq

.global timer_stub
.type timer_stub,@function
.extern timer_handler
timer_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    movq %rsp, %rdi
    movq %rsp, %r11
    andq $-16, %rsp
    subq $16, %rsp
    movq %r11, 8(%rsp)
    call timer_handler

    /*
     * timer_handler returns the saved GPR/IRET frame to resume.  The C
     * cpu_context_t ABI is SAVE_GPRS order followed by the five-qword
     * long-mode IRET frame: RIP, CS, RFLAGS, RSP, SS.  In 64-bit mode the
     * processor saves and IRETQ restores RSP/SS even for same-CPL Ring-0
     * interrupts, so synthetic Ring-0 contexts must initialize both fields.
     */
    testq %rax, %rax
    jnz 1f
    /* Defensive fallback: a null C result means resume the interrupted frame. */
    movq 8(%rsp), %rsp
    jmp 2f
1:
    movq %rax, %rsp
2:
    RESTORE_GPRS
    iretq

.global syscall_stub
.type syscall_stub,@function
.extern syscall_handler
syscall_stub:
    cld
    /* Preserve the caller-visible argument registers and scratch regs. */
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    CLAC_IF_SMAP
    ALIGN_CALL_FRAME
    call syscall_handler
    RESTORE_CALL_FRAME
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    iretq

/* -------------------------------------------------------------------------
 * CPU exceptions 0..31.
 * For vectors that architecturally push an error code, read it without
 * removing it from the CPU frame.  IRETQ therefore sees the original frame.
 * ------------------------------------------------------------------------- */

.macro ISR_NOERR n
.global isr\n\()_stub
.type isr\n\()_stub,@function
isr\n\()_stub:
    xorq %rsi, %rsi
    movq $\n, %rdi
    jmp common_exception
.endm

.macro ISR_ERR n
.global isr\n\()_stub
.type isr\n\()_stub,@function
isr\n\()_stub:
    movq (%rsp), %rsi
    movq $\n, %rdi
    jmp common_exception
.endm

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

.extern exception_handler
.type common_exception,@function
common_exception:
    cld
    /* On entry: RDI=vector, RSI=error code or 0, CPU frame untouched. */
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rdi
    pushq %rsi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    CLAC_IF_SMAP

    /* Preserve the original post-GPR stack while aligning for C. */
    ALIGN_CALL_FRAME
    call exception_handler
    RESTORE_CALL_FRAME

    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rsi
    popq %rdi
    popq %rdx
    popq %rcx
    popq %rax
    iretq

.global mouse_stub
.type mouse_stub,@function
.extern mouse_handler
mouse_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    ALIGN_CALL_FRAME
    call mouse_handler
    RESTORE_CALL_FRAME
    RESTORE_GPRS
    iretq


/* -------------------------------------------------------------------------
 * Kernel-management IPIs.  These use high vectors so they do not collide
 * with the existing 0x20 wake vector, keyboard/mouse IRQ vectors, or MSI
 * vectors.  Handlers only touch the interrupted frame and bounded atomics.
 * ------------------------------------------------------------------------- */
.global arkm_tlb_shootdown_stub
.type arkm_tlb_shootdown_stub,@function
.extern arkm_tlb_shootdown_handler
arkm_tlb_shootdown_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    movq %rsp, %rdi
    ALIGN_CALL_FRAME
    call arkm_tlb_shootdown_handler
    RESTORE_CALL_FRAME
    RESTORE_GPRS
    iretq

/* Dedicated multi-process Ring-3 scheduler IPI. The C handler returns the
 * exact saved frame to resume; F3 never reuses the legacy 0x20 wake vector. */
.global arkm_ring3_scheduler_stub
.type arkm_ring3_scheduler_stub,@function
.extern arkm_ring3_scheduler_ipi_handler
arkm_ring3_scheduler_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    movq %rsp, %rdi
    ALIGN_CALL_FRAME
    call arkm_ring3_scheduler_ipi_handler
    RESTORE_CALL_FRAME
    testq %rax, %rax
    jz 1f
    movq %rax, %rsp
    RESTORE_GPRS
    iretq
1:
    RESTORE_GPRS
    iretq

.global arkm_process_stop_stub
.type arkm_process_stop_stub,@function
.extern arkm_process_stop_ipi_handler
arkm_process_stop_stub:
    cld
    SAVE_GPRS
    CLAC_IF_SMAP
    movq %rsp, %rdi
    ALIGN_CALL_FRAME
    call arkm_process_stop_ipi_handler
    RESTORE_CALL_FRAME
    RESTORE_GPRS
    iretq

/* The stop IPI rewrites a Ring-3 long-mode IRET frame with a kernel RSP/SS
 * and this Ring-0 trampoline. Switch from the per-CPU TSS stack to the
 * dedicated OOM stack before calling C. */
.global arkm_ring3_oom_trampoline
.type arkm_ring3_oom_trampoline,@function
.extern arkm_ring3_oom_exit_c
.extern arkm_ring3_oom_stack
arkm_ring3_oom_trampoline:
    cli
    CLAC_IF_SMAP
    leaq arkm_ring3_oom_stack+8192(%rip), %rsp
    andq $-16, %rsp
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorq %rbp, %rbp
    call arkm_ring3_oom_exit_c
1:
    cli
    hlt
    jmp 1b

/* sys_exit() runs on the process's private kernel stack. The C helper first
 * switches to the kernel page table, releases this process's CPU ownership,
 * restores the AP TSS stack, and returns the saved AP-idle interrupt frame. */
.global arkm_resume_idle_after_ring3
.type arkm_resume_idle_after_ring3,@function
.extern arkm_process_prepare_idle_resume
.extern arkm_process_cpu_idle_loop
arkm_resume_idle_after_ring3:
    cli
    call arkm_process_prepare_idle_resume
    testq %rax, %rax
    jz 2f
    movq %rax, %rsp
    RESTORE_GPRS
    iretq
2:
    call arkm_process_cpu_idle_loop
3:
    cli
    hlt
    jmp 3b

.section .note.GNU-stack,"",@progbits
