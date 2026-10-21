#!/usr/bin/env bash
set -Eeuo pipefail

__script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
readonly __script_dir

cd "$__script_dir/../"

./flutter/bin/flutter pub get
./flutter/bin/flutter gen-l10n
./flutter/bin/dart run build_runner build --delete-conflicting-outputs
