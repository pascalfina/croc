#!/usr/bin/env bash
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
model_dir="$root/rtl/vendor/hyperbus/models/s27ks0641"
source_model="$model_dir/s27ks0641.v"
output_model="$model_dir/s27ks0641_verilator.v"
model_patch="$root/verilator/patches/s27ks0641-verilator.patch"

if [[ ! -f "$source_model" ]]; then
    echo "[ERROR][HyperRAM] Missing $source_model. Install the Infineon model separately." >&2
    exit 1
fi
if ! command -v patch >/dev/null 2>&1; then
    echo "[ERROR][HyperRAM] The 'patch' utility is required to prepare the Verilator model." >&2
    exit 1
fi

temporary_model="$(mktemp "$model_dir/.s27ks0641-verilator.XXXXXX")"
trap 'rm -f -- "$temporary_model"' EXIT

# Never change the vendor source or publish a partially patched model.
if ! patch --batch --forward --quiet --fuzz=0 --reject-file=- \
        --input="$model_patch" --output="$temporary_model" "$source_model"; then
    echo "[ERROR][HyperRAM] Compatibility patch failed; check the installed model version." >&2
    exit 1
fi

if ! cmp -s "$temporary_model" "$output_model"; then
    chmod --reference="$source_model" "$temporary_model"
    mv -f -- "$temporary_model" "$output_model"
fi
echo "[INFO][HyperRAM] Verilator-compatible model ready: $output_model"
