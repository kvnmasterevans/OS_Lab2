OUTPUT_ARCH( "riscv" )
ENTRY( _main )

/* Separate program headers so code is read-only and data is not
   executable. Without these, newer linkers emit a single RWX segment and
   user code is writable (usertests textwrite fails). exec() maps each
   segment with permissions from its flags. 5 = R+X, 6 = R+W. */
PHDRS
{
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}

SECTIONS
{
 . = 0x0;
 
  .text : {
    *(.text .text.*)
  } :text

  .rodata : {
    . = ALIGN(16);
    *(.srodata .srodata.*) /* do not need to distinguish this from .rodata */
    . = ALIGN(16);
    *(.rodata .rodata.*)
    . = ALIGN(0x1000);
  } :text

  /* Page-align explicitly: unlisted sections such as .eh_frame land
     after .rodata, and exec() requires each segment to start on a page. */
  .data : ALIGN(0x1000) {
    . = ALIGN(16);
    *(.sdata .sdata.*) /* do not need to distinguish this from .data */
    . = ALIGN(16);
    *(.data .data.*)
  } :data

  .bss : {
    . = ALIGN(16);
    *(.sbss .sbss.*) /* do not need to distinguish this from .bss */
    . = ALIGN(16);
    *(.bss .bss.*)
  } :data

  PROVIDE(end = .);
}
