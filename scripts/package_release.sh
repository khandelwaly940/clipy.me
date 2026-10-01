#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
out="$root/build/release"
stage="$out/stage"
mkdir -p "$out"
xcodebuild -project Clipy.xcodeproj -scheme Clipy -configuration Release -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
rm -rf "$stage"
mkdir -p "$stage"
ditto build/DerivedData/Build/Products/Release/ClipyMe.app "$stage/ClipyMe.app"
sdk=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
  xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" scripts/VerifyMigration.swift -lsqlite3 -o "$out/verify-$arch"
  xcrun swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" scripts/LoginItems.swift -o "$out/login-$arch"
done
lipo -create "$out/verify-arm64" "$out/verify-x86_64" -output "$stage/ClipyMeVerify"
lipo -create "$out/login-arm64" "$out/login-x86_64" -output "$stage/ClipyMeLogin"
lipo "$stage/ClipyMe.app/Contents/MacOS/ClipyMe" -verify_arch arm64 x86_64
codesign --force --deep --sign - "$stage/ClipyMe.app"
codesign --force --sign - "$stage/ClipyMeVerify"
codesign --force --sign - "$stage/ClipyMeLogin"
codesign --verify --deep --strict "$stage/ClipyMe.app"
cp LICENSE README.md "$stage/"
python3 scripts/test_migration.py "$stage/ClipyMeVerify"
(cd "$stage" && ditto -c -k --sequesterRsrc . "$out/ClipyMe-macos-universal.zip")
(cd "$out" && shasum -a 256 ClipyMe-macos-universal.zip > ClipyMe-macos-universal.zip.sha256)
echo "Release: $out/ClipyMe-macos-universal.zip"
