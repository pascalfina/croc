# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Run unit tests through Verilator simulation.
# Usage: run_tests.sh [--sim SIM_BINARY] [--hexdir HEX_DIR] [--filter PATTERN]
#                     [--exclude TEST_NAME] [--expect-fail TEST_NAME]
#                     [--timeout SECONDS] [--show-output] [--live-output]
#
# Expects to be run from the verilator/ directory (or paths adjusted via flags).
# Each test writes its own log file.
# Exit code: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SIM_BINARY="obj_dir/Vtb_croc_soc"
HEX_DIR="../sw/bin/test"
FILTER="test_*"
TIMEOUT=120
EXCLUDES=()
EXPECTED_FAILURES=()
SHOW_OUTPUT=false
LIVE_OUTPUT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sim)     SIM_BINARY="$2"; shift 2 ;;
        --hexdir)  HEX_DIR="$2";   shift 2 ;;
        --filter)  FILTER="$2";    shift 2 ;;
        --exclude) EXCLUDES+=("$2"); shift 2 ;;
        --expect-fail) EXPECTED_FAILURES+=("$2"); shift 2 ;;
        --timeout) TIMEOUT="$2";   shift 2 ;;
        --show-output) SHOW_OUTPUT=true; shift ;;
        --live-output) LIVE_OUTPUT=true; SHOW_OUTPUT=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--sim SIM_BINARY] [--hexdir HEX_DIR] [--filter PATTERN] [--exclude TEST_NAME] [--expect-fail TEST_NAME] [--timeout SECONDS] [--show-output] [--live-output]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -x "$SIM_BINARY" ]]; then
    echo "Error: Simulator binary not found or not executable: $SIM_BINARY" >&2
    exit 1
fi

# Find all test hex files from pattern
shopt -s nullglob
hex_files=("$HEX_DIR"/${FILTER}.hex)
shopt -u nullglob

if [[ ${#hex_files[@]} -eq 0 ]]; then
    echo "Error: No test hex files matching '${FILTER}.hex' found in $HEX_DIR" >&2
    exit 1
fi

echo "Found ${#hex_files[@]} test(s) to run"
echo "========================================="

passed=0
failed=0
declare -a results=()

for hex in "${hex_files[@]}"; do
    test_name=$(basename "$hex" .hex)

    skip_test=false
    for excluded_test in "${EXCLUDES[@]}"; do
        if [[ "$test_name" == "$excluded_test" ]]; then
            skip_test=true
            break
        fi
    done
    if [[ "$skip_test" == true ]]; then
        echo "Skipping $test_name"
        continue
    fi

    expected_failure=false
    for expected_test in "${EXPECTED_FAILURES[@]}"; do
        if [[ "$test_name" == "$expected_test" ]]; then
            expected_failure=true
            break
        fi
    done

    log_file="${test_name}.log"

    printf "Running %-20s ... " "$test_name"

    # Capture the complete simulator log. With --live-output, stream it while
    # the test is running and keep the same log for result parsing.
    if [[ "$LIVE_OUTPUT" == true ]]; then
        if timeout "$TIMEOUT" stdbuf -oL -eL "$SIM_BINARY" "+binary=$hex" \
            2>&1 | tee "$log_file"; then
            pipeline_status=("${PIPESTATUS[@]}")
        else
            pipeline_status=("${PIPESTATUS[@]}")
        fi
        sim_exit=${pipeline_status[0]}
    elif timeout "$TIMEOUT" "$SIM_BINARY" "+binary=$hex" > "$log_file" 2>&1; then
        sim_exit=0
    else
        sim_exit=$?
    fi

    if [[ "$SHOW_OUTPUT" == true && "$LIVE_OUTPUT" == false ]]; then
        echo
        echo "----- ${test_name} output -----"
        cat "$log_file"
        echo "----- end ${test_name} output -----"
    fi

    # Check for timeout (exit code 124 from timeout command)
    if [[ $sim_exit -eq 124 ]]; then
        echo "FAIL (timeout after ${TIMEOUT}s)"
        results+=("FAIL $test_name (timeout after ${TIMEOUT}s)")
        ((failed++)) || true
        continue
    fi

    # An expected-failure test passes only if the exception handler reports the
    # exception and the testbench reaches its deliberate FAIL result.
    if [[ "$expected_failure" == true ]]; then
        if grep -q '\[EXCEPTION\] mcause=' "$log_file" \
            && grep -q '\[JTAG\] Simulation finished: FAIL' "$log_file"; then
            echo "PASS (expected failure)"
            results+=("PASS $test_name (expected failure)")
            ((passed++)) || true
        else
            echo "FAIL (expected failure was not reported)"
            results+=("FAIL $test_name (expected failure was not reported)")
            ((failed++)) || true
        fi
    # Check for SUCCESS/FAIL in the log
    elif grep -q '\[JTAG\] Simulation finished: SUCCESS' "$log_file"; then
        echo "PASS"
        results+=("PASS $test_name")
        ((passed++)) || true
    else
        # Try to extract the return code from the FAIL line
        fail_line=$(grep '\[JTAG\] Simulation finished: FAIL' "$log_file" 2>/dev/null || true)
        if [[ -n "$fail_line" ]]; then
            rc=$(echo "$fail_line" | sed -n 's/.*return code \(0x[0-9a-fA-F]*\).*/\1/p')
            echo "FAIL (rc=${rc:-?})"
            results+=("FAIL $test_name (rc=${rc:-?})")
        else
            echo "FAIL (no result line, sim exit=$sim_exit)"
            results+=("FAIL $test_name (no result line, sim exit=$sim_exit)")
        fi
        ((failed++)) || true
    fi
done

echo "========================================="
echo "Summary: ${passed} passed, ${failed} failed, $((passed + failed)) total"
echo ""

if [[ $failed -gt 0 ]]; then
    echo "Failed tests:"
    for r in "${results[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo "  - ${r#FAIL }"
        fi
    done
    exit 1
fi

echo "All tests passed."
exit 0
