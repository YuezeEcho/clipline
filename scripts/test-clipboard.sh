#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/ClipboardHistory.swift Tests/ClipboardHistoryChecks.swift \
  -o .build/clipboard-checks
.build/clipboard-checks
