#!/bin/zsh
# Builds Clipshelf and installs it to ~/Applications/Clipshelf.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/Clipshelf.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Clipshelf "$APP/Contents/MacOS/Clipshelf"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Installed $APP"
