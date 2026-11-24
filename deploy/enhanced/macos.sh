#!/bin/bash
# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
set -euo pipefail

if [[ $# != 3 ]]; then
  echo 'Usage: macos.sh <build-directory> <qt-sdk> <openssl-sdk>' >&2
  exit 2
fi
build=$1
qt=$2
openssl=$3
version=1.27.0.23
root=$(cd "$(dirname "$0")/../.." && pwd -P)
common=(
  -DCMAKE_BUILD_TYPE=Release -DBUILD_INSTALLER=OFF -DSKIP_BUILD_TESTS=ON
  -DUPDATE_TRANSLATIONS=OFF "-DDESKFLOW_PACKAGE_VERSION=$version"
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DOPENSSL_USE_STATIC_LIBS=TRUE
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$root=." "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$root=."
  "-DCMAKE_PREFIX_PATH=$qt" "-DOPENSSL_ROOT_DIR=$openssl"
)
if [[ ${DESKFLOW_SKIP_SOURCE_TESTS:-0} != 1 ]]; then
  cmake -S "$root" -B "$build-tests" "${common[@]}" -DBUILD_TESTS=ON
  cmake --build "$build-tests" --parallel 3
  QT_QPA_PLATFORM=offscreen ctest --test-dir "$build-tests/src/unittests" --no-tests=error --output-on-failure
fi
cmake -S "$root" -B "$build" "${common[@]}" -DBUILD_TESTS=OFF -DDESKFLOW_CANDIDATE_BUILD=ON \
  -DDESKFLOW_CANDIDATE_SESSIONS_ROOT=/private/tmp/deskflow-enhanced-candidate-sessions
cmake --build "$build" --target DeskflowCandidate deskflow-core deskflow-candidate-network-core app_translations --parallel 3

scratch=$(mktemp -d)
mount_point="$scratch/mounted"
mounted=0
cleanup() {
  if [[ $mounted == 1 ]]; then hdiutil detach "$mount_point" >/dev/null || return; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
stage="$scratch/image"
mkdir -p "$stage" "$mount_point" "$build/release-out"
app="$stage/DeskflowCandidate.app"
ditto "$build/bin/DeskflowCandidate.app" "$app"
"$qt/bin/macdeployqt" "$app" -always-overwrite -verbose=1
cp "$root/LICENSE" "$stage/LICENSE.txt"
ditto "$root/LICENSES" "$stage/LICENSES"
cp "$root/deploy/enhanced/THIRD-PARTY.md" "$stage/THIRD-PARTY.md"
ln -s /Applications "$stage/Applications"

# All dependencies are packaged before signing. No application profile is staged.
for name in DeskflowCandidate deskflow-candidate-core deskflow-candidate-network-core; do
  [[ $(lipo -archs "$app/Contents/MacOS/$name") == arm64 ]]
  if otool -L "$app/Contents/MacOS/$name" | tail -n +2 | grep -Eq '/Users/|/opt/homebrew/|/usr/local/'; then
    echo "Build-host library path in $name" >&2
    exit 1
  fi
done
[[ -s "$app/Contents/Resources/translations/deskflow_zh_CN.qm" ]]
[[ -z $(find "$app" -type f \( -name '*.conf' ! -name qt.conf -o -name '*.state' -o -name '*.pem' -o -name '*.key' -o -name '*.log' \)) ]]
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
dmg="$build/release-out/Deskflow-Enhanced-$version-macOS-arm64.dmg"
hdiutil create -ov -fs HFS+ -volname 'Deskflow Enhanced' -srcfolder "$stage" -format UDZO "$dmg"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg" >/dev/null
mounted=1
# Copy as a user would from the disk image but use an isolated test profile.
installed="$scratch/installed/DeskflowCandidate.app"
ditto "$mount_point/DeskflowCandidate.app" "$installed"
codesign --verify --deep --strict "$installed"
test_root=$(cd "$scratch" && pwd -P)
export XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state"
export QT_QPA_PLATFORM=cocoa
"$installed/Contents/MacOS/deskflow-candidate-core" --version | tee "$build/release-out/macos-validation.txt"
"$installed/Contents/MacOS/DeskflowCandidate" --version | tee -a "$build/release-out/macos-validation.txt"
grep -q "$version" "$build/release-out/macos-validation.txt"
# Launch with Cocoa and a disposable profile. No Accessibility authorization is
# provided, so the fresh instance should remain in its permission guide.
unset QT_QPA_PLATFORM
"$installed/Contents/MacOS/DeskflowCandidate" > "$scratch/gui.log" 2>&1 &
gui_pid=$!
sleep 5
if ! kill -0 "$gui_pid" 2>/dev/null; then
  cat "$scratch/gui.log" >&2
  exit 1
fi
kill -TERM "$gui_pid"
wait "$gui_pid" || true
printf '%s\n' 'Disk image verified and mounted; copied application signature, native startup, and GUI/core version checks passed.' >> "$build/release-out/macos-validation.txt"
