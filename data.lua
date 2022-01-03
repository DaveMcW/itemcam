local selection_tool = {
  name = "item-zoom",
  type = "selection-tool",
  icon = "__item-zoom__/graphics/tool.png",
  icon_size = 64,
  icon_mipmaps = 4,
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
  name = "item-zoom",
  type = "shortcut",
  action = "lua",
  toggleable = true,
  icon = {
    filename = "__item-zoom__/graphics/shortcut-x32.png",
    flags = {"gui-icon"},
    mipmap_count = 2,
    priority = "extra-high-no-scale",
    scale = 0.5,
    size = 32
  },
  small_icon = {
    filename = "__item-zoom__/graphics/shortcut-x24.png",
    flags = {"gui-icon"},
    mipmap_count = 2,
    priority = "extra-high-no-scale",
    scale = 0.5,
    size = 24
  },
}
data:extend{shortcut}
