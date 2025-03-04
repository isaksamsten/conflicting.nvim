# conflicting.nvim

conflicting.nvim allows you to resolve conflicts while highlighting them in style.

The plugin was originally integrated into my LLM code assistant
([sia.nvim](https://github.com/isaksamsten/sia.nvim)), but I appreciated its
workflow for managing merge conflicts. So here it is: a conflict resolver that
is resource-light (it adds no overhead when there are no conflicts) while
offering a more visually appealing experience.

## Demo

https://github.com/user-attachments/assets/92ea6953-60ae-44ad-98f6-86673d20d8dd

https://github.com/user-attachments/assets/890dc214-fb50-46d2-ba03-e1b4d9d19931

## Features

- Track Git repositories for merge conflicts. No overhead for files without
  conflicts.
- Manually track files for conflicts from other source (e.g.,
  [sia.nvim](https://github.com/isaksamsten/sia.nvim))
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

## Usage

Bind the following functions to suitable keys or use the command `Conflicting`:

- `require("conflicting").accept_incoming()`: accept incoming changes. The same
  as `Conflicting incoming`
- `require("conflicting").accept_current()`: accept current changes (reject
  incoming changes). The same as `Conflicting current`.
- `require("conflicting").accept_both()`: accept both changes (and manually
  edit the conflict). The same as `Conflicting both`.
- `require("conflicting").reject()`: reject both changes. The same as `Conflicting reject`.
- `require("conflicting").diff()`: open a two-way diff with the current and
  incoming changes to manually merge the changes. The same as `Conflicting diff`.
- `require("conflicting").quickfix()`: add all conflict markers from tracked
  files to the quickfix list.

## Highlight groups

`conflicting.nvim` uses the following highlight groups:

- `ConflictingOursHeader` links to `DiffAdd` by default
- `ConflictingOurs` links to `DiffAdd` by default
- `ConflictingTheirs` links to `DiffChange` by default
- `ConflictingTheirsHeader` links to `DiffChange` by default
- `ConflictingDelimiter` links to `Normal` by default

Since no colorscheme integrates with `conflicting.nvim`, you need to set the
highlight groups manually to override these defaults. See my
[config](https://github.com/isaksamsten/nvim-config/blob/fa6fa6139f31963d3afd953ec84c4a7cb78d96eb/colors/dragon.lua#L660C1-L662C8) for inspiration.
