#define CORE_STATUS (0x03000008u)

__attribute__((noreturn)) void main(void) {
    volatile unsigned int counter = 0;
    unsigned int result;

    counter = counter + 1;
    result  = (counter == 1) ? 1u : 3u;

    /* Keep the status write explicit while the C stack path is being tested. */
    __asm__ volatile("li t0, 0x03000008\n\t"
                     "cspecialr c3, mtdc\n\t"
                     "csetaddr c4, c3, t0\n\t"
                     "mv t1, %0\n\t"
                     "sw t1, 0(x4)\n\t"
                     :
                     : "r"(result)
                     : "t0", "t1", "memory");

    for (;;) {
    }
}
