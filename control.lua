require "util"

local INSERTER_SEARCH_DISTANCE = 5
local ROBOT_SEARCH_DISTANCE = 5
local HAS_TRANSPORT_LINE = {
  ["transport-belt"] = 1,
  ["underground-belt"] = 1,
  ["splitter"] = 1,
  ["linked-belt"] = 1,
  ["loader-1x1"] = 1,
  ["loader-1x2"] = 1,
}
local IS_ROBOT = {
  ["construction-robot"] = 1,
  ["logistic-robot"] = 1,
}

function on_init()
  global.zoom_controllers = {}
end

function on_tick()
  for player_index, controller in pairs(global.zoom_controllers) do
    local player = game.get_player(player_index)
    if player.controller_type ~= defines.controllers.god then
      -- The controller changed somehow, abort everything
      global.zoom_controllers[player_index] = nil
    else
      -- Follow the item
      on_tick_player(player, controller)
    end
  end
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
  table.sort(entities, function (a, b) return cmp_dist(a.position, center) < cmp_dist(b.position, center) end)

  for _, entity in pairs(entities) do
    local item = entity_contains_item(entity)
    if item then
      -- Enter zoom mode
      start_item_zoom(player, item, entity)
      return
    end
  end
end

function on_tick_player(player, controller)
  local target = controller.entity

  -- Target was destroyed... but did something grab it?
  if controller.entity_type == "item-entity" then
    for _, grabber in pairs(controller.grabbers) do
      if entity_contains_item(grabber.entity, controller.item) then
        if grabber.entity.type == "inserter" then
          target = grabber.entity
          break
        end
      end
    end
  end

  -- Target was destroyed
  if not target.valid then
    controller.grabbers = {}
    return
  end

  -- Did something grab the item from our target?
  if target.get_output_inventory() then
    for _, grabber in pairs(controller.grabbers) do
      if entity_contains_item(grabber.entity, controller.item) then
        if grabber.entity.type == "inserter" then
          target = grabber.entity
          break
        elseif IS_ROBOT[grabber.entity.type] then
          if target.position.x == grabber.entity.position.x
          and target.position.y == grabber.entity.position.y then
            target = grabber.entity
            break
          end
        end
      end
    end
  end

  if (target.type == "inserter" and not target.drop_target)
  or HAS_TRANSPORT_LINE[target] then
    for _, grabber in pairs(controller.grabbers) do
      if grabber.entity.type == "inserter"
      and entity_contains_item(grabber.entity, controller.item)
      and grabber.entity.held_stack.count > grabber.count then
        target = grabber.entity
        break
      end
    end
  end

  -- Did the target drop the item somwhere?
  if entity_item_count(target, controller.item) < controller.count then
    if target.type == "inserter" then
      if target.drop_target and entity_contains_item(target.drop_target, controller.item) then
        target = target.drop_target
      else
        -- Search for item on ground
        local items = target.surface.find_entities_filtered{
          type = "item-entity",
          position = target.drop_position,
        }
        for _, item in pairs(items) do
          if item.stack.name == controller.item then
            target = item
          end
        end
      end

    elseif target.type == "logistic-robot" then
      local found = target.surface.find_entities_filtered{
        type = "logistic-chest",
        position = target.position,
        force = target.force,
        limit = 1,
      }[1]
      if found and entity_contains_item(found, controller.item) then
        target = found
      end

    elseif target.type == "construction-robot" then
      local found = target.surface.find_entities_filtered{
        type = {"logistic-chest", "roboport"},
        position = target.position,
        force = target.force,
        limit = 1,
      }[1]
      if found and entity_contains_item(found, controller.item) then
        target = found
      else
        -- Search for a new building too
        local prototype = game.item_prototypes[controller.item]
        if prototype.place_result then
          found = target.surface.find_entities_filtered{
            name = prototype.place_result.name,
            position = target.position,
            force = target.force,
            limit = 1,
          }[1]
          if found then
            target = found
          end
        end
      end
    end
  end

  -- Calculate item position
  local position = target.position

  if target.type == "inserter" then
    local progress = inserter_progress(target)

    local start_pos = target.pickup_position
    if target.pickup_target then
      start_pos = target.pickup_target.position
    end

    local end_pos = target.drop_position
    if target.drop_target then
      end_pos = target.drop_target.position
    end

    position = {
      x = end_pos.x + progress * (start_pos.x - end_pos.x),
      y = end_pos.y + progress * (start_pos.y - end_pos.y),
    }
  end

  -- Teleport to the item position
  player.teleport(position, target.surface)

  -- Find potential entities that could grab the item next tick
  controller.grabbers = find_grabbers(target)
  controller.entity = target
  controller.entity_type = target.type
  controller.count = entity_item_count(target, controller.item)

  -- Take screenshots
  if global.screenshot_count < 100 then
    -- game.take_screenshot {
    --   player = player,
    --   surface = player.surface,
    --   show_entity_info = true,
    --   resolution = {600, 600},
    --   path = "item-zoom/screenshot-"..global.screenshot_count..".png"
    -- }
    -- for i = 1, 100000000 do end
    -- global.screenshot_count = global.screenshot_count + 1
  end
end

function find_grabbers(entity)
  local grabbers = {}

  -- Inserters pulling from output inventory
  if entity.get_output_inventory()
  or HAS_TRANSPORT_LINE[entity.type]
  or (entity.type == "inserter" and not entity.drop_target)
  or entity.type == "item-entity" then
    local box = entity.bounding_box
    if entity.type == "inserter" then
      local p = entity.drop_position
      box = {
        left_top = {x = p.x - 0.3, y = p.y - 0.3},
        right_bottom = {x = p.x + 0.3, y = p.y + 0.3},
      }
    end
    local inserters = entity.surface.find_entities_filtered{
      area = expand_box(box, INSERTER_SEARCH_DISTANCE),
      type = {"inserter"},
    }
    for _, inserter in pairs(inserters) do
      local count = 0
      if inserter.held_stack.valid_for_read then
        count = inserter.held_stack.count
      end
      if inserter.pickup_target == entity then
        if count == 0 or HAS_TRANSPORT_LINE[entity.type] then
          table.insert(grabbers, {entity=inserter, count=count})
        end
      elseif (entity.type == "inserter" and not entity.drop_target)
      or entity.type == "item-entity" then
        local p = inserter.pickup_position
        if p.x >= box.left_top.x
        and p.y >= box.left_top.y
        and p.x <= box.right_bottom.x
        and p.y <= box.right_bottom.y then
          table.insert(grabbers, {entity=inserter, count=count})
        end
      end
    end
  end

  -- Robots pulling from specific entities
  if IS_ROBOT[entity.type] then
    local robots = entity.surface.find_entities_filtered{
      area = expand_box(entity.bounding_box, ROBOT_SEARCH_DISTANCE),
      type = {"inserter"},
      force = entity.force,
    }
    for _, robot in pairs(robots) do
      if not entity_contains_item(robot) then
        table.insert(grabbers, {entity=robot, count=0})
      end
    end
  end

  -- TODO: Loaders

  shuffle(grabbers)
  return grabbers
end

-- Return normalized distance from drop_position
function inserter_progress(inserter)
  -- Calculate angle between held_stack_position and drop_position
  local a = inserter.held_stack_position
  local b = inserter.position
  local c = inserter.drop_position
  local angle = math.atan2(a.x-b.x, a.y-b.y) - math.atan2(c.x-b.x, c.y-b.y)
  -- Convert to value betwen 0 and 1
  angle = angle / math.pi
  if angle > 1 then angle = angle - 2 end
  if angle < -1 then angle = angle + 2 end
  return math.abs(angle)
end

function pointOnLine(line1, line2, pt, line3, line4)
  if line1.x == line2.x and line1.y == line2.y then return line3 end

  local dy = line2.y - line1.y
  local dx = line2.x - line1.x
  local U = (dx*(pt.x - line1.x) + dy*(pt.y - line1.y)) / (dx*dx + dy*dy);
  if U > 1 then U = 1 end
  if U < 0 then U = 0 end
  local r = {
    x = line3.x + U * (line4.x - line3.x),
    y = line3.y + U * (line4.y - line3.y),
  }

  rendering.draw_circle{
    surface = game.surfaces[1],
    target = r,
    color = {r=1, g=0, b=0, a=1},
    radius = 0.2,
    width = 3,
    time_to_live = 2,
  }
  return r;
end

function expand_box(box, extra_tiles)
  local result = util.table.deepcopy(box)
  result.left_top.x = result.left_top.x - extra_tiles
  result.left_top.y = result.left_top.y - extra_tiles
  result.right_bottom.x = result.right_bottom.x + extra_tiles
  result.right_bottom.y = result.right_bottom.y + extra_tiles
  return result
end

function start_item_zoom(player, item, entity)
  player.set_shortcut_toggled("item-zoom", true)
  player.clear_cursor()

  -- Save current controller
  local character_name = nil
  if player.character then
    character_name = player.character.name
  end
  global.zoom_controllers[player.index] = {
    item = item,
    entity = entity,
    entity_type = entity.type,
    controller_type = player.controller_type,
    character = player.character,
    character_name = character_name,
    grabbers = {},
    count = entity_item_count(entity, item),
  }

  -- Swap to god controller
  player.set_controller{type = defines.controllers.god}
  player.teleport(entity.position, entity.surface)
  player.zoom = 2

  -- Take screenshots
  global.screenshot_count = 0
end

function exit_item_zoom(player)
  player.set_shortcut_toggled("item-zoom", false)

  local old_controller = global.zoom_controllers[player.index]
  if not old_controller then return end

  -- Search for a valid character
  local character = nil
  if old_controller.controller_type == defines.controllers.character then
    character = old_controller.character
    if not character or not character.valid then
      if old_controller.character_name then
        character = player.create_character(old_controller.character_name)
      else
        character = player.create_character()
      end
    end
  end

  -- Swap back to old controller
  player.set_controller{
    type = defines.controllers.character,
    character = character,
  }
end

-- Calculate a distance value using Pythagorean theorem
function cmp_dist(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx*dx + dy*dy
end

function entity_contains_item(entity, item)

  -- Check output inventory

  local inventory = entity.get_output_inventory()
  local found = inventory_contains_item(inventory, item)
  if found then return found end

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
    if product and product.type == "item" then
      if item and product.name ~= item then return end
      return product.name
    end
  end

  -- Check more inventories

  if IS_ROBOT[entity.type] then
    inventory = entity.get_inventory(defines.inventory.robot_cargo)
    found = inventory_contains_item(inventory, item)
    if found then return found end
    inventory = entity.get_inventory(defines.inventory.robot_repair)
    found = inventory_contains_item(inventory, item)
    if found then return found end
  end

  if entity.type == "inserter" then
    if not entity.held_stack.valid_for_read then return end
    if item and entity.held_stack.name ~= item then return end
    return entity.held_stack.name
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

  if HAS_TRANSPORT_LINE[entity.type] then
    for i = 1, entity.get_max_transport_line_index() do
      local line = entity.get_transport_line(i)
      found = inventory_contains_item(line, item)
      if found then return found end
    end
  end
end

function inventory_contains_item(inventory, item)
  if not inventory then return end
  if inventory.get_item_count() == 0 then return end
  if item and inventory.get_item_count(item) == 0 then return end
  if item then return item end
  local found,count = next(inventory.get_contents());
  return found
end

function recipe_contains_item(recipe, item)
  if not recipe.products then return end
  for _, product in pairs(recipe.products) do
    if product.type == "item" then
      if item and product.name ~= item then return end
      return product.name
    end
  end
  return false
end

function entity_item_count(entity, item)
  local count = entity.get_item_count(item)
  if entity.type == "inserter" and entity.held_stack.valid_for_read then
    count = entity.held_stack.count
  end
  return count
end

function shuffle(t)
  -- https://stackoverflow.com/questions/35572435#68486276
  for i = #t, 2, -1 do
      local j = math.random(i)
      t[i], t[j] = t[j], t[i]
  end
end

script.on_init(on_init)
script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_player_selected_area, on_player_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, on_player_selected_area)
script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)


