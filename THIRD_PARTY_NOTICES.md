# Third-party software

## HotKey
HotKey by Sam Soffes, https://github.com/soffes/HotKey, MIT license.
Impulse uses it only for the global shortcut. The vendored revision, the local change, and the full license are in `vendor/HotKey`.

## Emoji data
emojilib 4.0.3 (keywords) and unicode-emoji-json 0.9.0 (names, groups, order) by Mu-An Chiou, https://github.com/muan/emojilib and https://github.com/muan/unicode-emoji-json, MIT license.
`Sources/LauncherCore/EmojiData.swift` holds this data. `scripts/make_emoji_data.py` rebuilds it. The full licenses are in `vendor/emoji`.

## Everything else
The AppKit interface and the action and configuration core are original Impulse code. Impulse uses no Raycast code or assets. The build needs no network package downloads, because the vendored source is in this repository.
