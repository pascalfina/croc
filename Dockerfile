# syntax=docker/dockerfile:1
#
# Build the CHERIoT LLVM toolchain once and add it to the Croc OSEDA image.
# The existing docker-compose.yml intentionally continues to use the
# pre-built OSEDA image for CI. Use docker-compose.cheriot.yml locally.

FROM ubuntu:24.04 AS cheriot-llvm

ARG CHERIOT_LLVM_REF=cheriot
ARG LLVM_JOBS=4

ENV DEBIAN_FRONTEND=noninteractive
ENV NINJA_STATUS="%p [%f:%s/%t] %o/s, %es"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        git \
        lld \
        ninja-build \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${CHERIOT_LLVM_REF}" \
    https://github.com/CHERIoT-Platform/llvm-project.git /src/cheriot-llvm

RUN cmake -S /src/cheriot-llvm/llvm -B /build/cheriot-llvm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX=/cheriot-tools \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_ENABLE_UNWIND_TABLES=NO \
    -DLLVM_TARGETS_TO_BUILD=RISCV \
    -DLLVM_DISTRIBUTION_COMPONENTS="clang;lld;llvm-objcopy;llvm-objdump;llvm-strip" \
    -DLLVM_PARALLEL_LINK_JOBS=1

RUN cmake --build /build/cheriot-llvm \
    --target install-distribution \
    --parallel "${LLVM_JOBS}"

# The distribution installs versioned Clang binaries. Provide stable names
# for Makefiles, editor tooling, and the CHERIoT SDK build system.
RUN set -eux; \
    cd /cheriot-tools/bin; \
    clang_bin="$(find . -maxdepth 1 -name 'clang-[0-9]*' | sort -V | tail -n 1)"; \
    test -n "${clang_bin}"; \
    ln -sfn "${clang_bin}" clang; \
    ln -sfn clang clang++; \
    ln -sfn lld ld.lld

FROM hpretl/iic-osic-tools:2025.12

COPY --from=cheriot-llvm /cheriot-tools /cheriot-tools

ENV CHERIOT_TOOLS=/cheriot-tools
ENV PATH=/cheriot-tools/bin:${PATH}
