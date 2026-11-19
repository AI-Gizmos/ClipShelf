# Clipshelf

A clipboard history for macOS. Clipshelf remembers the text, links, images, files and screenshots you copy, and lets you search them and paste any of them back with a hotkey.

It lives in the menu bar, keeps everything on your Mac, and has no dependencies beyond the system frameworks.

## Features

- **History panel**: Control+Command+V opens a searchable list of everything you copied, with a preview and the app it came from.
- **Island**: a small tab at the top centre of the screen (it hugs the notch on displays that have one) that expands on hover into your five most recent clips. Click a card to paste it or drag it into another app.
- **Screenshots**: new screenshots are added to the history as they are taken.
- **Pinning**: pinned clips stay at the top and are never trimmed.
- **Filters**: All, Text, Links, Images, Files, Screenshots, Pinned.
- **Password managers respected**: anything a password manager marks as concealed or transient is not recorded.

## Requirements

- macOS 14 or later
- Xcode command line tools, to build (`xcode-select --install`)

## Install

```bash
git clone https://github.com/AI-Gizmos/ClipShelf.git
```

```bash
cd ClipShelf && ./build.sh
```

```bash
open ~/Applications/Clipshelf.app
```

`build.sh` builds a release binary with Swift Package Manager, assembles `~/Applications/Clipshelf.app`, and signs it ad hoc on your machine. No prebuilt binary is distributed.

To update, pull, quit Clipshelf from its menu bar menu, run `./build.sh` again and reopen the app.

## Permissions

macOS asks for two things the first time they are needed:

- **Accessibility** lets Clipshelf press Command+V for you after you pick a clip. Without it, picking a clip still puts it on the clipboard and you paste it yourself.
- **Desktop folder access** (or wherever your screenshots are saved) lets Clipshelf notice new screenshots. Without it, everything else still works.

Because the app is signed ad hoc, macOS treats each rebuild as a new app and may ask for Accessibility again. If pasting stops working after a rebuild, remove Clipshelf from System Settings → Privacy & Security → Accessibility and add it back.

## Use

| Key | Action |
| --- | --- |
| Control+Command+V | Open or close the history panel |
| Type | Search |
| Up / Down | Move the selection |
| Return | Paste the selected clip |
| Command+1 … Command+9 | Paste that row directly |
| Tab / Shift+Tab | Cycle the filters |
| Command+P | Pin or unpin the selected clip |
| Command+Delete | Delete the selected clip |
| Escape | Close the panel |

The menu bar menu has **Pause Capturing**, **Show Island**, **Open at Login**, **Clear History…** (keeps pinned clips) and **Show History Folder**.

## Privacy

- History is stored only on your Mac, in `~/Library/Application Support/Clipshelf/` (`history.json` plus an `images/` folder), readable only by your user account. It is not encrypted.
- Clipshelf makes no network connections.
- Clips carrying the `org.nspasteboard` concealed, transient or auto-generated markers, or the 1Password marker, are skipped. Apps that do not set these markers are recorded like anything else, so use **Pause Capturing** before copying something sensitive from them.
- The 500 most recent unpinned clips are kept; older ones are removed along with their images.
- Text over 1 MB and images over 40 MB are not recorded.

## Configuration

The hotkey is set at build time. To change it, edit the `HotKey(keyCode:modifiers:)` line in `Sources/Clipshelf/main.swift` and run `./build.sh`. If another app already holds the hotkey, the menu bar menu still opens the panel.

## Uninstall

1. Turn off **Open at Login** in the menu bar menu, then choose **Quit Clipshelf**.
2. Delete `~/Applications/Clipshelf.app`.
3. Delete `~/Library/Application Support/Clipshelf` to remove your history.
4. Remove Clipshelf from System Settings → Privacy & Security → Accessibility.

## Layout

```
Sources/Clipshelf/   Swift sources
Package.swift        Swift Package Manager manifest
Info.plist           App bundle metadata
build.sh             Builds and installs ~/Applications/Clipshelf.app
```

## License

MIT. See [LICENSE](LICENSE).
