#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Two-phase APK build for low-RAM machines (2 GB / no swap).
#
# Why: `flutter build apk` runs the Dart AOT compiler (gen_snapshot, ~250 MB)
# and the Gradle/JVM build in the SAME window. On a 2 GB box the kernel OOM
# killer takes down the JVM. Splitting the pipeline keeps them apart:
#
#   Phase 1 (no JVM)  flutter assemble  -> libapp.so + flutter_assets
#   Phase 2 (no AOT)  ./gradlew assembleRelease -x compileFlutterBuildRelease
#
# Usage:  ./tools/build-apk-two-phase.sh [android-arm64|android-arm|android-x64]
# Output: build/app/outputs/flutter-apk/app-release.apk
# ---------------------------------------------------------------------------
set -euo pipefail

ARCH="${1:-android-arm64}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/app/intermediates/flutter/release"

: "${JAVA_HOME:?set JAVA_HOME to a JDK 17}"
: "${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
export PATH="$JAVA_HOME/bin:$PATH"

# Android local.properties needs both SDK and Flutter paths.
printf 'sdk.dir=%s\nflutter.sdk=%s\n' \
  "$ANDROID_SDK_ROOT" "$(dirname "$(dirname "$(command -v flutter)")")" \
  > "$ROOT/android/local.properties"

echo "==> Phase 1: Dart AOT + asset bundle (no JVM, ~25 s)"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"
flutter --quiet assemble --no-version-check \
  --depfile "$OUT/flutter_build.d" \
  --output "$OUT" \
  -dTargetFile=lib/main.dart \
  -dTargetPlatform=android \
  -dBuildMode=release \
  -dTrackWidgetCreation=false \
  -dAndroidArchs="$ARCH" \
  -dMinSdkVersion=24 \
  "android_aot_bundle_release_${ARCH}"

test -f "$OUT/$ARCH/libapp.so" || { echo "AOT failed: no libapp.so"; exit 1; }

echo "==> Phase 2: Gradle packaging only (AOT task skipped, ~10 min on 2 cores)"
cd "$ROOT/android"
# -Pdisable-abi-filtering=true: without it the Flutter Gradle plugin clears the
#   abiFilters from app/build.gradle.kts and re-adds every ABI, so the APK ends
#   up carrying plugin .so files for armv7/x86_64 that have no libapp.so.
# Memory: the JVM profile below is sized for a 2 GB box; drop it on a big machine.
./gradlew --no-daemon assembleRelease \
  -x compileFlutterBuildRelease \
  -Pdisable-abi-filtering=true \
  "-Dorg.gradle.jvmargs=-Xmx900m -XX:MaxMetaspaceSize=832m -XX:ReservedCodeCacheSize=80m -XX:+UseSerialGC" \
  --console=plain

echo
echo "==> Done:"
ls -la "$ROOT/build/app/outputs/flutter-apk/"*.apk
