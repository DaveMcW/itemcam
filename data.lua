local selection_tool = {
  name = "itemzoom",
  type = "selection-tool",
  icon = "__itemzoom__/graphics/tool.png",
  icon_size = 64,
  icon_mipmaps = 2,
  flags = {"hidden", "not-stackable", "only-in-cursor"},
  stack_size = 1,
  selection_mode = "any-entity",
  alt_selection_mode = "any-entity",
  selection_cursor_box_type = "entity",
  alt_selection_cursor_box_type = "entity",
  selection_color = {r=1, g=1, b=0, a=1},
  alt_selection_color = {r=1, g=1, b=0, a=1},
}
data:extend{selection_tool}

local shortcut = {
  name = "itemzoom",
  type = "shortcut",
  action = "lua",
  toggleable = true,
  icon = {
    filename = "__itemzoom__/graphics/shortcut-x32.png",
    priority = "extra-high-no-scale",
    size = 32,
    scale = 0.5,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
  disabled_icon = {
    filename = "__itemzoom__/graphics/shortcut-x32-white.png",
    priority = "extra-high-no-scale",
    size = 32,
    scale = 0.5,
    mipmap_count = 2,
    flags = {"gui-icon"}
  },
}
data:extend{shortcut}
