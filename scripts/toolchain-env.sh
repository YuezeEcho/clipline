# Source from the project root. Changes apply only to these build processes.
mkdir -p .build/module-cache .build/toolchain
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
CLIPLINE_SWIFT_FLAGS=(-module-cache-path "$CLANG_MODULE_CACHE_PATH")
CLIPLINE_SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift"
if [ -f "$CLIPLINE_SWIFT_INCLUDE/module.modulemap" ] && [ -f "$CLIPLINE_SWIFT_INCLUDE/bridging.modulemap" ]; then
  if /usr/bin/grep -q '^module SwiftBridging' "$CLIPLINE_SWIFT_INCLUDE/module.modulemap" && \
     /usr/bin/grep -q '^module SwiftBridging' "$CLIPLINE_SWIFT_INCLUDE/bridging.modulemap"; then
    python3 - "$CLIPLINE_SWIFT_INCLUDE" <<'PY'
import json, re, sys
from pathlib import Path
legacy = Path(sys.argv[1]) / 'module.modulemap'
fixed = Path('.build/toolchain/module.modulemap')
fixed.write_text(re.sub(r'module SwiftBridging\s*\{[^}]*\}', '', legacy.read_text()))
overlay = {'version': 0, 'use-external-names': False, 'roots': [
    {'type': 'file', 'name': str(legacy), 'external-contents': str(fixed.resolve())}
]}
Path('.build/toolchain/overlay.json').write_text(json.dumps(overlay))
PY
    CLIPLINE_SWIFT_FLAGS+=(-vfsoverlay "$PWD/.build/toolchain/overlay.json")
  fi
fi
