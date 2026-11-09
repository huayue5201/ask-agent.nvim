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
  them. Every row shows a live status dot: `●` idle, a rotating braille spinner while busy (the question is queued
  behind the running task, same as typing into pi while it works), `○` not running
  (process gone, socket missing, pane fell back to the shell). Exited pi instances stay
  visible in the list, greyed out, so you can see the agent is gone instead of guessing;
  `show_stale = false` hides them.
- **Optional RPC bridge** — lets the agent pull *live* Neovim context back (unsaved
  buffers, diagnostics, quickfix, project overview) instead of reading stale files.
- **Extensible backends** — a backend is four fields; a tmux-based agent (Claude Code, codex,
  opencode, aider…) is a five-line `generic.tmux(...)` call, busy state included.

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
The dot next to each entry is its live status: `●` idle, a spinner while busy (your
question is delivered immediately but pi processes it after the current turn — you get a
notice saying so), `○` not running. Choosing a `○` entry only warns — nothing is sent.

Busy rows animate when the picker implementation supports it: the plugin passes
`tick = 90` in the `vim.ui.select` opts and uses `frame` in `format_item(item, frame)`,
the contract `lib/menu.lua` honours (it re-renders every tick while waiting for a key).
telescope/fzf-lua/snacks/dropbar ignore `tick`, so there you see the first spinner frame
as a static icon.

## Setup

```lua
require("ask_agent").setup({
  -- "exact" (default) = only instances whose cwd equals yours; "related" also allows
  -- parent/child directories; "single" = if only one instance exists, use it
  matching = "exact",

  -- "map" (split-layout map, default) or "list"
  picker = "map",

  -- also list exited instances in the list picker as "not running" (default true)
  show_stale = true,

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

### Porting it to another agent (5 minutes)

If the agent runs in a tmux pane, the bundled factory is all you need — no new
file, no plugin change:

```lua
local generic = require("ask_agent.backends.generic")

require("ask_agent").setup({
  extra = {
    generic.tmux({
      id = "claude",
      label = "Claude Code",
      -- which panes host it (command name, Lua pattern)
      panes = generic.tmux_panes_by_cmd("claude"),
      -- optional: a different key than Enter, e.g. "C-m" or "Escape"
      keys_after = "Enter",
      -- optional: how to know it is mid-turn (see below)
      busy = generic.state_file("~/.cache/ask-agent/claude", { field = "cwd" }),
    }),
  },
})
```

The factory already implements `targets()` (from the pane list), `send()` (tmux
`load-buffer` → `paste-buffer` → `keys_after`, so multi-line text never turns into
several Enters and nothing goes through shell quoting) and `probe()` (pane alive,
not dead, still running the agent). Everything else — picker, status dots, batch
queue, aliases, the map — comes from the core.

That covers: Claude Code, codex, opencode, gemini-cli, aider, or anything else
that reads typed input from a TTY. Agents that only accept a socket/HTTP call
(pi, its ACP cousins) need a module: return the table from the contract above and
register it with `setup({ extra = { mod } })` or
`require("ask_agent.backends").register(mod)`.

### Busy / idle, the one non-obvious part

tmux can tell you a pane exists but not whether the agent is thinking. Two ways,
both without touching the plugin:

1. **Agent-side hooks writing a marker file** (recommended, accurate):

   ```sh
   # ~/.cache/ask-agent/claude/_Users_me_proj.json  <- written by the hook
   {"busy": true}
   ```

   ```lua
   busy = generic.state_file("~/.cache/ask-agent/claude", { field = "cwd" })
   ```

   `generic.state_file(dir, opts)` resolves `<dir>/<slug(key)>.json`, treats
   missing/invalid markers as "unknown" (never blocks sending), and a marker older
   than `opts.ttl` (default one hour) as unknown too, so a crashed session cannot
   look busy forever. `generic.slug()` is the same escaping a shell hook can
   reproduce (`tr -c '[:alnum:]._-' '_'`).

   Claude Code hooks, for example: `UserPromptSubmit` writes `{"busy":true}`,
   `Stop` writes `{"busy":false}`, both keyed by the `cwd` in the hook's stdin JSON.
   Then the picker shows `●` idle, a spinner while busy, and tells you the question
   will be queued.

2. **Screen scraping** — match on the pane's visible text (`capture-pane`) for a
   spinner or an "esc to interrupt" hint and pass that as `busy`. Zero agent-side
   setup, but it breaks when the UI changes; that is why it is not built in.

Providing `busy` is entirely optional: without it every live target is shown as
idle and delivery goes straight to the pane, which is what the agent's own input
buffer is for.

### Non-tmux discovery

`generic.tmux_panes(match)` is the low-level version of the filter: it hands you
`{ id, command, cwd, title }` for every pane and takes a predicate, which is what
you want when the agent runs under a wrapper (`node`, `bun`, `python`) or you can
only tell panes apart by title. For zellij/wezterm/kitty or an embedded terminal,
write the panes function yourself — it only has to return
`{ { id=, label=, cwd=, <how to deliver>= } }`.

`tests/backends.lua` (run it from the repo root with
`nvim --headless --clean -l tests/backends.lua`) is the reference: a hand-written
backend, the generic factory with a stubbed tmux, hook-written busy markers, and
the pane helpers.

Bundled backends:

- `pi` — reads `~/.cache/pi-agent/ask/<pid>.json` registrations written by the pi
  extension in [`extensions/nvim-context.ts`](extensions/nvim-context.ts), talks to the
  instance's unix socket.
- `generic` — the tmux factory above, plus `tmux_panes(match)`,
  `tmux_panes_by_cmd(pattern)` and `state_file(dir, opts)` for hook-written busy markers.

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
ask.generic                   -- tmux backend factory; also
                              -- generic.tmux_panes(match), generic.tmux_panes_by_cmd(pat),
                              -- generic.state_file(dir, opts), generic.slug(s)
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
