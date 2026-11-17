#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRATCH=$1
APP=$2
SOURCE="$SCRATCH/StikJIT-source"
STIKJIT_SHA=a9ccad90c7a8cb547f77ff338890e6633a65ac43

command -v xcodegen >/dev/null || { echo 'xcodegen is required to build the JIT helper' >&2; exit 1; }
git init -q "$SOURCE"
git -C "$SOURCE" remote add origin https://github.com/StikDebug/StikJIT.git
git -C "$SOURCE" fetch -q --depth 1 origin "$STIKJIT_SHA"
git -C "$SOURCE" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$STIKJIT_SHA" ]] || {
    echo 'StikJIT source revision differs from the pinned revision' >&2; exit 1;
}
git -C "$SOURCE" apply --check "$ROOT/jit/stikjit-apps.patch"
git -C "$SOURCE" apply "$ROOT/jit/stikjit-apps.patch"
(cd "$SOURCE" && xcodegen generate)
xcodebuild archive -project "$SOURCE/StikJIT.xcodeproj" -scheme StikJIT \
    -destination 'generic/platform=iOS' -archivePath "$SCRATCH/StikJIT.xcarchive" \
    -derivedDataPath "$SCRATCH/StikJIT-derived" SKIP_INSTALL=NO \
    CODE_SIGNING_ALLOWED=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES

FRAMEWORK="$SCRATCH/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework"
[[ -d "$FRAMEWORK" ]] || { echo 'StikJIT.framework was not archived' >&2; exit 1; }
mkdir -p "$ROOT/jit/Frameworks" "$APP/Frameworks" "$APP/PlugIns"
cp -R "$FRAMEWORK" "$ROOT/jit/Frameworks/"
(cd "$ROOT/jit" && xcodegen generate)
xcodebuild build -project "$ROOT/jit/WQJITHelper.xcodeproj" -scheme WQJITHelper \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$SCRATCH/JITHelper-derived" \
    CONFIGURATION_BUILD_DIR="$SCRATCH/JITHelper-products" CODE_SIGNING_ALLOWED=NO

[[ -d "$SCRATCH/JITHelper-products/WQJITHelper.appex" ]] || {
    echo 'WQJITHelper.appex was not built' >&2; exit 1;
}
cp -R "$FRAMEWORK" "$APP/Frameworks/"
cp -R "$SCRATCH/JITHelper-products/WQJITHelper.appex" "$APP/PlugIns/"
cp "$SOURCE/LICENSE" "$APP/StikJIT-LICENSE"
codesign -f -s - "$APP/Frameworks/StikJIT.framework"
codesign -f -s - --entitlements "$ROOT/jit/entitlements.plist" "$APP/PlugIns/WQJITHelper.appex"
