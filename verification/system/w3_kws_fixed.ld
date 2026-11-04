ENTRY(_start)
MEMORY
{
  ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 64K
}
SECTIONS
{
  .text   : { *(.text.start) *(.text*) } > ROM
  .rodata : { *(.rodata*) } > ROM
  .data : {
    . = ALIGN(4);
    __data_start = .;
    *(.data*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT> ROM
  __data_load = LOADADDR(.data);
  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.bss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM
  . = ORIGIN(RAM) + SIZEOF(.data) + SIZEOF(.bss);
  . = ALIGN(16);
  __stack_bottom = .;
  . = . + 8192;
  __stack_top = .;
  ASSERT(SIZEOF(.text) + SIZEOF(.rodata) <= 64K, "ROM overflow")
  ASSERT(__stack_top <= ORIGIN(RAM) + LENGTH(RAM), "RAM/stack overflow")
}
