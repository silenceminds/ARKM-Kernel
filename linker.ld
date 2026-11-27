ENTRY(_start)

SECTIONS
{
    /* Physical/virtual load address used by the Multiboot2 ELF image. */
    . = 1M;

    __load_start = .;

    /* Multiboot2 header: keep it early, 8-byte aligned, and retained. */
    .multiboot ALIGN(8) :
    {
        KEEP(*(.multiboot))
    }

    .text ALIGN(4K) :
    {
        *(.text.boot*)
        *(.text)
        *(.text.*)
    }

    .rodata ALIGN(4K) :
    {
        *(.rodata*)
    }

    .data ALIGN(4K) :
    {
        *(.data*)
    }

    __load_end = .;

    .bss ALIGN(4K) :
    {
        *(COMMON)
        *(.bss*)
    }

    __bss_end = .;

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
    }
}
