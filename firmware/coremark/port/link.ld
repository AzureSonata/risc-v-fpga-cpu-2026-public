/* ROM_BYTES/RAM_BYTES/STACK_BYTES supplied by the build, not assumed hardware. */
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = ROM_BYTES
    RAM (rw) : ORIGIN = 0x80000000, LENGTH = RAM_BYTES
}
SECTIONS {
    .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) . = ALIGN(4); } > ROM
    .data : {
        . = ALIGN(4); __data_start = .;
        __global_pointer$ = . + 0x800;
        *(.data*) *(.sdata*) . = ALIGN(4); __data_end = .;
    } > RAM AT > ROM
    __data_load_start = LOADADDR(.data);
    __rom_image_end = LOADADDR(.data) + SIZEOF(.data);
    .bss (NOLOAD) : {
        . = ALIGN(4); __bss_start = .;
        *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .;
    } > RAM
    __stack_top = (ORIGIN(RAM) + LENGTH(RAM)) & ~15;
    __stack_bottom = __stack_top - STACK_BYTES;
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(STACK_BYTES > 0 && STACK_BYTES % 16 == 0, "Stack must be positive and 16-byte aligned")
ASSERT(__bss_end <= __stack_bottom, "Data/BSS/stack exceed the declared actual RAM capacity")
ASSERT(__rom_image_end <= ORIGIN(ROM) + LENGTH(ROM), "Program exceeds the declared actual ROM capacity")
