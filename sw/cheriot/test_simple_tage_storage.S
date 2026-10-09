# simple test for capability store und loads
# this should verify the tag storage

    .section .text
    .globl   main

#define CHERIOT_ENABLE (0x03000018)
#define CORE_STATUS (0x03000008)

#define TEST_ADDRESS_CAP (0x10000C00)
#define TEST_ADDRESS_BANK1 (0x10000800)

main:
    li       t1, 1
    li       t2, CHERIOT_ENABLE
    sw       t1, 0(t2)              # enable cheriot

    .word    0x03d001db             # cspecialr c3, mtdc

    li       x5, CORE_STATUS
    .word    0x2051825b             # csetaddr c4, c3, x5

    li       x6, TEST_ADDRESS_CAP
    .word    0x206182db             # csetaddr c5, c3, x6
   // .word    0xFE42855B             # cgettag x10, c5

# we sholud have a valid capability for TEST_ADDRESS_BANK0
# stores
    .word    0x0052b023             # csc c5, 0(x5)
    .word    0x0002b303             # clc c6, 0(x5)
    .word    0xFE43055B             # cgettag x10, c6


    li       x11, 1                # expected tag; x6 was overwritten by clc c6
    beq      x11, x10, TAG_VALID
    li       x3, 3
    j        WRITE_STATUS

TAG_VALID:
    li       x3, 1

WRITE_STATUS:
    sw       x3, 0(x4)

1:
    j        1b

    .size    main, .-main
