#!/bin/bash
# run.sh              -> build + launch the app
# run.sh --self-check -> build + run the pure-logic assertions
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--self-check" ]]; then
    swift build -c debug
    exec "$(swift build -c debug --show-bin-path)/iCloudGUI" --self-check
fi

./build.sh release
open "build/iCloud GUI.app"
