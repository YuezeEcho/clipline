#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/PinnedPhotos.swift Tests/PinnedPhotosChecks.swift \
  -o .build/pinned-photos-checks
.build/pinned-photos-checks
