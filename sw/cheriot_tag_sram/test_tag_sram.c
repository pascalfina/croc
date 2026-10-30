#include <stddef.h>
#include <stdint.h>

#include "config.h"

_Static_assert(sizeof(uint32_t) == 4, "The test requires 32-bit words.");
_Static_assert(sizeof(void *) == 8, "The test requires CHERIoT capabilities.");
_Static_assert(UART_BYTE_ALIGN == 4, "The test requires word-spaced UART registers.");

typedef volatile uint32_t *capability_t;

/* Scratch symbols are raw addresses, not compiler-generated global capabilities. */
#define LINKER_ADDRESS(symbol)                                                  \
    ({                                                                         \
        uint32_t address;                                                      \
        __asm__("lui %0, %%hi(" #symbol ")\n\t"                                \
                "addi %0, %0, %%lo(" #symbol ")" : "=r"(address));              \
        address;                                                              \
    })

volatile uint32_t test_phase = 1;
static volatile uint32_t payload = 0x2468ace0u;

enum { ProbeCount = 15, UartPollLimit = 10000 };
#define PAYLOAD_VALUE 0x13579bdfu

/* Padded word arrays keep UART string reads within bounds without byte loads. */
#define TEXT(name, text)                                                        \
    static const union {                                                       \
        uint32_t words[(sizeof(text) + 3) / 4];                                 \
        char bytes[((sizeof(text) + 3) / 4) * 4];                                \
    } name = {.bytes = text}

TEXT(msg_phase1, "Tag SRAM [1]: stack and globals\n");
TEXT(msg_phase2, "Tag SRAM [2]: tags initially clear\n");
TEXT(msg_phase3, "Tag SRAM [3]: capability round-trip\n");
TEXT(msg_phase4, "Tag SRAM [4]: word stores and neighbouring tags\n");
TEXT(msg_phase5, "Tag SRAM [5]: null capability stores\n");
TEXT(msg_phase6, "Tag SRAM [6]: bounded stack and heap\n");
TEXT(msg_pass, "Tag SRAM: PASS\n");
TEXT(msg_fail, "Tag SRAM: FAIL phase=0x");
TEXT(msg_address, " address=0x");
TEXT(msg_expected, " expected=0x");
TEXT(msg_actual, " actual=0x");
TEXT(msg_newline, "\n");

static uint32_t address_of(const volatile void *pointer)
{
    return (uint32_t)__builtin_cheri_address_get(pointer);
}

static inline void *root_at(uint32_t address)
{
    void *root;
    __asm__ volatile("cspecialr %0, mtdc" : "=C"(root));
    return __builtin_cheri_address_set(root, address);
}

static volatile uint32_t *reg32(uint32_t base, uint32_t offset)
{
    return (volatile uint32_t *)root_at(base + offset);
}

__attribute__((noreturn)) static void finish(uint32_t result)
{
    *reg32(SOCCTRL_BASE_ADDR, 8) = (result << 1) | 1u;
    for (;;) {
    }
}

static void uart_init(void)
{
    const uint32_t divisor = UART_FREQ / (UART_BAUD * 16u);
    *reg32(UART_BASE_ADDR, 4) = 0;
    *reg32(UART_BASE_ADDR, 12) = 0x80;
    *reg32(UART_BASE_ADDR, 0) = divisor & 0xffu;
    *reg32(UART_BASE_ADDR, 4) = divisor >> 8;
    *reg32(UART_BASE_ADDR, 12) = 3;
    *reg32(UART_BASE_ADDR, 8) = 0xc7;
    *reg32(UART_BASE_ADDR, 16) = 0x20;
}

static void uart_wait(uint32_t mask)
{
    for (uint32_t attempt = 0; attempt < UartPollLimit; attempt++) {
        if ((*reg32(UART_BASE_ADDR, 20) & mask) == mask)
            return;
    }
    finish(0x7f);
}

static void uart_putc(uint32_t byte)
{
    uart_wait(0x20);
    *reg32(UART_BASE_ADDR, 0) = byte;
}

static void uart_flush(void)
{
    uart_wait(0x60);
}

static void uart_text(const volatile uint32_t *words)
{
    for (;;) {
        uint32_t word = *words++;
        for (unsigned byte = 0; byte < 4; byte++) {
            const uint32_t character = word & 0xffu;
            if (character == 0)
                return;
            uart_putc(character);
            word >>= 8;
        }
    }
}

static void uart_hex(uint32_t value)
{
    for (int shift = 28; shift >= 0; shift -= 4) {
        const uint32_t digit = (value >> shift) & 0xfu;
        uart_putc(digit < 10 ? '0' + digit : 'a' + digit - 10);
    }
}

__attribute__((noreturn)) static void fail(uint32_t address,
                                         uint32_t actual,
                                         uint32_t expected)
{
    uart_text(msg_fail.words);
    uart_hex(test_phase);
    uart_text(msg_address.words);
    uart_hex(address);
    uart_text(msg_expected.words);
    uart_hex(expected);
    uart_text(msg_actual.words);
    uart_hex(actual);
    uart_text(msg_newline.words);
    uart_flush();
    finish(test_phase);
}

static void expect(uint32_t address, uint32_t actual, uint32_t expected)
{
    if (actual != expected)
        fail(address, actual, expected);
}

static capability_t volatile *slot_at(uint32_t address)
{
    return (capability_t volatile *)__builtin_cheri_bounds_set_exact(
        root_at(address), sizeof(capability_t));
}

static void check_untagged(capability_t volatile *slot)
{
    capability_t loaded = *slot;
    expect(address_of(slot), __builtin_cheri_tag_get(loaded), 0);
}

static void check_capability(capability_t volatile *slot, capability_t expected)
{
    capability_t loaded = *slot;
    const uint32_t address = address_of(slot);
    expect(address, __builtin_cheri_tag_get(loaded), 1);
    expect(address, address_of(loaded), address_of(expected));
    expect(address, __builtin_cheri_base_get(loaded),
           __builtin_cheri_base_get(expected));
    expect(address, __builtin_cheri_length_get(loaded),
           __builtin_cheri_length_get(expected));
    expect(address, __builtin_cheri_perms_get(loaded),
           __builtin_cheri_perms_get(expected));
    expect(address, *loaded, PAYLOAD_VALUE);
}

static void check_other_probes(const volatile uint32_t *probes,
                               unsigned changed,
                               capability_t expected)
{
    for (unsigned i = 0; i < ProbeCount; i++) {
        if (i != changed)
            check_capability(slot_at(probes[i]), expected);
    }
}

int main(void)
{
    uart_init();
    uart_text(msg_phase1.words);
    uart_flush();

    volatile uint32_t stack_word = 0x11223344u;
    expect(address_of(&stack_word), stack_word, 0x11223344u);
    expect(address_of(&payload), payload, 0x2468ace0u);
    payload = PAYLOAD_VALUE;
    expect(address_of(&payload), payload, PAYLOAD_VALUE);

    /* These are scratch locations, never the C call stack or program image. */
    volatile uint32_t probes[ProbeCount];
    probes[0] = LINKER_ADDRESS(__heap_start);
    probes[1] = LINKER_ADDRESS(__heap_start) + 8;
    probes[2] = LINKER_ADDRESS(__tag_bank0_probe);
    probes[3] = LINKER_ADDRESS(__tag_bank0_probe) + 8;
    probes[4] = LINKER_ADDRESS(__tag_bank0_probe) + 120;
    probes[5] = LINKER_ADDRESS(__tag_bank0_probe) + 128;
    probes[6] = LINKER_ADDRESS(__tag_bank0_probe) + 248;
    probes[7] = LINKER_ADDRESS(__tag_boundary_probe);
    probes[8] = LINKER_ADDRESS(__tag_boundary_probe) + 8;
    probes[9] = LINKER_ADDRESS(__tag_bank1_probe);
    probes[10] = LINKER_ADDRESS(__tag_bank1_probe) + 8;
    probes[11] = LINKER_ADDRESS(__tag_bank1_probe) + 120;
    probes[12] = LINKER_ADDRESS(__tag_bank1_probe) + 128;
    probes[13] = LINKER_ADDRESS(__tag_bank1_probe) + 248;
    probes[14] = LINKER_ADDRESS(__tag_last_probe);

    test_phase = 2;
    uart_text(msg_phase2.words);
    uart_flush();
    for (unsigned i = 0; i < ProbeCount; i++)
        check_untagged(slot_at(probes[i]));

    test_phase = 3;
    uart_text(msg_phase3.words);
    uart_flush();
    capability_t expected = __builtin_cheri_bounds_set_exact(&payload, sizeof(payload));
    expect(address_of(expected), __builtin_cheri_tag_get(expected), 1);
    for (unsigned i = 0; i < ProbeCount; i++)
        *slot_at(probes[i]) = expected;
    for (unsigned i = 0; i < ProbeCount; i++)
        check_capability(slot_at(probes[i]), expected);

    test_phase = 4;
    uart_text(msg_phase4.words);
    uart_flush();
    for (unsigned i = 0; i < ProbeCount; i++) {
        capability_t volatile *slot = slot_at(probes[i]);
        volatile uint32_t *words = (volatile uint32_t *)slot;
        for (unsigned half = 0; half < 2; half++) {
            /* Deliberate pointer-representation access: -fno-strict-aliasing. */
            words[half] = 0;
            check_untagged(slot);
            check_other_probes(probes, i, expected);
            *slot = expected;
            check_capability(slot, expected);
        }
    }

    test_phase = 5;
    uart_text(msg_phase5.words);
    uart_flush();
    for (unsigned i = 0; i < ProbeCount; i++) {
        capability_t volatile *slot = slot_at(probes[i]);
        *slot = NULL;
        check_untagged(slot);
        check_other_probes(probes, i, expected);
        *slot = expected;
        check_capability(slot, expected);
    }

    test_phase = 6;
    uart_text(msg_phase6.words);
    uart_flush();
    capability_t volatile stack_slot = expected;
    check_capability(&stack_slot, expected);
    void *heap = __builtin_cheri_bounds_set_exact(
        root_at(LINKER_ADDRESS(__heap_start)),
        LINKER_ADDRESS(__heap_end) - LINKER_ADDRESS(__heap_start));
    expect(address_of(heap), __builtin_cheri_tag_get(heap), 1);
    capability_t volatile *heap_slot = (capability_t volatile *)heap;
    *heap_slot = expected;
    check_capability(heap_slot, expected);

    uart_text(msg_pass.words);
    uart_flush();
    return 0;
}
