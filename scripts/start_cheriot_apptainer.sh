#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${ROOT_DIR}/.containers/croc-cheriot.sif"

if command -v apptainer >/dev/null 2>&1; then
    RUNTIME="$(command -v apptainer)"
elif command -v singularity >/dev/null 2>&1; then
    RUNTIME="$(command -v singularity)"
else
    echo "Fehler: weder apptainer noch singularity wurde gefunden." >&2
    exit 1
fi

if [[ ! -f "${IMAGE}" ]]; then
    echo "Fehler: Container-Image nicht gefunden: ${IMAGE}" >&2
    exit 1
fi

# Keep the compiler cache next to the repository instead of in the home
# directory, whose quota parallel Verilator builds can fill up.
mkdir -p "${ROOT_DIR}/.ccache"

exec "${RUNTIME}" shell \
    --cleanenv \
    --env "PATH=/foss/tools/bin:/foss/tools/pulp/bin:/foss/tools/sak:/cheriot-tools/bin:/foss/tools/riscv-gnu-toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    --env 'PS1=Apptainer [\w]> ' \
    --env "CCACHE_DIR=/fosic/designs/croc/.ccache" \
    --bind "${ROOT_DIR}:/fosic/designs/croc" \
    --pwd /fosic/designs/croc \
    "${IMAGE}"
