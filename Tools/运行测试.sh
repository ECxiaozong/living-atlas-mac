#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# AppKit window tests share the process focus and pasteboard.
args=(--no-parallel)
for option in "$@"; do
  case "$option" in --parallel|--no-parallel) args=(); break ;; esac
done
if [[ -f "$plugin" ]]; then args+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
exec swift test -j 6 "${args[@]}" "$@"
