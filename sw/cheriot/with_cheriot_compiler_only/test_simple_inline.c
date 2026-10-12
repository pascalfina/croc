/* 1:1 inline-assembly version of test_simple.S. */

__attribute__((noreturn, naked)) void main(void) {
    __asm__ volatile("li t1, 1\n\t"
                     "li t2, 0x03000018\n\t"
                     "sw t1, 0(t2)\n\t"
                     "li x1, 69\n\t"
                     "li x5, 0x03000008\n\t"
                     "cspecialr c3, mtdc\n\t"
                     "csetaddr c4, c3, x5\n\t"
                     "cgettag x10, c1\n\t"
                     "beq x0, x10, 1f\n\t"
                     "li x3, 3\n\t"
                     "j 2f\n\t"
                     "1:\n\t"
                     "li x3, 1\n\t"
                     "2:\n\t"
                     "sw x3, 0(x4)\n\t"
                     "3:\n\t"
                     "j 3b\n\t"
                     :
                     :
                     : "memory");
}
