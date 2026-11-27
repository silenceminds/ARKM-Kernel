/* gdt.s - Arkm Kernel Memory Segment Loader */
.global gdt_flush
.type gdt_flush, @function

gdt_flush:
    /* Get the pointer to the GDT, passed as a parameter from C */
    mov 4(%esp), %eax  
    lgdt (%eax)        /* Tell the CPU to load our new memory map */

    /* Flush the old data segments and load our new Ring 0 Data Segment (0x10) */
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss

    /* Flush the old code segment and load our new Ring 0 Code Segment (0x08) */
    /* We do this by performing a "far jump" */
    ljmp $0x08, $.flush_cs

.flush_cs:
    ret



