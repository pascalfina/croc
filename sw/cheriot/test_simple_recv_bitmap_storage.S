# simple test for recv bitmap storage
# this first makes a capability stor and load
# which should we valid then we set the recvoation bit
# an make another capability load which should give 
# a false tag using our revocation hardware

    .section .text
    .globl   main

#define CHERIOT_ENABLE (0x03000018)
#define CORE_STATUS (0x03000008)
#define TEST_HEAP_ADDRESS (0x10000D00)


main:
    li       t1, 1
    li       t2, CHERIOT_ENABLE
    sw       t1, 0(t2)                                  # enable cheriot

    .word    0x03d001db                                 # cspecialr c3, mtdc

    li       x5, CORE_STATUS
    .word    0x2051825b                                 # csetaddr c4, c3, x5

    li       x6, TEST_HEAP_ADDRESS
    .word    0x206182db                                 # csetaddr c5, c3, x6
    li       x8, 8
    .word    0x108282db                                 # csetbounds c5, c5, x8

# we sholud have a valid capability for TEST_HEAP_ADDRESS
# stores
    .word    0x0052b023                                 # csc c5, 0(x5)
    .word    0x0002b303                                 # clc c6, 0(x5)
    .word    0xFE43055B                                 # cgettag x10, c6

    li       x11, 1                                     # expected tag; x6 was overwritten by clc c6
    beq      x11, x10, FIRST_TAG_VALID
    li       x3, 3 //FAIL
    j        WRITE_STATUS

FIRST_TAG_VALID:

    li       x7, 0x10001000
    .word    0x207183db                                 # csetaddr c7, c3, x7

    lw       t1, 0(x7)                                  # READ BITMPAP ENTRY
    ori      t1, t1, 1                                  # SET REVOCATION BIT TO 1
    sw       t1, 0(x7)  
    .word    0x0002b303                                 # clc c6, 0(x5)
    .word    0xFE43055B                                 # cgettag x10, c6

    li       x11, 1                                     # expected tag; x6 was overwritten by clc c6
    beq      x11, x10, SECOND_TAG_VALID 
    li       x3, 1 //SUCCESS
    j        WRITE_STATUS


SECOND_TAG_VALID:
    li       x3, 3 //FAIL
    j        WRITE_STATUS


WRITE_STATUS:
    sw       x3, 0(x4)

1:
    j        1b

    .size    main, .-main
