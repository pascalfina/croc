// cause exception on purpose

__attribute__((noreturn, naked)) void main(void) {
    __asm__ volatile("li x5, 0x03000008\n\t"
                     "cspecialr c3, mtdc\n\t"
                     "csetaddr c4, c3, x5\n\t"
                     "li x4, 69\n\t" //invalidate cap c4
                     "li t1, 69\n\t"
                     "sw t1, 0(x4)\n\t" // cooked
                     :
                     :
                     : "memory");
}
