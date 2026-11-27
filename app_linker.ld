ENTRY(_start)

SECTIONS
{
    /* Tell the kernel to load this APP exactly at the 1GB boundary */
    . = 0x40000000;

    /* The Code Section: Align to a 4KB boundary */
    .text ALIGN(0x1000) :
    {
        *(.text*)
    }

    /* Read-Only Data (Strings): Align to the NEXT 4KB boundary */
    .rodata ALIGN(0x1000) :
    {
        *(.rodata*)
        *(.lrodata*)
    }

    /* Read/Write Data: Align to the NEXT 4KB boundary */
    .data ALIGN(0x1000) :
    {
        *(.data*)
    }

    /* Uninitialized Data: Align to the NEXT 4KB boundary */
    .bss ALIGN(0x1000) :
    {
        *(COMMON)
        *(.bss*)
    }
}