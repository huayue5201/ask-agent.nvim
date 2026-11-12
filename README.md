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
  a marker + virtual text in the source buffer, then send them all at once or one by one
  (`:AskAgentBatchSend [ids]`). Each question travels with its own anchor.
- **Per-question routing** — route queue entries to different agent instances
  (`:AskAgentBatchRoute`); a routed entry's marker shows `[3→reviewer]` in that agent's
  color, and a batch send delivers each entry to its own agent.
- **Commands only, no keymaps** — the plugin never touches your mappings; you bind
  `:AskAgent*` commands however you like.
- **Anchor capture** — `cwd`, tab, `file:line`, visual selection, `modified`, plus a
  one-line human-readable summary that travels with the question.
- **Multiple instances, disambiguated** — when several agents run in the same project
  you get a picker. Every instance gets a stable color, so the same agent is the same
  color in the list and in the map. Give instances names with `:AskAgentRename` (or `n` in the dashboard).
- **Two pickers** — a **map** of your terminal split layout (pick the agent by the pane
  it lives in; it only shows agents of the window nvim lives in) and a plain **list**
  (works across tabs/windows — use it for agents outside the current window). `<Tab>`
  flips between them. Every row shows the agent's state: `●` idle, `◐` working (the question is queued
  behind the running task, same as typing into pi while it works), `⚠` waiting for you,
  `✓` finished, `✗` failed, `○` not running (process gone, socket missing, pane fell
  back to the shell). `show_stale = false` hides the exited ones.
- **A sidebar for every agent** — `:AskAgentDashboard` opens a tree: agents on top
  (most urgent first: permission > question > finished > error > working > idle), their
  tasks below — the questions still queued for that agent (`◐`) and the turns already
  sent (`spinner` running, `✓` done, `✗` failed). `<CR>` on an agent opens it in a
  viewer float (rex, tmux, herdr, or any viewer you register) and on a task jumps to
  the code anchor it was written at. Blocked prompts, finished turns, failures and
  an agent exiting mid-turn are reported through `vim.notify`; `ask_agent.statusline()`
  puts the counts (`⚠1 ✓2 ◐3`) where you want them.
- **View an agent without leaving Neovim** — `<CR>` on an agent in the sidebar opens
  a float that shows the *same* agent, live, in the terminal you already run it in
  (rex, tmux, herdr). A second display, not a copy: the agent keeps its session,
  pane and process, and closing the float only detaches. The float opens in
  terminal mode, so you type into the agent immediately; `<C-q>` closes it and
  `<Esc>` still goes to the agent (that is how you interrupt a turn).
- **Status another plugin can act on** — `ask.agents()`, `ask.on("done"|"blocked")`,
  `ask.wait()` and a `correlation` tag that travels with a send and comes back with the
  event, so a task list can own the work and the agent only owns the conversation.
- **Optional RPC bridge** — lets the agent pull *live* Neovim context back (unsaved
  buffers, diagnostics, quickfix, project overview) instead of reading stale files.
- **Change review** — `:AskAgentDiff` shows what an agent actually changed. The plugin
  captures a git tree at the turn boundaries (before the send, when the turn ends) and
  diffs the two: an immutable interval you can re-run with plain `git diff <a> <b>`, not
  a heuristic. Rendered by whichever viewer you already have (diffbandit, Neovim 0.12's
  builtin `nvim.difftool`, codediff), with a dependency-free diff buffer as the fallback.
- **Question history** — every question the plugin delivers is recorded with its
  anchor, target and text, across sessions. `:AskAgentHistory` searches it (full text,
  path, label), then re-asks, copies, or jumps back to the exact line — even after a
  restart. Answers stay in the agent; this is a ledger of questions, not a transcript.
- **Prompt library** — reusable templates with placeholders (`{{file}}`, `{{line}}`,
  `{{selection}}`, `{{cwd}}`, `{{diagnostics}}`…) that are filled from the anchor at
  ask time. Keep them globally, or commit them as `.ask-agent/prompts.json` so a
  team shares the same review prompts.
- **Extensible backends** — a backend is four fields; a tmux-based agent (Claude Code, codex,
  opencode, aider…) is a five-line `generic.tmux(...)` call, busy state included.

## Requirements

- Neovim 0.10+ (uses `vim.json`, `vim.uv`).
- List mode prefers **ui-menu.nvim** when it is installed: that is what makes the
  list screen-centered, animates the spinner, and gives a real `<Tab>` round-trip
  back to the map. It is recommended but **not required** — without it (or with
  `list_impl = "vim_ui"`) the list goes through `vim.ui.select`, so whichever
  plugin overrides it (dropbar, telescope, fzf-lua, snacks, mini.pick …) is what
  you get. Float menus are centered and glyphs are colored on a best-effort basis;
  `<Tab>` is only added when the implementation does not use it.
- Optional: a *layout adapter* for the split-layout map view — `rex` ships built in, and
  `layouts/generic.lua` has a tmux factory; anything else can be plugged in (see
  [Layout adapters](#layout-adapters)).
- At least one agent backend (see [Backends](#backends)).
- Optional: `git` for change review ([Change review](#change-review)). Without a
  repository the feature is unavailable, and every other feature keeps working.

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
| `:AskAgentRename` | Name an instance (`!` clears the name) |
| `:AskAgentDashboard` | Sidebar tree: agents + their queued/sent tasks (jump / send / flush / ack) |
| `:AskAgentBatch` | Queue a question at the cursor instead of sending it now |
| `:AskAgentBatchVisual` | Queue a question anchored to the selection |
| `:AskAgentBatchSend [ids]` | Send queued questions (all, or e.g. `3,5-7`) to their agents |
| `:AskAgentBatchRoute [ids]` | Route queued questions to one agent (`!` clears the route) |
| `:AskAgentBatchList` | List queued questions (send / route / jump / edit / delete) |
| `:AskAgentBatchDelete` | Delete the queued question on the cursor line (undoable) |
| `:AskAgentBatchUndo` | Undo the last delete / clear, restoring markers |
| `:AskAgentBatchClear` | Drop every queued question (undoable) |
| `:AskAgentDiff [id\|head]` | Review what changed: newest turn, a turn id, or `head` = whole worktree since HEAD |
| `:AskAgentSnapshot [id]` | Start (no arg) or close (`last`, a turn id) a manual review interval |
| `:AskAgentHistory [query]` | Search questions sent before (re-ask / copy / jump / delete) |
| `:AskAgentPrompt[!] [name]` | Use a prompt template, rendered against the current anchor (`!` = include the selection) |
| `:AskAgentPromptSave[!] <name>` | Save the selection/current line as a prompt (`!` = project file) |

No keymaps are installed: the plugin only defines commands. Map them yourself, e.g.

```lua
vim.keymap.set({ "n", "v" }, "<leader>aq", function()
  require("ask_agent").ask({ visual = vim.fn.mode() ~= "n" })
end, { desc = "Ask agent" })
vim.keymap.set({ "n", "v" }, "<leader>ab", function()
  require("ask_agent").batch_ask({ visual = vim.fn.mode() ~= "n" })
end, { desc = "Ask agent: queue" })
vim.keymap.set("n", "<leader>aB", "<cmd>AskAgentBatchSend<cr>", { desc = "Ask agent: send queue" })
vim.keymap.set("n", "<leader>ai", "<cmd>AskAgentRename<cr>", { desc = "Ask agent: rename" })
```

In the **ask window**: `<C-s>` sends, `<Esc>`/`<C-c>` cancels, `<CR>` is a newline.
In the **map**: letter picks that pane, `<Tab>` switches to the list, `<Esc>` cancels.
In the **list**: number (or `<M-a>` for items past 9) picks, `<Tab>` goes back to the map.
Each entry carries its live status, colored by state: `●` idle, a spinner while busy (your question is
delivered immediately but pi processes it after the current turn — you get a notice
saying so), `⚠` blocked (a send would sit unread), `✓` done, `✗` error, `○` not
running. In the map the status is a colored badge after the pane letter, so the
agent glyph stays visible; a running turn animates that badge. Choosing a `○` entry
only warns — nothing is sent.

Busy rows animate when the picker implementation supports it: the plugin passes
`tick = 90` in the `vim.ui.select` opts and uses `frame` in `format_item(item, frame)`,
the contract `ui-menu.nvim` honours (it re-renders every tick while waiting for a key).
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

  -- list implementation: "auto" (ui-menu if installed, else vim.ui.select),
  -- "ui_menu" (require it), or "vim_ui". ui-menu gives centering, spinner
  -- animation and <Tab> back to the map; it is recommended, not required.
  list_impl = "auto",

  -- also list exited instances in the list picker as "not running" (default true)
  show_stale = true,

  -- frames for the busy icon (default: a 10-frame braille spinner). Point it at the
  -- spinner your picker already uses, e.g. require("ui_menu").frames, and both the
  -- list and the map animate with the same glyphs.
  spinner = { "⠋", "⠙", "⠹", "⠸" },

  -- animation interval for the busy icon, in ms (default 90); match your picker's tick
  tick = 90,

  -- how often the state layer polls every backend, in ms (default 2000)
  state_interval = 2000,

  -- report finished/blocked agents through vim.notify (default true)
  state_notify = true,

  -- notification house style: bold text in the level's diagnostic colour
  -- (default true; a notification plugin such as nvim-notify keeps its own look)
  notify_style = true,

  -- ring the terminal bell with every notification (default false);
  -- :set belloff=all still mutes it
  notify_sound = false,

  -- draw │ ├ └ between an agent and its tasks (default true); sidebars
  -- narrower than 20 columns fall back to plain indentation
  tree_lines = true,

  -- light the path from an agent to the task running right now: "dash"
  -- (default; bright cells march down it), "pulse" (one bright cell with a
  -- trailing mid shade), "static" (dim→bright), or "off". Without
  -- truecolor it degrades to a single flat green.
  running_line = "dash",

  -- task rows shown per agent before the "… N older tasks" row (default 5;
  -- false shows every stored task)
  task_limit = 5,

  -- drop finished tasks older than this from the journal, in ms (default 24h);
  -- the newest task of every agent always stays
  task_ttl = 24 * 3600 * 1000,

  -- turn snapshots for change review; `false` disables the feature entirely.
  -- Every sent question (and, with trigger_state, every working→done turn) records
  -- two git trees under the cache dir. keep = newest turns retained,
  -- ttl = max age in ms. Trees are immutable, so review always works offline.
  snapshots = { enabled = true, keep = 50, ttl = 7 * 24 * 3600 * 1000, trigger_state = true },

  -- how :AskAgentDiff renders: "auto" picks the best installed viewer
  -- (diffbandit → nvim.difftool → codediff → builtin). include_unsaved folds
  -- modified buffers into the end side, so an in-flight edit is reviewable too.
  review = { backend = "auto", include_unsaved = true },

  -- `:AskAgentDashboard` <CR> opens the agent in a float; readonly refuses input
  -- (tmux -r, the rex mirror drops stdin). width/height are fractions of the
  -- editor and cap a viewer that knows the agent's own grid (an agent bigger
  -- than the screen gets this share of it; 1 fills the screen).
  view = { readonly = false, width = 0.85, height = 0.75 },

  -- delivered questions, newest 200, with their anchors; `false` records nothing.
  -- path moves the journal; max_text caps one record (a huge paste is truncated).
  history = { enabled = true, keep = 200, max_text = 20000 },

  -- prompt templates: global_path is the user file, project_file is looked up under
  -- the git root (or the nearest ancestor with .ask-agent) and may be committed.
  prompts = { global_path = vim.fn.stdpath("cache") .. "/ask-agent/prompts.json" },

  -- keep tasks and unread marks across restarts (default true);
  -- persist = { path = ".../journal.json", enabled = false } moves or disables it
  persist = true,

  -- default backend id
  default = "pi",

  -- extra backends declared inline (see Backends); they are registered at setup time
  extra = {},

  -- every glyph in the plugin: a flat key is an agent icon (backend or instance id),
  -- the `ui` group styles the interface. This block is the default, verbatim.
  icons = {
    pi = "π",
    claude = vim.fn.nr2char(0x273B),
    generic = vim.fn.nr2char(0xF120),
    fallback = vim.fn.nr2char(0xF06A9), -- unknown agents
    ui = {
      header = vim.fn.nr2char(0xF06A9), -- dashboard winbar / notification prefix
      state = {
        blocked = "⚠",
        done = "✓",
        error = "✗",
        working = "◐",
        idle = "●",
        unknown = "◌",
        gone = "○",
      },
      task = { queued = "◐", done = "✓", error = "✗" },
      tree = { collapsed = "▸", expanded = "▾", leaf = "·" },
      spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    },
  },

  -- brand colors, keyed like agent icons
  icon_colors = { claude = "#d97757" },

  -- instance names live here by default
  aliases = { file = vim.fn.stdpath("cache") .. "/ask-agent/aliases.json" },

  -- live-context RPC bridge; `false` disables it entirely
  bridge = { dir = vim.fn.stdpath("cache") .. "/pi-ctx" },
})
```

### Icons

Everything drawn by the plugin comes from `lua/ask_agent/icons.lua`: agent glyphs,
state marks (`⚠ ✓ ✗ ◐ ● ◌ ○`), task marks in the dashboard tree, the tree folds,
the busy spinner and the header. Override them in one place:

```lua
require("ask_agent").setup({
  icons = {
    claude = "",                      -- agent icon
    fallback = "",                    -- unknown agent
    ui = {
      header = "",                     -- dashboard / notifications
      state = { done = "" },           -- only the keys you want to change
      task = { queued = "…" },
      tree = { collapsed = "▸" },
      spinner = { "1", "2", "3" },      -- a frame list replaces the default entirely
    },
  },
  icon_colors = { claude = "#d97757" }, -- brand colors
})
```

`icons.all()` returns the active registry (glyphs + `ui`), and `icons.ui(group, key)`
/ `icons.spin(frame)` / `icons.header()` are the read accessors other plugins can use.
A top-level `spinner` setup option still wins over `icons.ui.spinner` (it exists so the
picker can share its own animation frames).

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

   Claude Code is wired up already: `extensions/claude-ask-agent-state.sh` writes
   the marker, and these hooks call it —

   ```json
   "hooks": {
     "UserPromptSubmit": [{ "hooks": [{ "type": "command",
       "command": "/bin/sh -c '~/.claude/ask-agent-state.sh busy'", "timeout": 5 }] }],
     "Stop":          [{ "hooks": [{ "type": "command",
       "command": "/bin/sh -c '~/.claude/ask-agent-state.sh idle'", "timeout": 5 }] }],
     "SessionStart":  [{ "hooks": [{ "type": "command",
       "command": "/bin/sh -c '~/.claude/ask-agent-state.sh idle'", "timeout": 5 }] }],
     "SessionEnd":    [{ "hooks": [{ "type": "command",
       "command": "/bin/sh -c '~/.claude/ask-agent-state.sh idle'", "timeout": 5 }] }]
   }
   ```

   Copy the script to `~/.claude/`, add the hooks to `~/.claude/settings.json`, and the
   picker shows `●` idle, a spinner while busy, and tells you the question will be
   queued. Same pattern works for any agent with lifecycle hooks (codex/opencode
   plugins): write `{"busy":true}` on submit, `{"busy":false}` on stop.

2. **Screen scraping** — match on the pane's visible text (`capture-pane`) for a
   spinner or an "esc to interrupt" hint and pass that as `busy`. Zero agent-side
   setup, but it breaks when the UI changes; that is why it is not built in.

Providing `busy` is entirely optional: without it every live target is shown as
idle and delivery goes straight to the pane, which is what the agent's own input
buffer is for.

The marker may carry more than a boolean — anything that speaks OSC 7501 can report
the same state the terminal would display, and `blocked`/`done` then behave exactly
like rex-reported ones (unread marks and notifications):

```json
{"state": "blocked", "kind": "permission", "msg": "run the test suite?"}
```

```sh
# from inside the agent's wrapper, for any agent that can emit an OSC sequence
printf '\033]7501;state=blocked;kind=permission;msg=run%%20the%%20tests%%3F;app=codex\007'
```

Either form is picked up by `probe()` and overridden only by rex, which reports the
same data with full metadata.

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
- `claude` — Claude Code in tmux, busy state read from the marker files its hooks write:

  ```lua
  require("ask_agent").setup({ extra = { require("ask_agent.backends.claude").new() } })
  ```

  `new()` takes `{ id, label, command (default "claude"), command_pattern, state_dir,
  field, ttl, keys_after }`. Then `:AskAgentBackend claude`.

## The map picker

When a layout adapter says which terminal pane an agent lives in, `ask-agent.nvim` draws
your split layout as a small map and puts a letter in each pane that hosts an agent. The map
covers the window nvim lives in and nothing else: its whole point is that a cell's position
mirrors the real pane position, which stops meaning anything once other windows (tabs) are
mixed in. Agents in other windows are chosen from the list (`<Tab>`). Zoom does not collapse
the map: it always uses the full split tree, so an agent in a zoomed-away pane still gets a cell. Panes covered by a floating window are shown but never get the letter — the
label moves to a visible cell of that pane instead, so the map never paints over
whatever is floating on top.

Colors, icons and letters: each instance has a stable color derived from its `id:ts`,
used both in the map and in the list, plus its agent glyph. The letter is bold.
The map itself is compact (blocks touch) and centered on screen.

No adapter is required. The map is the primary picker even for a single locatable
candidate; only when no candidate can be placed in the layout (or there is no
adapter) does it fall back to the list, where `<Tab>` goes back to the map.

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

`:AskAgentRename` (or `n` in the dashboard) names an instance; the name is used
in lists, the ask window title and the "sent" notification. Without a name the
directory basename is shown instead of `pid 123`, then the agent's title/label.

Names are stored in `<cache>/ask-agent/aliases.json` as a slot per backend +
real directory, so they survive a restart: one name in a directory is inherited
by the next instance, and once there are several they are shown as `name ·2`,
`name ·3`. Only a slot bound to the same pid + start time is reused
automatically; a new instance in a crowded directory starts unnamed instead of
guessing. `:AskAgentRename!` clears the name and its slot.

## RPC bridge (live context for the agent)

`setup()` starts a Neovim RPC socket and writes a registration file, so an external
agent can ask Neovim what it is looking at *right now* — including unsaved buffers,
visual selection, LSP diagnostics and the quickfix list — instead of reading disk.

Call it one-shot, no client state needed:

```sh
nvim --server <sock> --remote-expr \
  'v:lua.require("ask_agent.bridge").handle("<base64(json)>")'
```

Requests: `state`, `buffer`, `diagnostics`, `quickfix`, `list`, `project`,
`agents` (`{state?}` filter), `ask` (`{text, backend?, target?}`), `task`
(`{key}`) and `status` — the last four make the
whole control plane reachable from a terminal agent, not just from your own Lua
config.
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

### MCP server

`bin/ask-agent-mcp` exposes the same plane as an MCP server, so a client that only
speaks MCP (Claude Desktop, another agent) gets tools without any Lua:

```json
{"mcpServers": {"ask-agent": {"command": "/Users/you/neovim-plugins/ask-agent.nvim/bin/ask-agent-mcp"}}}
```

Tools: `agents`, `ask`, `task`, `status` — the same actions as the
bridge, forwarded to the nvim instance working in the current directory (or
`$ASK_AGENT_SOCK`). It is python3 + `nvim` only; nothing to install.

## API

```lua
local ask = require("ask_agent")

ask.setup(opts)
ask.ask(opts)                 -- ask ({ visual = true })
ask.batch_ask(opts)           -- queue instead of send ({ visual = true })
ask.batch_send(opts)          -- send queued ({ ids = "3,5-7" }; nil = all), route-aware
ask.batch_route(ids, opts)    -- route queued entries to an agent ({ clear = true } clears)
ask.batch_list()              -- list queued questions (send/route/jump/edit/delete)
ask.batch_clear() / ask.batch_count()
ask.send(text, opts)          -- send without the ask window ({ correlation = { plugin, key }, anchor = a })
ask.task(key)                 -- newest task handed to that agent
ask.agents(opts)              -- every instance, most urgent first ({ state, backend, correlation })
ask.on(event, fn)             -- "state" | "update" | "done" | "blocked" | "error"; returns unsubscribe
ask.wait(key, want, ms, cb)   -- cb(rec) once that instance reaches a state (cb(nil) on timeout)
ask.statusline()              -- "⚠1 ✓2 ◐3", empty when nothing needs attention
ask.dashboard(opts)           -- open the sidebar ({ pos = "right", width = 40 }; pos = "left" moves it)
ask.goto_anchor(a)            -- jump to a captured anchor (false + reason if gone)
ask.diff(opts)                -- review changes ({ id = turn, head = true, backend, cwd })
ask.snapshot(id)              -- start (nil) or close ("last", an id) a manual interval
ask.turns(cwd)                -- recorded turns, newest first ({ id, start, finish, ... })
ask.history(opts)             -- delivered questions, newest first ({ query, cwd, backend, limit })
ask.prompts(cwd)              -- prompt templates visible from a directory
ask.prompt(name, opts)        -- ask with a template rendered against the anchor
ask.prompt_save(name, text, opts) / ask.prompt_remove(name, opts)
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
ask.view(target, opts)        -- show an agent in a viewer float ({ readonly })
ask.register_view(mod)        -- register a viewer provider (rex/tmux/herdr built in)
ask.views()                   -- registered providers, highest priority first
```

## Agent status

`ask_agent.state` is the single truth about every instance: it polls the backends
every `state_interval` ms (default 2000), and the picker, the dashboard, the
statusline and other plugins all read from it, so they cannot disagree.

A source that knows the real thing wins: rex reports each block's
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status.md) program
status (`working` / `blocked` with `kind` / `done` / `error` metadata), which is
used when the target carries `rex = { session, block }`. Otherwise the backend's
probe decides (`busy` → working, else idle, no probe → unknown, `running = false`
→ gone). When a turn ends while we know we sent something into it, the state
becomes `done` with `unread = true`; that survives later polls that only know
`idle`, until you acknowledge it.

States: `idle`, `working`, `blocked` (`kind` = `permission` / `question` /
`auth`), `done`, `error`, `unknown`, `gone`. `blocked` is reported on every
transition into it; `done` and `error` are throttled to one per 30 s per instance,
and a finished turn is not reported while its local terminal is the current
window. `done` and `blocked` stay in the dashboard and count in the statusline
until `a` (acknowledge) or `d` (dismiss) — the CLI stays the place where work is
accepted.

Where an observation came from is kept as `rec.source` — `rex` (the agent reported
itself), `probe` (the backend's own hook/pane probe), or `heuristic` (nobody said
"done", the turn simply stopped looking busy; the sidebar labels those `inferred`).

A blocked agent is reported, never answered from Neovim: the sidebar and statusline
show `blocked` (with the agent's own message) and `<CR>` brings its terminal window
to the front. Permission prompts, choices and passwords are answered in that
terminal — the protocol carries no structured options, so injecting text would be
a guess.

Journal: the tasks and unread marks are written to
`stdpath("cache")/ask-agent/journal.json` (1 s debounce, tasks older than a week
dropped on load), so restarting Neovim does not lose who is waiting for you. Turn
it off with `persist = false`.

Events instead of polling: when a target lives in a rex block, the state layer
streams `rex events -s SESSION --json` and reacts to
`terminal.program_status_changed` / `_removed` within milliseconds; the 2 s poll
stays as the fallback for everything else.

```lua
local ask = require("ask_agent")

ask.agents({ state = "blocked" })          -- what needs me right now
ask.wait("pi:91841", "done", 600000, function(rec)
  if rec then print("done:", rec.msg) end
end)
ask.on("done", function(rec)                -- or: react without polling
  local c = rec.dispatch and rec.dispatch.correlation
  if c and c.plugin == "todo2" then require("todo2").complete_by_key(c.key) end
end)
require("lua-line").add(ask.statusline)
```

Correlation is opaque: `ask.send(text, { correlation = { plugin, key } })`
stores it on the instance's record, `:AskAgent` and batch sends do not set one, and
`rec.dispatch = { text, ts, correlation, anchor }` is handed back with every event.

Every send is also appended to `rec.tasks` (newest first, last 20): `{ text, ts,
status = "running" | "done" | "error", correlation, anchor }` — that is what the
sidebar shows under each agent. Tasks finish when the instance reports `done` /
`error`, or when a turn ends after we sent something.

## Dashboard

`:AskAgentDashboard` opens a sidebar on the right (40 columns; `:lua
require("ask_agent").dashboard({ pos = "left", width = 30 })` moves/resizes it): a
tree whose top level is the agents (most urgent first) and whose children are that
agent's tasks — the questions still queued for it and the turns already sent to it:

```
▾ ⚠ reviewer (2)  claude  needs permission: run the test suite?  2m
│ ├─ ◐ add the retry path  queued  3m
│ └─ ⠹ run the test suite  running  41s
▾ ✓ worker-1 (1)  pi      done: 12 files changed  1m
│ └─ ✓ update the docs  done  38s
▾ ◐ worker-2  pi      busy  12s
  └─ ⠹ port the parser  running  12s
```

Tasks hang off their agent with `│ ├ └` connectors (`tree_lines`); the rail under
the fold marker keeps the agent → tasks connection continuous. The path from
an agent down to the task it is running right now is green and animated as a
marching dashed line: one bright cell every three, shifted down one step per
spinner frame (`running_line = "dash"`). `"pulse"` sends a single bright cell with
a trailing mid shade instead, `"static"` keeps a dim→bright gradient, and `"off"`
draws plain tree lines. Sidebars narrower than 20 columns drop the connectors and
keep the old indentation.

The winbar counts what wants you (`⚠2 ✓1 ◐3`) and the sidebar grows once on open
(up to 48 columns) when a row would be truncated; narrow sidebars drop the backend
column before they cut the message. Finished tasks show how long the turn took
(`38s`), running ones how long it has been going; the sort order is blocked/error,
done, working, idle (also in the `?` help). A long task list shows the newest
`task_limit` (5) rows and collapses the rest into `… N older tasks  ⏎ show`
(`<CR>` on that row expands it; folding the agent with `<Tab>` resets the slice).
Finished tasks older than `task_ttl` (24h) leave the journal on the next save, and
loading a journal drops them too — the newest task per agent is always kept.
A turn that another tool dispatched (todo2, a plugin) carries its key on the row,
dim in brackets: `[t42]`, so several sources can share one agent and still be told
apart; `:AskAgentHistory` shows the same as `todo2 t42` in the record line.

Agent glyphs: `●` idle, spinner working, `⚠` blocked, `✓` done, `✗` error, `◌`
unknown, `○` exited. Task glyphs: spinner running, `◐` queued, `✓` done, `✗` failed.

| Key | On an agent | On a task |
| --- | --- | --- |
| `<CR>` | show it in a viewer float | jump to the anchor of a task another tool dispatched; open the agent for a turn of your own |
| `o` | jump to the row's code anchor, when it has one | |
| `s` / `S` | send / flush every queued question routed to it | |
| `a` / `d` | acknowledge / dismiss | delete the queued question |
| `n` | rename (empty restores the directory name) | |
| `v` | review the whole worktree vs HEAD | review the turn behind that task |
| `y` | copy the name | copy the task text |
| `f` | only agents that need you (blocked / error / unread done) — toggle | |
| `<Tab>` | fold the agent's tasks | |
| `?` | key help (a float; `q` closes it) | |
| `r` / `q` | poll now / close | |

Row layout: fold marker, state glyph, name (padded to the longest name) with the task
count, then the message; a task that has a code anchor shows it as `file.lua:42`
flushed right (that is exactly what `<CR>`/`o` jump to), then the age, and the
backend appears on the
right too when more than one backend is running. Tree connectors are colored by
`AskAgentTree` (links to `Comment`); the running path uses the `AskAgentRun*`
groups so both can be restyled from a colorscheme. Rows are truncated to the window
width, narrow windows included, and re-flow when the sidebar is resized. The buffer
updates itself from state and queue events (no polling of its own; the spinner is the
only timer, and it only runs while a turn is actually in progress) and keeps your
cursor where it was.

### Viewing an agent

`<CR>` on an agent in the sidebar opens a float showing that agent — the same
session, the same process, not a copy. The float is a terminal attached to the
host's own second-display command, so the agent keeps running where it was and
closing the float only detaches.

Which terminal or multiplexer shows an agent is user-specific, so the sidebar knows
a provider contract — rex, tmux and herdr ship built in:

```lua
require("ask_agent").register_view({
  id = "herdr",
  priority = 10,                          -- higher wins when several providers match
  can = function(target) return target.herdr ~= nil end,
  cmd = function(target, opts)
    return { cmd = { "herdr", "agent", "attach", target.herdr.id } }
  end,
})
```

`cmd` returns `{ cmd, env, width, height, note }` (everything but `cmd` optional;
`env` removes inherited variables, `note` is a one-line hint shown on the float).
A target matches the first provider (by `priority`) whose `can(target)` returns
true: `target.rex = { session, block }`, `target.pane`, and `target.herdr = { id }`
are what the built-ins look for.

The float opens in terminal mode, exactly like `:terminal`: open it and type.
The float only adds these keys, and its footer always shows them:

| key | mode | what it does |
| --- | --- | --- |
| `<C-q>` | normal + terminal | close the float (the agent keeps running) |
| `q` | normal | same as `<C-q>` |
| `i` | normal | start typing into the agent (writable viewers only) |

`<Esc>` is deliberately not mapped: it belongs to the agent, where it means
"interrupt". Use `<C-q>` to leave (or `<C-\><C-n>` then `q` to copy text
first). The title shows `agent · provider · state` and drops the less important
parts when the float is narrow; the footer shows the keys plus `read only`,
the provider's `note`, and `clipped WxH→WxH` when the agent's grid does not fit
the screen.

Set `view.readonly = true` when you only want to watch: tmux gets `-r`, the rex
mirror ignores stdin, and herdr keeps only its non-takeover display.

One agent has one float: opening the same agent again focuses the open float
instead of stacking another. The float is also tied to the agent: when the
state layer reports it gone, or the host client exits (the rex block closed, the
program in it exited, tmux/herdr detached), the float closes itself — a viewer
never stays behind as a picture of a dead process. For the rex mirror, a block
whose shell outlives the agent (`Ctrl-C` in the float) counts as gone too.

The float is clipped, never wrapped, when the agent's terminal is larger than
the screen: the top of a taller grid is cropped and long lines are cut at the
right, so no agent line can reflow inside the float. The footer reports the
crop.

tmux is attached with `-f ignore-size` and the float is sized to the session's
own grid (window rows plus the status line), so viewing an agent never reflows
the panes somebody else is looking at. Limits worth knowing: this is a second
client, not a mirror, so a full-screen TUI may still repaint when the float is
clamped to a smaller screen than the session; a multiplexer can be configured
(`destroy-unattached`) to end a session when its last client leaves.

Rex has no attach at all, so that viewer is a mirror: `bin/rex-view.py` asks rex
for the block's screen (the visible rows only, not scrollback) as VT text,
repaints whole frames, and forwards what you type with
`com.superlogical.terminal.write`. Frames rather than a spliced byte stream, so
the picture stays right even if the float and the block disagree about size.
Repaints are driven by the block's data connection (`rex.data.terminal.v1`): new
output paints immediately (at most every 20 ms), an idle block costs nothing, and
a keypress echoes in ~25 ms instead of waiting for a poll tick. The helper still
repaints once a second as a safety net, and polls the block's process to exit
(closing the float) when the block closes, when its program exits, or when the
agent exited but the block's shell survived.

## Batch questions

When a question comes up while browsing, `:AskAgentBatch` (or
`:AskAgentBatchVisual` for a selection) queues it instead of sending: the text goes nowhere yet, and the source line gets a
`»` sign plus the question as end-of-line virtual text (`[n]` = queue position). Move
on, queue more. `:AskAgentBatchSend` sends every entry as its own message — each
keeps the anchor captured when it was queued — and `:AskAgentBatchSend 3,5-7`
sends only those entries.

Entries can be routed to different agents: `:AskAgentBatchRoute 3` (or
`:AskAgentBatchRoute` for all, `!` to clear) picks a target of the current backend
(`:AskAgentBackend` switches it) and tags the marker `[3→claude]` in that instance's
color. A batch send then groups by route — routed entries go to their own agent, the
unrouted rest shares one picker — so one queue can be split across several running
agents. Entries follow buffer edits through
their extmarks, and `:AskAgentBatchList` sends/routes/jumps/edits/deletes them.
`:AskAgentBatchDelete` removes the entry on the cursor line; every delete and
`:AskAgentBatchClear` can be undone with `:AskAgentBatchUndo` (in-memory, last 20
operations).

## Change review

`:AskAgentDiff` answers "what did the agent change?" with evidence instead of a
heuristic. At a turn boundary the plugin writes the worktree as a git tree — a temp
copy of `.git/index`, `git add -A`, `git write-tree`, so your real index and refs are
never touched, and nothing is staged or committed. When the turn ends it captures the
second tree. The review is then literally `git diff <start> <finish>`: an immutable
interval anyone can re-run, no transcript parsing, no agent cooperation.

What the plugin can honestly bracket:

| What | When | Limits |
| --- | --- | --- |
| Whole worktree vs `HEAD` | `:AskAgentDiff head`, no turn needed | uncommitted changes from before are included |
| One sent question | tree before the send, tree when the turn ends | your own edits inside the window are indistinguishable |
| Any turn, typed straight into the agent | state layer's `working → done` (`trigger_state`) | needs an agent whose state the backend can see |
| One tool call | — | needs the agent to report it; out of scope |

`blocked` does not close a turn (the agent is waiting, not finished), and a second
question sent to the same agent while a turn is open widens the same window instead of
starting a new one.

**Viewers** are adapters; the plugin never implements a diff engine:

| Backend | Used when | Notes |
| --- | --- | --- |
| `diffbandit` | installed | folder diff with its full rendering; unsaved buffers included |
| `nvim.difftool` | Neovim 0.12+ | zero install (`:packadd nvim.difftool`), rename detection |
| `codediff` | installed | trees are wrapped in ref-less commits, since it expects revisions |
| `builtin` | always | one `filetype=diff` buffer + quickfix of changed files; no dependencies |

Set `review.backend` to pin one, or pass `{ backend = ... }` per call. With
`include_unsaved = true` (default) modified buffers are written into a throwaway copy of
the end tree, so a review shows what is actually in the editor — never what was last
saved. The builtin backend renders committed-to-disk bytes only, since it diffs trees.

Snapshots live in `stdpath("cache")/ask-agent/snapshots.json` (newest 50, 7 days by
default). `:AskAgentSnapshot` brackets an interval by hand (start, then
`:AskAgentSnapshot last` to close) for work that never passed through the plugin;
`:AskAgentDiff <id>` reviews any stored turn, and `:AskAgentDiff` with no argument
reviews the newest one. `ask.turns()` lists what is available.

## Question history and prompts

Both features share one rule: the question the agent sees is `text + anchor`, so both
work by assembling that payload before the send — never by reading the agent back.

**History** (`:AskAgentHistory [query]`) is written on the send path, after the backend
accepted the text, so it never claims a delivery that failed. Each record keeps the
text, the anchor (`path:line`, selection, cwd), the backend and the instance label.
Actions on a record: re-ask (prefills the ask window with the same text and takes a
fresh anchor), copy, jump to the code, delete. Records survive restarts; `jump` falls
back to opening the file by path when the original buffer is gone.

```lua
ask.history({ query = "rename", limit = 10 })  -- newest first, filter by cwd/backend too
```

**Prompts** are JSON files with `{ version = 1, prompts = [{ name, text, desc }] }`:

- global: `stdpath("cache")/ask-agent/prompts.json`
- project: `<root>/.ask-agent/prompts.json` — a project prompt overrides a global one
  with the same name, and `:AskAgentPromptSave!` writes there so it can be committed.

Placeholders are replaced against the anchor captured for that ask (unknown ones are
left verbatim so typos show up):

| Placeholder | Value |
| --- | --- |
| `{{file}}` | anchor path (`src/a.lua`) |
| `{{line}}`, `{{col}}` | anchor position |
| `{{filetype}}` | buffer filetype |
| `{{cwd}}` | anchor cwd |
| `{{selection}}` | visual lines, joined with newlines (empty without a selection) |
| `{{diagnostics}}` | diagnostics attached to the anchor buffer |
| `{{modified}}` | `unsaved` when the buffer had unsaved changes |

`:AskAgentPromptSave <name>` opens an input prefilled with the selection (or the
current line); `:AskAgentPrompt <name>` renders it immediately, and with no name opens
a picker offering use / copy / edit / delete. In Lua: `ask.prompt(name)`,
`ask.prompt_save(name, text, { project = true })`, `ask.prompt_remove(name)`.

## Health

`:checkhealth ask_agent` reports the active backend, how many instances it sees, whether
which layout adapters are usable, which `vim.ui.select` implementation was detected, and where aliases and the bridge registry live.

## Development

```sh
sh tests/run.sh          # every headless test, one PASS/FAIL line each
stylua --check .         # formatting
```

`tests/run.sh` is what CI runs (`.github/workflows/ci.yml`): each test is a
standalone Lua file executed with `nvim --headless --clean -l`, so a failure names
the file and the assertion. Tests never touch your cache: they stub backends and
turn the journal off, except the one test that writes it to `/tmp`.

## License

MIT
