    .section .text.start, "ax"
    .globl _start
_start:
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
    li      t2, 0
1:
    bgeu    t0, t1, 2f
    sw      t2, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    w3_kws_main
3:
    nop
    j       3b
