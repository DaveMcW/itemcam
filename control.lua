
function on_init()
  global.zoom_controllers = {}
end

function on_lua_shortcut(event)
  if event.prototype_name ~= "item-zoom" then return end

  -- Player clicked the mod button
  local player = game.get_player(event.player_index)
  if player.is_shortcut_toggled("item-zoom") then
    -- Exit zoom mode
    exit_item_zoom(player)
  elseif player.cursor_stack then
    -- Give the player a selection tool
    player.clear_cursor()
    player.cursor_stack.set_stack("item-zoom")
  end
end

function on_player_selected_area(event)
  if event.item ~= "item-zoom" then return end

  -- Player selected an entity to zoom in
  local player = game.get_player(event.player_index)

  -- Sort entities by distance from selection center
  local center = {
    x = (event.area.left_top.x + event.area.right_bottom.x) / 2,
    y = (event.area.left_top.y + event.area.right_bottom.y) / 2,
  }
  local entities = event.entities
  table.sort(entities, function (a, b) return distance(a.position, center) < distance(b.position, center) end)

  for _, entity in pairs(entities) do
    if entity_contains_item(entity) then
      -- Enter zoom mode
      start_item_zoom(player, entity)
      return
    end
  end
end

function distance(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx*dx + dy*dy
end

function start_item_zoom(player, entity)
  player.clear_cursor()
  player.set_shortcut_toggled("item-zoom", true)
  player.print("starting item zoom on " .. entity.name)
  rendering.draw_circle{
    color = {r=1, g=1, b=0, a=1},
    width = 5,
    filled = false,
    target = entity,
    surface = entity.surface,
    radius = 2,
    time_to_live = 120,
  }
end

function exit_item_zoom(player)
  player.set_shortcut_toggled("item-zoom", false)
end

function entity_contains_item(entity, item)

  -- Check output inventory

  local inventory = entity.get_output_inventory()
  if inventory_contains_item(inventory, item) then return true end

  -- Check current recipe

  if entity.type == "assembling-machine"
  or entity.type == "furnace" then
    if entity.get_recipe() and entity.is_crafting() then
      return recipe_contains_item(entity.get_recipe(), item)
    end
  end

  if entity.type == "reactor"
  or entity.type == "burner-generator" then
    local product = entity.burner and entity.burner.currently_burning and entity.burner.currently_burning.burnt_result
    if item then return product.name == item end
    return product ~= nil
  end

  -- Check more inventories

  if entity.type == "construction-robot"
  or entity.type == "logistic-robot" then
    inventory = entity.get_inventory(defines.inventory.robot_cargo)
    if inventory_contains_item(inventory, item) then return true end
    inventory = entity.get_inventory(defines.inventory.robot_repair)
    if inventory_contains_item(inventory, item) then return true end
  end

  if entity.type == "inserter" then
    if not entity.held_stack.valid_for_read then return false end
    if item and entity.held_stack.name ~= item then return false end
    return entity.held_stack.count > 0
  end

  if entity.type == "mining-drill" then
    local target = entity.mining_target
    if not target then return end
    return recipe_contains_item(target.prototype.mineable_properties, item)
  end

  if entity.type == "roboport" then
    inventory = entity.get_inventory(defines.inventory.roboport_material)
    return inventory_contains_item(inventory, item)
  end

  if entity.type == "transport-belt"
  or entity.type == "underground-belt"
  or entity.type == "splitter"
  or entity.type == "linked-belt"
  or entity.type == "loader-1x1"
  or entity.type == "loader-1x2" then
    for i = 1, entity.get_max_transport_line_index() do
      local line = entity.get_transport_line(i)
      if inventory_contains_item(line, item) then return true end
    end
  end

  return false
end

function inventory_contains_item(inventory, item)
  if not inventory then return false end
  if not item then
    return inventory.get_item_count() > 0
  else
    return inventory.get_item_count(item) > 0
  end
end

function recipe_contains_item(recipe, item)
  if not recipe.products then return false end
  for _, product in pairs(recipe.products) do
    if product.type == "item" then
      if not item then return true end
      if product.name == item then return true end
    end
  end
  return false
end

script.on_init(on_init)
script.on_event(defines.events.on_player_selected_area, on_player_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, on_player_selected_area)
script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)


