-- ---------------------------------------------------------------------------
-- data.lua  (prototype stage)
-- ---------------------------------------------------------------------------
-- The dashboard button lives in Factorio's top-left mod-GUI flow and is created
-- at runtime (see scripts/gui.lua), so almost nothing is needed here.
--
-- We register ONE custom input so the dashboard can also be toggled with a
-- keybind, plus a couple of GUI styles used by the renderer. Everything else
-- reuses vanilla styles so the mod matches the base UI (and dark mode) for free.
-- ---------------------------------------------------------------------------

-- Toggle keybind ------------------------------------------------------------
data:extend({
  {
    type = "custom-input",
    name = "tod-toggle-dashboard",
    key_sequence = "CONTROL + T",
    action = "lua",
  },
  {
    type = "shortcut",
    name = "tod-toggle-dashboard",
    order = "a[train-station-monitor]",
    action = "lua",
    toggleable = false,
    associated_control_input = "tod-toggle-dashboard",
    icon = {
      filename = "__base__/graphics/icons/locomotive.png",
      priority = "extra-high-no-scale",
      size = 64,
      scale = 1,
    },
    small_icon = {
      filename = "__base__/graphics/icons/locomotive.png",
      priority = "extra-high-no-scale",
      size = 64,
      scale = 0.5,
    },
    localised_name = { "mod-name.train-station-monitor" },
    localised_description = { "tod.button-tooltip" },
  },
})

-- GUI styles ----------------------------------------------------------------
-- Extend the default GUI style prototype rather than defining a new theme, so
-- we inherit whatever theme (light / dark) the player has selected.
local styles = data.raw["gui-style"].default

-- Fixed width for the dashboard so columns line up regardless of content.
styles["tod_dashboard_frame"] = {
  type = "frame_style",
  parent = "frame",
  minimal_width = 720,
  maximal_width = 1100,
}

-- A subtle "toolbar" strip that holds the sort / filter / search controls.
styles["tod_toolbar_frame"] = {
  type = "frame_style",
  parent = "subheader_frame",
  horizontally_stretchable = "on",
  horizontal_spacing = 10,
  left_padding = 8,
  right_padding = 8,
  top_padding = 6,
  bottom_padding = 6,
}

-- Scroll pane that holds the (potentially 1000+) resource rows.
styles["tod_rows_scroll"] = {
  type = "scroll_pane_style",
  parent = "scroll_pane",
  minimal_height = 260,
  maximal_height = 640,
  extra_right_padding_when_activated = -12,
}

-- Small square icon button used for the per-station controls (📍 🚂 ⚡).
styles["tod_control_button"] = {
  type = "button_style",
  parent = "tool_button",
  size = 24,
  padding = 1,
}
