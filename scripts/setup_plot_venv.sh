#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Creates .venv with matplotlib for the cache evaluation plots. The scripts use
# it automatically when their Python has no matplotlib, e.g. outside the
# container.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

python=${PYTHON:-python3.12}
"$python" -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install matplotlib==3.11.2 numpy==2.5.4
