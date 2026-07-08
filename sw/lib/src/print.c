// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Philippe Sauter <phsauter@iis.ee.ethz.ch>

#include "print.h"
#include "util.h"
#include "config.h"

const char hex_symbols[16] = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'};

/// @brief format number as hexadecimal digits
/// @return number of characters written to buffer
uint8_t format_hex32(char *buffer, uint32_t num) {
    uint8_t idx = 0;
    if (num == 0) {
        buffer[0] = hex_symbols[0];
        return 1;
    }

    while (num > 0) {
        buffer[idx++] = hex_symbols[num & 0xF];
        num >>= 4;
    }
    return idx;
}

uint8_t format_dec32(char *buffer, int32_t num) {
    uint8_t idx = 0;
    if (num == 0) {
        buffer[0] = '0';
        return 1;
    }

    int is_negative = 0;
    uint32_t unum;
    if (num < 0) {
        is_negative = 1;
        unum        = (uint32_t)-num;
    } else {
        unum = (uint32_t)num;
    }

    while (unum > 0) {
        buffer[idx++] = '0' + (unum % 10);
        unum /= 10;
    }

    if (is_negative) {
        buffer[idx++] = '-';
    }

    return idx;
}

void printf(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buffer[12]; // holds string while assembling
    uint8_t idx;

    while (*fmt) {
        if (*fmt == '%') {
            fmt++;
            if (*fmt == 'x') { // hex
                idx = format_hex32(buffer, va_arg(args, unsigned int));
                // print from buffer
                for (int j = idx - 1; j >= 0; j--) {
                    putchar(buffer[j]);
                }
            } else if (*fmt == 'c') { // char
                char chr = (char)va_arg(args, int);
                putchar(chr);
            } else if (*fmt == 's') { // string
                char *str = va_arg(args, char *);
                while (*str) {
                    putchar(*str++);
                }
            } else if (*fmt == 'd') { // dec
                idx = format_dec32(buffer, va_arg(args, int));
                // print from buffer
                for (int j = idx - 1; j >= 0; j--) {
                    putchar(buffer[j]);
                }
            }
        } else {
            putchar(*fmt);
        }
        fmt++;
    }

    va_end(args);
}
