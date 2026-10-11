# Emoji paste with Hammerspoon

Impulse copies the emoji you pick. To paste it too, it asks [Hammerspoon](https://www.hammerspoon.org) to press Command-V. Hammerspoon holds the Accessibility permission, so Impulse does not need it.

1. Install Hammerspoon and give it the Accessibility permission.
2. Add these lines to `~/.hammerspoon/init.lua`. Use the absolute path of your Impulse folder.

```lua
local impulse = "/absolute/path/to/impulse"
impulsePaste = dofile(impulse .. "/automation/impulse-paste.lua").setup()
```

3. Reload the Hammerspoon configuration.

The handler accepts requests only from the Impulse app and takes no parameters. Nothing else can trigger a paste. The paste replaces your clipboard contents.
