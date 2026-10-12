#define CORE_STATUS (0x03000008u)

__attribute__((noreturn)) void main(void)
{
    volatile int array[4];
    volatile int *volatile p = &array[0];
    unsigned int result;

    p[0] = 42;
    result = (p[0] == 42) ? 1u : 3u;

    /* Report the result without constructing an MMIO pointer in C. */
    __asm__ volatile(
        "li t0, 0x03000008\n\t"
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
