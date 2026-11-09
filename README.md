# ask-agent.nvim

Write a question in a floating window and send it — together with a precise anchor
(cwd, tab, file, line, visual selection, unsaved state) — to an external coding agent
running outside Neovim: a `pi` instance in another terminal, a Claude Code session in
a tmux pane, anything you can reach over a socket or a command line.

The point is the *anchor*: agents launched outside Neovim only see disk snapshots.
`ask-agent.nvim` hands them "the thing you are looking at right now".

```
        ┌── nvim ────────────────┐        ┌── pi / claude / tmux ──┐
  :AskAgent                      │        │                        │
  ──────────────►  floating ask  ─── socket/cmd ───►  agent session │
                   + anchor       │        │                        │
        └────────────────────────┘        └────────────────────────┘
```

## Features

- **Floating ask window** — no buffers, no temp files, no window churn. `<C-s>` sends.
- **Batch questions** — queue several anchored questions while you browse, each shown as
  a marker + virtual text in the source buffer, then send them all at once
  (`:AskAgentBatchSend`). Each question travels with its own anchor.
- **Commands only, no keymaps** — the plugin never touches your mappings; you bind
  `:AskAgent*` commands however you like.
- **Anchor capture** — `cwd`, tab, `file:line`, visual selection, `modified`, plus a
  one-line human-readable summary that travels with the question.
- **Multiple instances, disambiguated** — when several agents run in the same project
  you get a picker. Every instance gets a stable color, so the same agent is the same
  color in the list and in the map. Give instances names with `:AskAgentAlias`.
- **Two pickers** — a **map** of your terminal split layout (pick the agent by the pane
  it lives in) and a plain **list** (works across tabs/windows). `<Tab>` flips between
  them.
- **Optional RPC bridge** — lets the agent pull *live* Neovim context back (unsaved
  buffers, diagnostics, quickfix, project overview) instead of reading stale files.
- **Extensible backends** — a backend is four fields; a tmux backend is ~10 lines.

## Requirements

- Neovim 0.10+ (uses `vim.json`, `vim.uv`).
- No picker dependency: list mode goes through `vim.ui.select`, so whichever plugin
  overrides it (dropbar, telescope, fzf-lua, snacks, mini.pick …) is what you get.
  Float menus get centered and each item's glyph is painted with its instance color;
  `<Tab>` (back to the map) is only added when the implementation does not use it.
- Optional: a *layout adapter* for the split-layout map view — `rex` ships built in, and
  `layouts/generic.lua` has a tmux factory; anything else can be plugged in (see
  [Layout adapters](#layout-adapters)).
- At least one agent backend (see [Backends](#backends)).

## Install

`vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/huayue5201/ask-agent.nvim" })
require("ask_agent").setup()
```

lazy.nvim:

```lua
{
  "huayue5201/ask-agent.nvim",
  config = function()
    require("ask_agent").setup()
  end,
}
```

Local checkout (development):

```lua
vim.pack.add({ { src = "~/code/ask-agent.nvim" } })
```

## Usage

| Command | Description |
| --- | --- |
| `:AskAgent [text]` | Ask with the cursor anchor (`:AskAgent` opens the ask window) |
| `:AskAgentVisual` | Ask with the current visual selection as anchor |
| `:AskAgentPi` | Ask the `pi` backend explicitly |
| `:AskAgentBackend [id]` | Switch/choose the default backend |
| `:AskAgentPicker [map\|list]` | Choose the multi-candidate picker |
| `:AskAgentTarget [id]` | Pin the target instance (`!` clears) |
| `:AskAgentAlias` | Name an instance (`!` clears the name) |
| `:AskAgentBatch` | Queue a question at the cursor instead of sending it now |
| `:AskAgentBatchVisual` | Queue a question anchored to the selection |
| `:AskAgentBatchSend` | Send every queued question (one message each) to one target |
| `:AskAgentBatchList` | List queued questions (jump / edit / delete) |
| `:AskAgentBatchDelete` | Delete the queued question on the cursor line (undoable) |
| `:AskAgentBatchUndo` | Undo the last delete / clear, restoring markers |
| `:AskAgentBatchClear` | Drop every queued question (undoable) |

No keymaps are installed: the plugin only defines commands. Map them yourself, e.g.

```lua
vim.keymap.set({ "n", "v" }, "<leader>aq", function()
  require("ask_agent").ask({ visual = vim.fn.mode() ~= "n" })
end, { desc = "Ask agent" })
vim.keymap.set({ "n", "v" }, "<leader>ab", function()
  require("ask_agent").batch_ask({ visual = vim.fn.mode() ~= "n" })
end, { desc = "Ask agent: queue" })
vim.keymap.set("n", "<leader>aB", "<cmd>AskAgentBatchSend<cr>", { desc = "Ask agent: send queue" })
vim.keymap.set("n", "<leader>ai", "<cmd>AskAgentAlias<cr>", { desc = "Ask agent: alias" })
```

In the **ask window**: `<C-s>` sends, `<Esc>`/`<C-c>` cancels, `<CR>` is a newline.
In the **map**: letter picks that pane, `<Tab>` switches to the list, `<Esc>` cancels.
In the **list**: number (or `<M-a>` for items past 9) picks, `<Tab>` goes back to the map.

## Setup

```lua
require("ask_agent").setup({
  -- "exact" (default) = only instances whose cwd equals yours; "related" also allows
  -- parent/child directories; "single" = if only one instance exists, use it
  matching = "exact",

  -- "map" (split-layout map, default) or "list"
  picker = "map",

  -- default backend id
  default = "pi",

  -- extra backends declared inline (see Backends); they are registered at setup time
  extra = {},

  -- per-agent glyphs and brand colors
  icons = { pi = "π", claude = "✻" },
  icon_colors = { claude = "#d97757" },

  -- instance names live here by default
  aliases = { file = vim.fn.stdpath("cache") .. "/ask-agent/aliases.json" },

  -- live-context RPC bridge; `false` disables it entirely
  bridge = { dir = vim.fn.stdpath("cache") .. "/pi-ctx" },
})
```

## Backends

A backend is a table; the contract lives in `lua/ask_agent/backends/init.lua`:

```lua
---@class ask_agent.Backend
---@field id string                unique id, e.g. "pi"
---@field label string             shown in prompts
---@field icon? string             glyph override
---@field targets fun(): table[]   live instances
---@field send fun(target: table, text: string): boolean, string?
---@field available? fun(): boolean, string?
---@field status? fun(): boolean, string?
```

Each target is one instance:

```lua
{
  id = "12345",            -- stable within its lifetime (pid, socket, tmux pane id…)
  label = "pid 12345",
  cwd = "/path/to/project",
  ts = 1730000000,         -- start time; used for ordering, alias staleness and colors
  sock = "/tmp/12345.sock",-- optional: where to deliver
  rex = { session = "dev", block = "b2" }, -- optional: which terminal pane it lives in
  icon = "",               -- optional: per-instance glyph
  avoid = "reply only shows up in its host UI", -- optional: warn before sending
}
```

### Adding a tmux-based agent in ten lines

```lua
local generic = require("ask_agent.backends.generic")

require("ask_agent").setup({
  extra = {
    generic.tmux({
      id = "claude",
      label = "Claude Code",
      -- how to find instances: return { { id =, label =, cwd =, pane = } }
      list = function() ... end,
      -- how to deliver: paste the text into the pane and press enter
      deliver = function(target, text) ... end,
    }),
  },
})
```

For non-tmux transports (unix socket, HTTP, file drop) write a module returning the
table above and register it with `require("ask_agent.backends").register(mod)` — or pass
it through `setup({ extra = { mod } })`.

Bundled backends:

- `pi` — reads `~/.cache/pi-agent/ask/<pid>.json` registrations written by the pi
  extension in [`extensions/nvim-context.ts`](extensions/nvim-context.ts), talks to the
  instance's unix socket.
- `generic` — the tmux factory above.

## The map picker

When a layout adapter says which terminal pane an agent lives in, `ask-agent.nvim` draws
your split layout as a small map and puts a letter in each pane that hosts an agent. Panes covered by a floating window are shown but never get the letter — the
label moves to a visible cell of that pane instead, so the map never paints over
whatever is floating on top.

Colors, icons and letters: each instance has a stable color derived from its `id:ts`,
used both in the map and in the list, plus its agent glyph. The letter is bold.
The map itself is compact (blocks touch) and centered on screen.

No adapter is required: without one (or when fewer than two candidates can be located)
the picker silently falls back to the list.

## Layout adapters

Where does each agent live on screen? That is multiplexer-specific, so it is an adapter:

```lua
{
  id = "zellij",                                    -- unique id
  available = function() return true end,           -- ok, reason?
  window = function() return win, data end,         -- "the window nvim is in" (opaque)
  panes = function(win) return {                    -- normalised 0..1 rects, y from the top,
    { id = "p1", rect = { 0, 0, 0.5, 1 }, kind = "tiled" },  -- later entries paint on top
  } end,
  match = function(target) return target.pane end,  -- which pane hosts this instance
  cursor = function() return "p1" end,              -- optional: where nvim is focused
  labels = function(data) return {} end,            -- optional: pane id -> label
}
```

Register it with `require("ask_agent").register_layout(adapter)` (or `setup({ layout = "zellij" })`
to pick the default). A backend then stamps the locator the adapter expects — for the
tmux adapter that is `target.layout = { pane = "%3" }`, for rex it is
`target.rex = { session = "dev", block = "b2" }`.

Two adapters ship with the plugin:

- `rex` (`lua/ask_agent/layouts/rex.lua`) — registers itself, reads
  `rex session inspect <session> --json`.
- tmux factory (`lua/ask_agent/layouts/generic.lua`):

```lua
require("ask_agent").register_layout(require("ask_agent.layouts.generic").tmux())
```

Don't see your multiplexer? Open an issue with its geometry command and the adapter is
usually a 30-line file.

## Instance names

`:AskAgentAlias` attaches a name to an instance; the name is used in the
list, in the ask window title and in the "sent" notification. Names are stored in
`<cache>/ask-agent/aliases.json`, keyed by instance id and stamped with its start time,
so a recycled pid never inherits an old name. `:AskAgentAlias!` clears a name.

## RPC bridge (live context for the agent)

`setup()` starts a Neovim RPC socket and writes a registration file, so an external
agent can ask Neovim what it is looking at *right now* — including unsaved buffers,
visual selection, LSP diagnostics and the quickfix list — instead of reading disk.

Call it one-shot, no client state needed:

```sh
nvim --server <sock> --remote-expr \
  'v:lua.require("ask_agent.bridge").handle("<base64(json)>")'
```

Requests: `state`, `buffer`, `diagnostics`, `quickfix`, `list`, `project`.
Every handler returns a JSON string; failures are `{"ok":false,"error":…}` and never
throw. Register your own actions from your config:

```lua
require("ask_agent.bridge").extend("project", function(req)
  return { ok = true, text = my_project_summary(req.root) }
end)
```

`project` has no implementation on purpose — it depends on the project tooling of the
host config.

For `pi`, drop [`extensions/nvim-context.ts`](extensions/nvim-context.ts) into
`~/.pi/agent/extensions/` and restart `pi`; it writes the registration JSON and exposes
the `state`/`buffer`/`diagnostics`/`quickfix` tools to the agent.

## API

```lua
local ask = require("ask_agent")

ask.setup(opts)
ask.ask(opts)                 -- ask ({ visual = true })
ask.batch_ask(opts)           -- queue instead of send ({ visual = true })
ask.batch_send(opts)          -- send all queued, one message each
ask.batch_list()              -- list queued questions (jump/edit/delete)
ask.batch_clear() / ask.batch_count()
ask.send(text, opts)          -- send without the ask window
ask.use(id) / ask.current()   -- default backend
ask.list() / ask.targets(id)  -- backends / instances
ask.pin(id) / ask.pinned()    -- pin a target
ask.alias(target, name) / ask.alias_of(target)
ask.picker("map" | "list")
ask.layout(id)                -- active layout adapter (nil/"auto" = first usable)
ask.generic                   -- tmux backend factory
ask.register(mod)             -- register a backend at runtime
ask.register_layout(mod)      -- register a layout adapter at runtime
```

## Batch questions

When a question comes up while browsing, `:AskAgentBatch` (or
`:AskAgentBatchVisual` for a selection) queues it instead of sending: the text goes nowhere yet, and the source line gets a
`»` sign plus the question as end-of-line virtual text (`[n]` = queue position). Move
on, queue more. `:AskAgentBatchSend` sends every entry as its own
message — each keeps the anchor captured when it was queued — to a single target
chosen once. Entries follow buffer edits through their extmarks, and
`:AskAgentBatchList` jumps/edits/deletes them. `:AskAgentBatchDelete` removes the
entry on the cursor line; every delete and `:AskAgentBatchClear` can be undone
with `:AskAgentBatchUndo` (in-memory, last 20 operations).

## Health

`:checkhealth ask_agent` reports the active backend, how many instances it sees, whether
which layout adapters are usable, which `vim.ui.select` implementation was detected, and where aliases and the bridge registry live.

## License

MIT
