#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/Inbox.swift Sources/Tendedero/CaptureLocations.swift Tests/StorageChecks.swift -o .build/storage-checks
.build/storage-checks
