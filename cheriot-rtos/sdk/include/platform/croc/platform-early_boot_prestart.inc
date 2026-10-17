/*
 * Croc RV32 bootstrap.
 * This runs before the CHERIoT RTOS loader starts.
 */

/* Install the CHERIoT trap vector before enabling CHERIoT. */
li      t0, 0x02000500
csrw    mtvec, t0

/* Enable CHERIoT decoding through Croc SoC control. */
lui     t0, 0x03000
li      t1, 1
sw      t1, 24(t0)