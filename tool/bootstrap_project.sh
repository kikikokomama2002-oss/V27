#!/usr/bin/env bash
set -euo pipefail

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: Flutter SDK is required" >&2
  exit 1
fi

flutter pub get
dart run build_runner build --delete-conflicting-outputs
echo "Project bootstrap complete."
