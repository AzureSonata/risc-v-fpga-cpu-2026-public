/* Fixed, repository-owned yes feature tensor used by the W3 system image. */
    .section .rodata.w3_kws_fixture, "a", @progbits
    .balign 4
    .globl w3_kws_yes_fixture
    .type w3_kws_yes_fixture, @object
w3_kws_yes_fixture:
    .incbin "verification/kws/k2/vectors/yes_1000ms_real49/layer_00_RESHAPE_out_04.bin"
    .size w3_kws_yes_fixture, .-w3_kws_yes_fixture
