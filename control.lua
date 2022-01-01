-- Entity processing order:
-- 1. Transport belt movement/item transfer
-- 2. Worker robot movement
-- 3. Worker robot item transfer
-- 4. Inserter movement
-- 5. Inserter item transfer


require "util"

local DEBUG = true
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
local DX = {
  [defines.direction.north] = 0,
  [defines.direction.east] = 1,
  [defines.direction.south] = 0,
  [defines.direction.west] = -1,
}
local DY = {
  [defines.direction.north] = -1,
  [defines.direction.east] = 0,
  [defines.direction.south] = 1,
  [defines.direction.west] = 0,
}
local SPLITTER_SIDE = {-0.5, -0.5, 0.5, 0.5, -0.5, -0.5, 0.5, 0.5}

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
  local entities = event.entities
  local center = {
    x = (event.area.left_top.x + event.area.right_bottom.x) / 2,
    y = (event.area.left_top.y + event.area.right_bottom.y) / 2,
  }
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
  if not target.valid and controller.entity_type == "item-entity" and controller.grabbers then
    for _, grabber in pairs(controller.grabbers) do
      if grabber.entity.valid
      and grabber.entity.type == "inserter"
      and entity_contains_item(grabber.entity, controller.item)
      and grabber.entity.held_stack.count > grabber.count then
        target = grabber.entity
        controller.grabbers = nil
        break
      end
    end
  end

  -- Target was destroyed
  if not target.valid then
    controller.grabbers = nil
    return
  end

  local info = nil

  -- Did something grab the item from our target?
  if target.get_output_inventory() then
    for _, grabber in pairs(controller.grabbers) do
      if grabber.entity.valid
      and entity_contains_item(grabber.entity, controller.item) then
        if grabber.entity.type == "inserter"
        and grabber.entity.held_stack_position.x == grabber.entity.pickup_position.x
        and grabber.entity.held_stack_position.y == grabber.entity.pickup_position.y then
          target = grabber.entity
          break
        elseif IS_ROBOT[grabber.entity.type]
        and target.position.x == grabber.entity.position.x
        and target.position.y == grabber.entity.position.y then
          target = grabber.entity
          break
        end
      end
    end

  elseif (target.type == "inserter" and not target.drop_target) then
    for _, grabber in pairs(controller.grabbers) do
      if grabber.entity.valid
      and grabber.entity.type == "inserter"
      and entity_contains_item(grabber.entity, controller.item)
      and grabber.entity.held_stack.count > grabber.count then
        target = grabber.entity
        controller.pickup_position = target.held_stack_position
        break
      end
    end

  elseif HAS_TRANSPORT_LINE[target.type] then
    for _, grabber in pairs(controller.grabbers) do
      if grabber.entity.valid
      and grabber.entity.type == "inserter"
      and entity_contains_item(grabber.entity, controller.item)
      and grabber.entity.held_stack.count > grabber.count then

        -- TODO: Compare held_stack_position to belt item position

        target = grabber.entity
        controller.pickup_position = target.held_stack_position
        break
      end
    end

    -- Did the item move to a different belt?
    if HAS_TRANSPORT_LINE[target.type] then
      info = get_line_info(controller.line, target)
      -- Stop at the end of the belt
      if target.type == "splitter" then
        if controller.belt_progress < 1 then
          -- Ignore belt split inside splitter
          controller.belt_progress = controller.belt_progress + target.prototype.belt_speed
        end
      elseif controller.belt_progress < info.length then
        controller.belt_progress = controller.belt_progress + target.prototype.belt_speed
      end
      -- Find new belt
      if (controller.belt_progress >= info.length and (target.type ~= "splitter" or info.index <= 4))
      or controller.line.get_item_count(controller.item) == 0 then
        local output_lines = get_output_lines(controller.line, target)
        local output_line = nil
        -- Pick a random belt
        shuffle(output_lines)
        for i = 1, #output_lines do
          if output_lines[i] ~= controller.line
          and output_lines[i].get_item_count(controller.item) > 0 then
            output_line = output_lines[i]
            break
          end
        end
        if output_line then
          -- Reset progress, except inside a splitter
          if target.type ~= "splitter" or target ~= output_line.owner then
            controller.belt_progress = controller.belt_progress - info.length
            if controller.belt_progress > target.prototype.belt_speed
            or controller.belt_progress < 0 then
              controller.belt_progress = 0
            end
          end
          -- Move to new belt
          controller.line = output_line
          target = output_line.owner
          info = nil
        end
      end
    end

  -- Did the target drop the item somwhere?
  elseif entity_item_count(target, controller.item) < controller.count then
    if target.type == "inserter" then
      if target.drop_target then
        target = target.drop_target
        find_transport_line(target, item, controller)
      else
        -- Search for item on ground
        local items = target.surface.find_entities_filtered{
          type = "item-entity",
          position = target.drop_position,
        }
        for _, item in pairs(items) do
          if item.stack.name == controller.item then
            target = item
            break
          end
        end
      end

    elseif target.type == "logistic-robot" then
      local found = target.surface.find_entities_filtered{
        type = "logistic-container",
        position = target.position,
        force = target.force,
        limit = 1,
      }[1]
      if found then
        if entity_contains_item(found, controller.item) then
          target = found
        else
          -- Did an inserter grab the item in the same tick?
          target = find_picking_inserter(found, controller.item) or target
        end
      end

    elseif target.type == "construction-robot" then
      local found = target.surface.find_entities_filtered{
        type = {"logistic-container", "roboport"},
        position = target.position,
        force = target.force,
        limit = 1,
      }[1]
      if found then
        if entity_contains_item(found, controller.item) then
          target = found
        else
          -- Did an inserter grab the item in the same tick?
          target = find_picking_inserter(found, controller.item) or target
        end
      end

      -- Search for a new building
      if target.type == "construction-robot" then
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

  -- Item position
  local position = target.position
  local belt_progress = nil
  if HAS_TRANSPORT_LINE[target.type] then
    belt_progress = controller.belt_progress or 0
  end

  if target.type == "inserter" then
    -- Calculate a point on the line from drop_position to pickup_position
    local progress = inserter_progress(target)
    local start_pos = controller.pickup_position or (target.pickup_target and target.pickup_target.position) or target.pickup_position
    local end_pos = (target.drop_target and target.drop_target.position) or target.drop_position
    position = {
      x = end_pos.x + progress * (start_pos.x - end_pos.x),
      y = end_pos.y + progress * (start_pos.y - end_pos.y),
    }

    if DEBUG then
      rendering.draw_circle{
        surface = target.surface,
        target = start_pos,
        color = {r=1, g=0, b=0, a=1},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
      rendering.draw_circle{
        surface = target.surface,
        target = end_pos,
        color = {r=1, g=1, b=0, a=1},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
    end


  elseif HAS_TRANSPORT_LINE[target.type] then
    if not info then
      info = get_line_info(controller.line, target)
    end
    local progress
    if target.type == "splitter" then
      progress = controller.belt_progress
    else
      progress = controller.belt_progress / info.length
    end
    -- Calculate a point on the transport line
    position = {
      x = info.start_pos.x + progress * (info.end_pos.x - info.start_pos.x),
      y = info.start_pos.y + progress * (info.end_pos.y - info.start_pos.y),
    }

    if DEBUG then
      rendering.draw_circle{
        surface = target.surface,
        target = position,
        color = {r=1, g=1, b=1, a=1},
        radius = 0.0005,
        width = 1,
        time_to_live = 120,
      }
      rendering.draw_circle{
        surface = target.surface,
        target = info.start_pos,
        color = {r=1, g=0, b=0, a=1},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
      rendering.draw_circle{
        surface = target.surface,
        target = info.end_pos,
        color = {r=1, g=1, b=0, a=1},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
    end
  end

  -- Teleport to the item position
  player.teleport(position, target.surface)

  -- Find potential entities that could grab the item next tick
  controller.grabbers = find_grabbers(target)

  -- Save data for next tick
  controller.entity = target
  controller.entity_type = target.type
  controller.count = entity_item_count(target, controller.item)
  controller.belt_progress = belt_progress
  if target.type ~= "inserter" then
    controller.pickup_position = nil
  end

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

-- Find an inserter on the first tick of its pickup animation
function find_picking_inserter(entity, item)
  local inserters = entity.surface.find_entities_filtered{
    area = expand_box(entity.bounding_box, INSERTER_SEARCH_DISTANCE),
    type = "inserter",
  }
  for _, inserter in pairs(inserters) do
    if inserter.pickup_target == entity
    and inserter.held_stack_position.x == inserter.pickup_position.x
    and inserter.held_stack_position.y == inserter.pickup_position.y
    and entity_contains_item(inserter, item) then
      return inserter
    end
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

    -- Custom bounding boxes for entities that can't be inserter targets
    if entity.type == "item-entity" then
      box = tile_box(box)
    elseif entity.type == "inserter" and not entity.drop_target then
      local p = entity.drop_position
      box = tile_box({left_top = {x=p.x, y=p.y}, right_bottom = {x=p.x, y=p.y}})
    end

    local inserters = entity.surface.find_entities_filtered{
      area = expand_box(box, INSERTER_SEARCH_DISTANCE),
      type = "inserter",
    }
    for _, inserter in pairs(inserters) do
      local count = 0
      if inserter.held_stack.valid_for_read then
        count = inserter.held_stack.count
      end

      if inserter.pickup_target == entity then
        -- Found inserter target
        if count == 0 or HAS_TRANSPORT_LINE[entity.type] then
          table.insert(grabbers, {entity=inserter, count=count})
        end

      elseif (entity.type == "inserter" and not entity.drop_target)
      or entity.type == "item-entity" then
        -- Search pickup_position for inserter target
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
  if entity.type == "logistic-container" or entity.type == "roboport" then
    local robots = entity.surface.find_entities_filtered{
      area = expand_box(entity.bounding_box, ROBOT_SEARCH_DISTANCE),
      type = {"construction-robot", "logistic-robot"},
      force = entity.force,
    }
    for _, robot in pairs(robots) do
      if not entity_contains_item(robot) then
        table.insert(grabbers, {entity=robot, count=0})
      end
    end
  end

  shuffle(grabbers)

  if entity.type == "loader-1x1" or entity.type == "loader-1x2" then
    -- TODO: Loaders
  end

  return grabbers
end

function find_transport_line(entity, item, controller)
  if not HAS_TRANSPORT_LINE[entity.type] then return end
  for i = 1, entity.get_max_transport_line_index() do
    local line = entity.get_transport_line(i)
    if line.get_item_count(controller.item) > 0 then
      controller.line = line
      controller.belt_progress = 0.5
      break
    end
  end
end

function get_output_lines(line, belt)
  local index = get_line_index(line, belt)

  -- 1. Search inside the belt entity
  if belt.type == "underground-belt"
  and belt.belt_to_ground_type == "input"
  and index <= 2 then
    for i = 3, 4 do
      local output_line = belt.get_transport_line(i)
      if line.line_equals(output_line) then
        return {output_line}
      end
    end
  end
  if belt.type == "splitter" and index <= 4 then
    -- Splitter always breaks transport line, so this is easy
    return line.output_lines
  end

  -- 2. Search the underground exit
  if belt.type == "underground-belt"
  and belt.belt_to_ground_type == "input"
  and index > 2
  and belt.neighbours then
    for i = 1, 2 do
      local output_line = belt.neighbours.get_transport_line(i)
      if line.line_equals(output_line) then
        return {output_line}
      end
    end
  end

  -- 3. Search the belt entity outputs
  for _, output in pairs(belt.belt_neighbours.outputs) do
    for i = 1, output.get_max_transport_line_index() do
      local output_line = output.get_transport_line(i)
      if line.line_equals(output_line) then
        return {output_line}
      end
    end
  end

  -- 4. If the line does not match because the internal transport line changed,
  -- use LuaTransportBelt.output_lines to find the new line
  return line.output_lines
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

function draw_circle()
  rendering.draw_circle{
    surface = game.surfaces[1],
    target = r,
    color = {r=1, g=0, b=0, a=1},
    radius = 0.2,
    width = 3,
    time_to_live = 2,
  }
end

function expand_box(box, extra_tiles)
  local result = util.table.deepcopy(box)
  result.left_top.x = result.left_top.x - extra_tiles
  result.left_top.y = result.left_top.y - extra_tiles
  result.right_bottom.x = result.right_bottom.x + extra_tiles
  result.right_bottom.y = result.right_bottom.y + extra_tiles
  return result
end

function tile_box(box)
  -- Select every tile in the box, with a 1 pixel (1/256 tile) margin
  local result = util.table.deepcopy(box)
  result.left_top.x = math.floor(result.left_top.x) + 0.00390625
  result.left_top.y = math.floor(result.left_top.y) + 0.00390625
  result.right_bottom.x = math.ceil(result.right_bottom.x) - 0.00390625
  result.right_bottom.y = math.ceil(result.right_bottom.y) - 0.00390625
  return result
end

function start_item_zoom(player, item, entity)
  player.set_shortcut_toggled("item-zoom", true)
  player.clear_cursor()
  if player.character then
    player.character.walking_state = {walking = false}
  end

  -- Save current controller
  local controller = {
    item = item,
    entity = entity,
    entity_type = entity.type,
    controller_type = player.controller_type,
    character = player.character,
    character_name = player.character and player.character.name,
    grabbers = {},
    count = entity_item_count(entity, item),
  }
  find_transport_line(entity, item, controller)
  global.zoom_controllers[player.index] = controller

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

-- Calculate a distance value using Pythagorean theorem.
-- We can skip the square root, since it is only used to compare two points.
function cmp_dist(a, b)
  return (a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y)
end

-- Return item paramenter if it exists in the entity.
-- Return random item if item parameter is nil.
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

-- Return item paramenter if it exists in the inventory.
-- Return random item if item parameter is nil.
function inventory_contains_item(inventory, item)
  if not inventory then return end
  if inventory.get_item_count() == 0 then return end
  if item and inventory.get_item_count(item) == 0 then return end
  if item then return item end
  local found,count = next(inventory.get_contents());
  return found
end

-- Return item paramenter if it exists in the recipe products.
-- Return random product if item parameter is nil.
function recipe_contains_item(recipe, item)
  if not recipe.products then return end
  for _, product in pairs(recipe.products) do
    if product.type == "item" then
      if item and product.name ~= item then return end
      return product.name
    end
  end
end

function entity_item_count(entity, item)
  if HAS_TRANSPORT_LINE[entity] then
    return 0
  end
  if entity.type == "inserter" and entity.held_stack.valid_for_read then
    return entity.held_stack.count
  end
  return entity.get_item_count(item)
end

function shuffle(t)
  -- https://stackoverflow.com/questions/35572435#68486276
  for i = #t, 2, -1 do
      local j = math.random(i)
      t[i], t[j] = t[j], t[i]
  end
end

function get_belt_info(belt)
  local input_direction = belt.direction
  local start_pos = util.table.deepcopy(belt.position)
  local end_pos = util.table.deepcopy(belt.position)

  -- Curved belt changes input direction
  local inputs = belt.belt_neighbours.inputs
  if belt.type == "transport-belt" and #inputs == 1 then
    if DX[belt.direction] == 0
    and inputs[1].position.x < belt.position.x
    and (inputs[1].type ~= "splitter" or inputs[1].position.x == belt.position.x - 1) then
      input_direction = defines.direction.east

    elseif DX[belt.direction] == 0
    and inputs[1].position.x > belt.position.x
    and (inputs[1].type ~= "splitter" or inputs[1].position.x == belt.position.x + 1) then
      input_direction = defines.direction.west

    elseif DY[belt.direction] == 0
    and inputs[1].position.y < belt.position.y
    and (inputs[1].type ~= "splitter" or inputs[1].position.y == belt.position.y - 1) then
      input_direction = defines.direction.south

    elseif DY[belt.direction] == 0
    and inputs[1].position.y > belt.position.y
    and (inputs[1].type ~= "splitter" or inputs[1].position.y == belt.position.y + 1) then
      input_direction = defines.direction.north
    end
  end

  start_pos.x = belt.position.x - 0.5 * DX[input_direction]
  start_pos.y = belt.position.y - 0.5 * DY[input_direction]
  end_pos.x = belt.position.x + 0.5 * DX[belt.direction]
  end_pos.y = belt.position.y + 0.5 * DY[belt.direction]

  return {
    input_direction = input_direction,
    start_pos = start_pos,
    end_pos = end_pos,
  }
end

function get_line_info(line, belt)
  local belt_info = get_belt_info(belt)
  local start_pos = belt.position
  local end_pos = belt.position
  local length = 1
  local line_index = get_line_index(line, belt)

  if belt.type == "transport-belt" then
    start_pos = line_position(belt_info.start_pos, belt_info.input_direction, line_index)
    end_pos = line_position(belt_info.end_pos, belt.direction, line_index)
    -- Adjust length of curved belts
    -- https://forums.factorio.com/viewtopic.php?p=554468#p554468
    local distance = math.abs(start_pos.x - end_pos.x) + math.abs(start_pos.y - end_pos.y)
    if distance < 1 then
      length = 106 / 256
    elseif distance > 1 then
      length = 295 / 256
    end

  elseif belt.type == "underground-belt" and belt.belt_to_ground_type == "input"
  and line_index <= 2 then
    length = 0.5
    start_pos = line_position(belt_info.start_pos, belt.direction, line_index)
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif belt.type == "underground-belt" and belt.belt_to_ground_type == "input"
  and line_index > 2 then
    length = 0.5
    start_pos = line_position(belt.position, belt.direction, line_index)
    if belt.neighbours then
      -- Extend length to meet the paired underground belt
      length = util.distance(belt.position, belt.neighbours.position)
    end
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif belt.type == "underground-belt" and belt.belt_to_ground_type == "output"
  and line_index <= 2 then
    length = 0.5
    start_pos = line_position(belt.position, belt.direction, line_index)
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif belt.type == "underground-belt" and belt.belt_to_ground_type == "output"
  and line_index > 2 then
    if DEBUG then
      game.print("Item Zoom: I don't think this belt line is used. [gps="..belt.position.x..","..belt.position.y.."]")
    end
    length = 0.5
    start_pos = line_position(belt_info.start_pos, belt.direction, line_index)
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif belt.type == "splitter" then
    if line_index <= 4 then
    -- Input buffer takes up most of the belt
    -- https://forums.factorio.com/viewtopic.php?p=554468#p554468
      length = 179 / 256
    else
      length = 77 / 256
    end
    -- Pick the top or bottom side of the splitter
    local position = belt_info.start_pos
    position.x = position.x - DY[belt.direction] * SPLITTER_SIDE[line_index]
    position.y = position.y + DX[belt.direction] * SPLITTER_SIDE[line_index]
    -- Pick the correct line on the belt
    start_pos = line_position(position, belt.direction, line_index)
    -- The dividing line between the input and output is variable,
    -- so use one start_pos and end_pos for the entire splitter
    end_pos.x = start_pos.x + DX[belt.direction]
    end_pos.y = start_pos.y + DY[belt.direction]
  end

  return {
    start_pos = start_pos,
    end_pos = end_pos,
    length = length,
    index = line_index,
  }
end

function get_line_index(line, belt)
  for i = 1, belt.get_max_transport_line_index() do
    if line == belt.get_transport_line(i) then
      return i
    end
  end
  return 0
end

function line_position(pos, direction, line_index)
  local sign = 1
  if line_index % 2 == 0 then
    sign = sign * -1
  end
  if DY[direction] == 0 then
    sign = sign * -1
  end

  -- Offset from center of belt by 7.5 / 32 tiles
  local result = util.table.deepcopy(pos)
  result.x = result.x + DY[direction] * sign * 0.234375
  result.y = result.y + DX[direction] * sign * 0.234375

  return result
end


script.on_init(on_init)
script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_player_selected_area, on_player_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, on_player_selected_area)
script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)
