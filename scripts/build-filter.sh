#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="$REPO_ROOT/build/filter"
readonly JBIG_VERSION="2.1"
readonly JBIG_ARCHIVE="$BUILD_DIR/jbigkit-$JBIG_VERSION.tar.gz"
readonly JBIG_DIR="$BUILD_DIR/jbigkit-$JBIG_VERSION"
readonly OUTPUT_DIR="$REPO_ROOT/printer/filter/bin"
readonly OUTPUT_PATH="$OUTPUT_DIR/panasonic-kx-mb1500-gdi"
readonly SOURCE_PATH="$REPO_ROOT/printer/filter/src/panasonic_kx_mb1500_gdi.c"

fetch_jbigkit() {
    mkdir -p "$BUILD_DIR"

    if [ ! -f "$JBIG_ARCHIVE" ]; then
        curl -L "https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-$JBIG_VERSION.tar.gz" -o "$JBIG_ARCHIVE"
    fi

    rm -rf "$JBIG_DIR"
    tar -xzf "$JBIG_ARCHIVE" -C "$BUILD_DIR"
}

build_filter() {
    mkdir -p "$OUTPUT_DIR"

    clang \
        -arch arm64 \
        -arch x86_64 \
        -O2 \
        -Wall \
        -Wextra \
        -I"$JBIG_DIR/libjbig" \
        "$SOURCE_PATH" \
        "$JBIG_DIR/libjbig/jbig.c" \
        "$JBIG_DIR/libjbig/jbig_ar.c" \
        -lcups \
        -o "$OUTPUT_PATH"

    chmod 0755 "$OUTPUT_PATH"
}

main() {
    fetch_jbigkit
    build_filter
    printf '%s\n' "$OUTPUT_PATH"
}

main "$@"
