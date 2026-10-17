#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.cheriot.yml)

usage() {
  printf 'Usage: %s {build|rebuild|shell}\n' "$0"
  printf '\n'
  printf '  build    Build the OSEDA image with the CHERIoT LLVM toolchain\n'
  printf '  rebuild  Build it without using Docker build cache\n'
  printf '  shell    Start an interactive container using the CHERIoT image\n'
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

cd "$ROOT_DIR"
mkdir -p "$RUNTIME_DIR"

case "$1" in
  build)
    env UID="$(id -u)" GID="$(id -g)" \
      docker compose "${COMPOSE_FILES[@]}" build pulp-docker
    ;;

  rebuild)
    env UID="$(id -u)" GID="$(id -g)" \
      docker compose "${COMPOSE_FILES[@]}" build --no-cache pulp-docker
    ;;

  shell)
    env UID="$(id -u)" GID="$(id -g)" \
      docker compose "${COMPOSE_FILES[@]}" run --rm \
        -e PS1='\[\033[01;32m\]cheriot-croc:\[\033[00m\]\w $ ' \
        -e DISPLAY="${DISPLAY:-}" \
        -e XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        -v "$RUNTIME_DIR:$RUNTIME_DIR" \
        -v /tmp/.X11-unix:/tmp/.X11-unix \
        pulp-docker
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac
