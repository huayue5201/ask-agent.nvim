# Upstream: multi-client viewing gaps in Rex

Draft of a report for the Rex authors (no `rex feedback` command exists). Versions at
the time of writing: `rex 0.0.1793645657-gd018d2`, `api revision 10`.

**Title:** Multi-client viewing: no viewport, no writable stream, no input arbitration

Hi — I maintain a Neovim plugin (`ask-agent.nvim`) that shows an agent running in a Rex
block inside a Neovim floating window. Because Rex has no attach, that window is a text
mirror: it calls `com.superlogical.terminal.format` and forwards keys with
`com.superlogical.terminal.write`. It works, but three things are missing at the server
level and can't be fixed correctly on the client. Filing them together because they
share a cause.

First, to be clear about what I'm *not* asking for: I don't think clients should decide
grid size. `terminal.resize` being a request is right. The gaps are observability and
the shape of the stream.

## 1. A non-owner client can't declare a size, or learn that it is clipped

`terminal.resize` "applies at once if the caller owns the block or no client does, and
otherwise when the caller becomes the owner". So there is no way for a second viewer to
express "I'm 200x60, I'd show all of it if you'd let me" without taking ownership away
from the client the user is actually looking at — and no way to learn that it's
currently showing a crop.

Suggested: a per-connection `com.superlogical.terminal.viewport {columns, rows,
cell_width_px?, cell_height_px?}` that never changes ownership. The server keeps the
grid with the owner and answers with the verdict (`grid: {columns, rows}`, `viewport:
{columns, rows}`, `clipped: bool`). Symmetrically, expose that state (e.g.
`terminal.info` or fields on `format`/the data stream) so a viewer can label itself
"clipped 200x60 → 120x40" instead of silently cutting. The server has all the facts —
attached clients, owners, viewports — and is the only party that can arbitrate without
thrash (two clients resizing each other is a repaint loop).

## 2. The data stream can't be consumed by a third-party terminal

`data.connect` with `rex.data.terminal.v1` opens with a binary Ghostty snapshot, so
nothing but a Ghostty-based renderer can read it. Combined with the addressed-grid issue
above, that forces every external frontend into screen-scraping: pull a full-screen
serialization of the visible grid, diff it locally, repaint. At ≤20 ms per frame on a
200x60 grid that's ~12k cells of VT text per frame, plus two emulations of the same
output.

Either of these would fix it:

- a documented plain-text subprotocol (e.g. `rex.data.terminal.vt.v1`) carrying the same
  VT text `format` produces, so a stream is at least consumable; or
- incrementality in `format` itself: `terminal.format {since: <seq>}` returning only
  changed rows/cells plus the new seq. That alone would cut the cost by an order of
  magnitude for sparse output and would make a mirror a reasonable citizen.

## 3. Writes have no owner, so two interactive viewers interleave

`terminal.write` / `block.event` accept input from any client, with no notion of "who is
typing". With one viewer that's fine. With two — say the Rex pane and my float, or two
floats — keystrokes interleave and cursor state is shared, which is not something a
client can arbitrate (I can only enforce "one of my own windows is writable", which
doesn't cover input from the Rex app).

Options, in increasing scope: report other clients' writes as an event so a viewer can
render them as "remote typing"; a write lease (`terminal.input_lease {take|release}`)
checked on write; or keep writes owner-only and give non-owners an explicit opt-in path.

## 4. Minor: scrollback isn't addressable

`format` returns screen plus scrollback in one shot, with no offset/limit, so a viewer
that wants to page history must re-fetch everything (or `blob_read` the whole thing).
Ranges (`first_line`/`limit`) or a scrollback seq would make this usable.

---

Happy to test any of these against the plugin — it's a real second consumer, which is
probably useful for you.
