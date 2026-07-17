#!/bin/zsh
set -e
cd "$(dirname "$0")"

APP=build/TileTop.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/TileTop" Sources/*.swift -framework Cocoa -framework WebKit
codesign --force -s - "$APP"
echo "Built $APP"
