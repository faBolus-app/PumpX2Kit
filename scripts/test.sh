#!/usr/bin/env bash
# Run the PumpX2Kit test suite.
#
# Full Xcode is NOT installed in this environment — only the Command Line Tools. The
# swift-testing framework ships with the CLT but isn't on SwiftPM's default search/rpath,
# and the SIP-protected swiftpm-testing-helper strips DYLD_* env vars. So we point the
# compiler/linker at the CLT-bundled Testing.framework and bake in the rpaths it needs at
# load time (the framework itself + lib_TestingInterop.dylib, which live in different dirs).
#
# Once full Xcode is installed, plain `swift test` works and this wrapper is unnecessary.
set -euo pipefail

FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ ! -d "$FW/Testing.framework" ]]; then
  echo "Testing.framework not found under CLT ($FW)." >&2
  echo "Install Xcode or newer Command Line Tools, then run 'swift test' directly." >&2
  exit 1
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
