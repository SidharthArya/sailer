# sailer

A Wayland compositor written in Zig, built on wlroots. Sailing across in Linux.

## Features

- Multiple layout modes: Ribbon (horizontal scrolling), Tiling, Floating, SmartView
- 10 workspaces with per-workspace layout state
- Status bar with configurable height and font
- Session lock support
- Screenshot capture
- IPC server for external control
- MCP (Model Context Protocol) bridge
- Layer shell support (bars, overlays, etc.)
- Virtual keyboard support
- YAML/JSON config file

## Dependencies

- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) 0.19
- [Zig](https://ziglang.org) 0.15.2+
- wayland-server
- xkbcommon
- pixman
- freetype2
- python3 + PyYAML (for YAML config parsing)

## Building

```sh
zig build
```

The binary is output to `zig-out/bin/sailer`.

To run directly:

```sh
zig build run
```

## Configuration

Config is loaded from `~/.config/sailer/config.yaml` (or `.yml` / `.json`). If none is found, defaults are used.

Example config:

```yaml
font: /usr/share/fonts/TTF/DejaVuSans.ttf
gap: 8
split_ratio: 0.5
focus_on_close: previous
repeat_rate: 25
repeat_delay: 600

bar:
  enabled: true
  exclusive: true
  height: 32
  font_size: 11

keybindings:
  - key: Return
    modifiers: [Ctrl]
    action: spawn
    command: foot

  - key: q
    modifiers: [Ctrl, Shift]
    action: close

  - key: h
    modifiers: [Ctrl]
    action: focus_left

  - key: l
    modifiers: [Ctrl]
    action: focus_right

  - key: r
    modifiers: [Ctrl, Alt]
    action: toggle_ribbon_layout

  - key: t
    modifiers: [Ctrl, Alt]
    action: toggle_tiling_layout

  - key: f
    modifiers: [Ctrl, Alt]
    action: toggle_floating_layout

  - key: f
    modifiers: [Ctrl, Shift]
    action: toggle_floating
```

### Available Actions

| Action | Description |
|---|---|
| `spawn` | Run a command (requires `command` field) |
| `close` | Close focused window |
| `focus_left` / `focus_right` | Move focus between windows |
| `reorder_left` / `reorder_right` | Reorder windows |
| `resize_shrink` / `resize_expand` | Resize focused window |
| `move_left` / `move_right` / `move_up` / `move_down` | Move floating window |
| `toggle_ribbon_layout` | Toggle ribbon layout on/off |
| `toggle_tiling_layout` | Toggle tiling layout on/off |
| `toggle_floating_layout` | Toggle floating layout on/off (all windows float) |
| `toggle_floating` | Toggle focused window between tiled and floating |
| `toggle_maximize` | Maximize/restore focused window |
| `toggle_fullscreen` | Fullscreen/restore focused window |
| `toggle_layout` | Cycle between ribbon and tiling |
| `smart_view` | Toggle SmartView layout |
| `switch_workspace` | Switch to workspace by index (requires `workspace_index`) |
| `focus_output` | Focus next output |
| `toggle_sticky` | Toggle window sticky across workspaces |
| `toggle_hidden` | Toggle window visibility |
| `toggle_locked` | Lock window position |
| `toggle_marked` | Mark/unmark window |
| `toggle_urgent` | Toggle urgent flag |
| `toggle_private` | Toggle private flag |
| `get_screenshot` / `screenshot` | Take a screenshot |
| `set_display_mode` | Set display mode (`discrete`, `spanned`, `mirror`) |
| `cycle_display_mode` | Cycle through display modes |
| `toggle_locked` | Lock the session |
| `terminate` | Exit the compositor |

## Layouts

- **Ribbon** — windows arranged horizontally, scrolls to keep focused window centered
- **Tiling** — classic tiling layout
- **Floating** — all windows are free-floating; individual `toggle_floating` is disabled in this mode
- **SmartView** — focused window takes priority

Layout toggles save the previous layout and restore it on second press.

## License

MIT
