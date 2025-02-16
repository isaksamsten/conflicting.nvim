# conflicting.nvim

conflicting.nvim lets you resolve conflicts, while highlighting them in style.

## Demo

TODO

## Features

- Track Git repositories for merge conflicts. No overhead for files without
  conflicts.
- Manually track files for conflicts from other source (e.g.,
  [sia.nvim)(https://github.com/isaksamsten/sia.nvim))
- Resolve conflicts:
  - Accept current changes
  - Accept incoming changes
  - Reject all changes
  - Diff current and incoming changes

## Installation

```lua
{
  "isaksamsten/conflicting.nvim",
  --- Optionally bind keys
  keys = {
    {
      "ct",
      mode = "n",
      function()
        require("conflicting").accept_incoming()
      end,
      desc = "Accept incoming change",
    },
    {
      "co",
      mode = "n",
      function()
        require("conflicting").accept_current()
      end,
      desc = "Accept current change",
    },
    {
      "cd",
      mode = "n",
      function()
        require("conflicting").diff()
      end,
      desc = "Diff change",
    },
  },
  config = true,
}
```

### Configuration

```lua
{
  -- Track conflicts using the following trackers
  trackers = { require("conflicting").trackers.git, require("conflicting").trackers.manual },

  -- Automatically enable conflicting for all buffers
  auto_enable = true,
}
```
