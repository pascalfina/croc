# simple test for cheriot without capabilit stores or loads
# and thus should work without cabability hardware
  
    .section .text
    .globl   main

#define CHERIOT_ENABLE (0x03000018)
#define CORE_STATUS (0x03000008)

main:
    li       t1, 1
    li       t2, CHERIOT_ENABLE
    sw       t1, 0(t2)          # enable cheriot
    li       x1, 69             # should invalidate tag

    li       x5, CORE_STATUS
    .word    0x03d001db         # cspecialr c3, mtdc
    .word    0x2051825b         # csetaddr c4, c3, x5
    .word    0xfe40855b         # cgettag x10, c1

    beq      x0, x10, SUCCESS
    li       x3, 3
    j        WRITE_STATUS

SUCCESS:
    li       x3, 1

WRITE_STATUS:
    sw       x3, 0(x4)

1:
    j        1b

    .size    main, .-main