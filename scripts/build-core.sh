#!/usr/bin/env bash
# Builds the Rust core and generates the UniFFI Swift bindings into app/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/core"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release
LIB="target/release/libfenrir_core.a"
SW="$ROOT/app/Sources/Fenrir/Generated"
FFI="$ROOT/app/Sources/CFenrirCore"
mkdir -p "$SW" "$FFI/include"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo run --release --bin uniffi-bindgen -- generate --library "$LIB" --language swift --out-dir "$SW"
mv "$SW"/fenrir_coreFFI.h "$FFI/include/"
mv "$SW"/fenrir_coreFFI.modulemap "$FFI/include/module.modulemap"
echo '// Headers live in include/; this file keeps SwiftPM happy.' > "$FFI/shim.c"
