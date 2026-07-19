#!/usr/bin/env bash
# Symlinks the minimal set of mbedTLS .c files needed for EC-JPAKE into the CMbedTLSJPAKE
# target so SwiftPM compiles them as separate translation units. Idempotent. The symlinks are
# committed to git (git preserves symlinks), so CI works after `git submodule update`; rerun
# this only if the file set changes or links break.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Sources/CMbedTLSJPAKE/mbedtls_lib"
mkdir -p "$DEST"

FILES=(
  ecjpake.c ecp.c ecp_curves.c ecp_curves_new.c
  bignum.c bignum_core.c bignum_mod.c bignum_mod_raw.c
  constant_time.c md.c sha256.c platform.c platform_util.c
)

for f in "${FILES[@]}"; do
  ln -sf "../../../vendor/mbedtls/library/$f" "$DEST/$f"
done
echo "Linked ${#FILES[@]} mbedTLS sources into $DEST"
