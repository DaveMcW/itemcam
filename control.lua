-- Entity processing order:
-- 1. transport-belt
-- 2. Worker robot movement
-- 3. Worker robot item transfer
-- 4. Inserter movement
-- 5. Inserter item transfer
-- 6. assembling-machine
-- 7. mining-drill

local util = require "util"
local TransportGraph = require "lualib.transport-graph"

-- Constants
local DEBUG = true
local HAS_TRANSPORT_LINE = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
  ["linked-belt"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
}
local IS_CRAFTING_MACHINE = {
  ["assembling-machine"] = true,
  ["furnace"] = true,
  ["rocket-silo"] = true,
  ["reactor"] = true,
  ["burner-generator"] = true,
}
local IS_ROBOT = {
  ["construction-robot"] = true,
  ["logistic-robot"] = true,
}
local IS_LOADER = {
  ["loader"] = true,
  ["loader-1x1"] = true,
}
local IS_ALLOWED_CONTROLLER = {
  [defines.controllers.god] = true,
  [defines.controllers.spectator] = true,
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
  global.cameras = {}
  on_configuration_changed()
end

function on_configuration_changed()
  for _, player in pairs(game.players) do
    exit_itemcam(player)
  end
  on_runtime_mod_setting_changed()
end

function on_runtime_mod_setting_changed()
  local my_settings = settings
  global.INSERTER_SEARCH_DISTANCE = my_settings.global["itemcam-inserter-search-distance"].value
  global.ROBOT_SEARCH_DISTANCE = my_settings.global["itemcam-robot-search-distance"].value
  global.BELT_SEARCH_RATE = my_settings.global["itemcam-belt-search-rate"].value
end

function on_tick()
  for player_index, camera in pairs(global.cameras) do
    local player = game.get_player(player_index)
    if IS_ALLOWED_CONTROLLER[player.controller_type] then
      -- Follow the item
      on_tick_player(player, camera)
    else
      -- The controller changed somehow, abort everything
      global.cameras[player_index] = nil
    end
  end
end

function on_lua_shortcut(event)
  if event.prototype_name == "itemcam" then
    on_console_command(event)
  end
end

function on_console_command(event)
  if event.player_index == nil then return end

  local player = game.get_player(event.player_index)

  -- Exit itemcam mode
  if player.is_shortcut_toggled("itemcam") then
    exit_itemcam(player)
    return
  end

  -- Enter itemcam mode
  if player.selected then
    local item = select_item(player.selected)
    if item or is_crafting_item(entity) then
      start_itemcam(player, item, player.selected, nil)
      return
    end
  end

  -- Give the player a selection tool
  if player.cursor_stack then
    player.clear_cursor()
    player.cursor_stack.set_stack("itemcam")
  end
end

function on_player_selected_area(event)
  if event.item ~= "itemcam" then return end

  -- Player selected an entity to follow
  local player = game.get_player(event.player_index)

  -- Sort entities by distance from selection center
  local entities = event.entities
  local center = {
    x = (event.area.left_top.x + event.area.right_bottom.x) / 2,
    y = (event.area.left_top.y + event.area.right_bottom.y) / 2,
  }
  table.sort(entities, function (a, b) return cmp_dist(a.position, center) < cmp_dist(b.position, center) end)

  for _, entity in pairs(entities) do
    local item = select_item(entity, center)
    if item or is_crafting_item(entity) then
      -- Enter itemcam mode
      start_itemcam(player, item, entity, center)
      return
    end
  end
end

function on_tick_player(player, camera)
  local target = camera.entity

  -- Target was destroyed... but did something grab it?
  if not target.valid and camera.entity_type == "item-entity" and camera.grabbers then
    for _, grabber in pairs(camera.grabbers) do
      local entity = grabber.entity
      if entity.valid
      and entity.type == "inserter"
      and entity.held_stack.valid_for_read
      and entity.held_stack.name == camera.item
      and entity.held_stack.count > grabber.count then
        target = entity
        break
      end
    end
  end

  -- Target was destroyed
  if not target.valid then
    camera.grabbers = nil
    return
  end

  local info = nil

  -- Did we create a new item?
  if not camera.item and IS_CRAFTING_MACHINE[target.type] then
    camera.item = random_item(target.get_output_inventory())
  end

  if target.type == "mining-drill" then
    -- Make a list of all mined items
    local items = {}
    local resource = target.mining_target
    if resource then
      local products = resource.prototype.mineable_properties.products
      if products then
        for _, product in pairs(products) do
          if product.type == "item" then
            table.insert(items, product.name)
          end
        end
      end
    end
    shuffle(items)

    -- Search for mined items in target inventory
    local drop_target = target.drop_target
    if drop_target then
      if IS_CRAFTING_MACHINE[drop_target.type] then
        -- Search only input inventories
        local input_inventory = drop_target.get_inventory(defines.inventory.assembling_machine_input)
        local fuel_inventory = drop_target.get_inventory(defines.inventory.fuel)
        local rocket_inventory = drop_target.get_inventory(defines.inventory.rocket_silo_rocket)
        for _, item in pairs(items) do
          if (input_inventory and input_inventory.get_item_count(item) > 0)
          or (fuel_inventory and fuel_inventory.get_item_count(item) > 0)
          or (rocket_inventory and rocket_inventory.get_item_count(item) > 0) then
            camera.item = nil
            target = drop_target
            break
          end
        end
      else
        -- Search all inventories
        for _, item in pairs(items) do
          if drop_target.get_item_count(item) > 0 then
            camera.item = item
            find_transport_line(drop_target, camera, target.drop_position)
            target = drop_target
            break
          end
        end
      end

    -- Search for mined items on ground
    else
      local entities = target.surface.find_entities_filtered{
        type = "item-entity",
        position = target.drop_position,
      }
      for _, entity in pairs(entities) do
        for _, item in pairs(items) do
          if entity.stack.name == item then
            camera.item = item
            target = entity
            break
          end
        end
      end
    end

  elseif not camera.item then
    -- Wait for a new item to be crafted

  -- Did something grab the item from our target?
  elseif target.get_output_inventory() and camera.grabbers then
    for _, grabber in pairs(camera.grabbers) do
      local entity = grabber.entity
      if entity.valid then
        if entity.type == "inserter"
        and entity.held_stack.valid_for_read
        and entity.held_stack.name == camera.item
        and entity.held_stack_position.x == entity.pickup_position.x
        and entity.held_stack_position.y == entity.pickup_position.y
        and entity.held_stack.count > grabber.count then
          target = entity
          break
        elseif IS_ROBOT[entity.type]
        and entity.get_item_count(camera.item) > grabber.count
        and entity.position.x == target.position.x
        and entity.position.y == target.position.y then
          target = entity
          break
        elseif IS_LOADER[entity.type]
        and entity.get_item_count(camera.item) > 0
        and TransportGraph.has_gap(grabber.graph) then
          target = entity
          find_transport_line(target, camera, nil)
          break
        end
      end
    end

  elseif (HAS_TRANSPORT_LINE[target.type] or target.type == "inserter")
  and not target.drop_target
  and camera.grabbers then
    for _, grabber in pairs(camera.grabbers) do
      local entity = grabber.entity
      if entity.valid
      and entity.type == "inserter"
      and entity.held_stack.valid_for_read
      and entity.held_stack.name == camera.item
      and entity.held_stack.count > grabber.count then
        target = entity
        -- Use current position instead of inserter.pickup_position
        camera.pickup_position = target.held_stack_position
        break
      end
    end

    -- Move the item down the transport line
    if HAS_TRANSPORT_LINE[target.type] then
      info = get_line_info(target, camera.index)
      local speed = target.prototype.belt_speed

      -- Stop at the end of the transport line
      if camera.belt_progress >= info.length then
        -- Ignore transport line split inside splitter
        if target.type ~= "splitter" or camera.belt_progress >= 1 then
          speed = 0
        end
      end

      -- Stop if the belt is full
      local splitter_output_line = nil
      if speed > 0 and not camera.first_line then
        local gap = TransportGraph.has_gap(camera.graph)
        if gap then
          -- Remember which side of the splitter the gap is on
          splitter_output_line = gap.line
        elseif IS_LOADER[target.type] and target.loader_type == "input"
        and target.loader_container
        and target.loader_container.can_insert(camera.item) then
          -- Loader can move without gaps
        else
          -- There is no gap, the belt is full
          speed = 0
        end
      end


      camera.belt_progress = camera.belt_progress + speed

      -- Did the item move to a different transport line?
      if (camera.belt_progress >= info.length and (target.type ~= "splitter" or camera.index <= 4 or camera.belt_progress >= 1))
      or camera.line.get_item_count(camera.item) == 0 then
        if IS_LOADER[target.type] and target.loader_type == "input" then
          -- Check loader target
          if target.loader_container
          and target.loader_container.get_item_count(camera.item) > 0 then
            target = target.loader_container
          end
        else
          local output_lines = get_output_lines(target, camera.line, camera.index)
          local output_line = nil

          -- Pick the splitter line if there are multiple output lines
          if target.type == "splitter" then
            for i = 1, #output_lines do
              if output_lines[i] == splitter_output_line
              and output_lines[i].get_item_count(camera.item) > 0 then
                output_line = output_lines[i]
                break
              end
            end
          end

          -- Pick a random line if there are multiple output lines
          if not output_line then
            shuffle(output_lines)
            for i = 1, #output_lines do
              if output_lines[i] ~= camera.line
              and output_lines[i].get_item_count(camera.item) > 0 then
                output_line = output_lines[i]
                break
              end
            end
          end

          if output_line then
            -- Reset progress, except inside a splitter
            local owner = output_line.owner
            if target.type ~= "splitter" or target ~= owner then
              camera.belt_progress = camera.belt_progress - info.length
              if camera.belt_progress > target.prototype.belt_speed
              or camera.belt_progress < 0 then
                camera.belt_progress = 0
              end
            end
            -- Move to new transport line
            info = nil
            target = owner
            camera.line = output_line
            camera.index = get_line_index(target, output_line)
            camera.first_line = nil
            local side_merge = TransportGraph.move_to(camera.graph, target, output_line, camera.index)
            if side_merge then
              -- Advance to side merge position
              camera.belt_progress = 1 - side_merge
            end
          end
        end
      end
    end

  -- Did the target drop the item somewhere?
  elseif dropper_item_count(target, camera.item) < camera.count then
    if target.type == "inserter" then
      if target.drop_target then
        target = target.drop_target
        find_transport_line(target, camera, target.drop_position)
        if IS_CRAFTING_MACHINE[target.type] then
          camera.item = nil
        end
      else
        -- Search for item on ground
        local items = target.surface.find_entities_filtered{
          type = "item-entity",
          position = target.drop_position,
        }
        for _, item in pairs(items) do
          if item.stack.name == camera.item then
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
        if found.get_item_count(camera.item) > 0 then
          target = found
        else
          -- Did an inserter grab the item in the same tick?
          found = find_picking_inserter(found, camera.item)
          if found then
            target = found
          end
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
        if found.get_item_count(camera.item) then
          target = found
        else
          -- Did an inserter grab the item in the same tick?
          found = find_picking_inserter(found, camera.item)
          if found then
            target = found
          end
        end
      end

      -- Search for a new building
      if target.type == "construction-robot" then
        local prototype = game.item_prototypes[camera.item]
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
    belt_progress = camera.belt_progress or 0
  end

  if target.type == "inserter" then
    -- Calculate a point on the line from drop_position to pickup_position
    local progress = inserter_progress(target)
    local start_pos = camera.pickup_position or (target.pickup_target and target.pickup_target.position) or target.pickup_position
    local end_pos = (target.drop_target and target.drop_target.position) or target.drop_position
    position = {
      x = end_pos.x + progress * (start_pos.x - end_pos.x),
      y = end_pos.y + progress * (start_pos.y - end_pos.y),
    }

    if DEBUG then
      rendering.draw_circle{
        surface = target.surface,
        target = start_pos,
        color = {r=1, g=0, b=0},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
      rendering.draw_circle{
        surface = target.surface,
        target = end_pos,
        color = {r=1, g=1, b=0},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
    end


  elseif HAS_TRANSPORT_LINE[target.type] then
    if not info then
      info = get_line_info(target, camera.index)
    end
    local progress = belt_progress
    if target.type ~= "splitter" then
      progress = belt_progress / info.length
    end
    -- Calculate a point on the transport line
    position = {
      x = info.start_pos.x + progress * (info.end_pos.x - info.start_pos.x),
      y = info.start_pos.y + progress * (info.end_pos.y - info.start_pos.y),
    }

    if DEBUG then
      rendering.draw_circle{
        surface = target.surface,
        target = info.start_pos,
        color = {r=1, g=0, b=0},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
      rendering.draw_circle{
        surface = target.surface,
        target = info.end_pos,
        color = {r=1, g=1, b=0},
        radius = 0.2,
        width = 2,
        time_to_live = 2,
      }
    end
  end

  -- Teleport to the item position
  player.teleport(position, target.surface)

  if DEBUG then
    rendering.draw_circle{
      surface = target.surface,
      target = position,
      color = {r=1, g=1, b=1},
      radius = 0.0005,
      width = 1,
      time_to_live = 120,
    }
  end

  -- Recalculate inserters if the target changed
  -- Never trust inserters pointing at a train
  if camera.entity ~= target
  or target.type == "cargo-wagon"
  or target.type == "artillery-wagon" then
    camera.grabbers = nil
  end

  -- Find entities that could grab the item next tick
  if not camera.grabbers then
    camera.grabbers = find_grabbers(camera, target)
  end

  -- Update item count
  for _, grabber in pairs(camera.grabbers) do
    grabber.count = 0
    local entity = grabber.entity
    if entity.valid
    and entity.type == "inserter"
    and entity.held_stack.valid_for_read
    and entity.held_stack.name == camera.item then
      grabber.count = entity.held_stack.count
    end
  end

  if target.type == "logistic-container" or target.type == "roboport" then
    -- Delete old robots
    for i = #camera.grabbers, 1, -1 do
      if not camera.grabbers[i].entity.valid
      or IS_ROBOT[camera.grabbers[i].entity.type] then
        table.remove(camera.grabbers, i)
      end
    end
    -- Find new robots
    local robots = target.surface.find_entities_filtered{
      area = expand_box(target.bounding_box, global.ROBOT_SEARCH_DISTANCE),
      type = {"construction-robot", "logistic-robot"},
      force = target.force,
    }
    for _, robot in pairs(robots) do
      if not robot.has_items_inside() then
        table.insert(camera.grabbers, {entity=robot, count=0})
      end
    end
  end


  -- Save data for next tick
  camera.entity = target
  camera.entity_type = target.type
  camera.count = dropper_item_count(target, camera.item)
  camera.belt_progress = belt_progress
  if target.type ~= "inserter" then
    camera.pickup_position = nil
  end

  -- Take screenshots
  -- if global.screenshot_count < 100 then
  --   game.take_screenshot {
  --     player = player,
  --     surface = player.surface,
  --     show_entity_info = true,
  --     resolution = {600, 600},
  --     path = "itemcam/screenshot-"..global.screenshot_count..".png"
  --   }
  --   for i = 1, 100000000 do end
  --   global.screenshot_count = global.screenshot_count + 1
  -- end
end

-- Find an inserter on the first tick of its pickup animation
function find_picking_inserter(entity, item)
  local inserters = entity.surface.find_entities_filtered{
    area = expand_box(entity.bounding_box, global.INSERTER_SEARCH_DISTANCE),
    type = "inserter",
  }
  for _, inserter in pairs(inserters) do
    if inserter.pickup_target == entity
    and inserter.held_stack.valid_for_read
    and inserter.held_stack.name == item
    and inserter.held_stack_position.x == inserter.pickup_position.x
    and inserter.held_stack_position.y == inserter.pickup_position.y then
      return inserter
    end
  end
end

function find_grabbers(camera, entity)
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
      area = expand_box(box, global.INSERTER_SEARCH_DISTANCE),
      type = "inserter",
    }
    for _, inserter in pairs(inserters) do

      if inserter.pickup_target == entity then
        -- Found inserter target
        table.insert(grabbers, {entity=inserter})

      elseif (entity.type == "inserter" and not entity.drop_target)
      or entity.type == "item-entity" then
        -- Search pickup_position for inserter target
        local p = inserter.pickup_position
        if p.x >= box.left_top.x
        and p.y >= box.left_top.y
        and p.x <= box.right_bottom.x
        and p.y <= box.right_bottom.y then
          table.insert(grabbers, {entity=inserter})
        end
      end
    end
  end

  -- Loaders
  local loaders = entity.surface.find_entities_filtered{
    area = expand_box(entity.bounding_box, 1),
    type = {"loader", "loader-1x1"},
    force = entity.force,
  }
  for _, loader in pairs(loaders) do
    if loader.loader_container == entity and loader.loader_type == "output" then
      local graph = TransportGraph.new_from_loader(camera.item, entity, loader)
      table.insert(grabbers, {entity=loader, graph=graph})
    end
  end

  shuffle(grabbers)

  return grabbers
end

function find_transport_line(entity, camera, position)
  if not HAS_TRANSPORT_LINE[entity.type] then return end

  -- TODO: Use inserter drop position to eliminate some lines

  -- Pick a random line
  local indexes = {}
  for i = 1, entity.get_max_transport_line_index() do
    table.insert(indexes, i)
  end
  shuffle(indexes)

  for _, index in pairs(indexes) do
    local line = entity.get_transport_line(index)
    if line.get_item_count(camera.item) > 0 then
      camera.line = line
      camera.index = index
      camera.first_line = true
      camera.graph = TransportGraph.new(camera.item, entity, line, index)
      camera.belt_progress = 0

      -- TODO: Make more precise
      local info = get_line_info(entity, index)
      if entity.type == "transport-belt" then
        camera.belt_progress = info.length / 2
      elseif entity.type == "splitter" and index <= 4 then
        camera.belt_progress = 0.5
      elseif IS_LOADER[entity.type] and entity.loader_type == "input" then
        camera.belt_progress = 0.5
      end

      break
    end
  end
end

function get_output_lines(belt, line, index)
  -- Splitter always breaks transport line
  if belt.type == "splitter" and index <= 4 then
    return line.output_lines
  end

  -- Search inside the belt entity and the linked neighbor
  if belt.type == "underground-belt" and belt.belt_to_ground_type == "input" then
    local neighbor = belt.neighbours
    if not neighbor then
      -- Dead end
      return {}
    elseif index <= 2 then
      -- Underground section
      return {belt.get_transport_line(index+2)}
    else
      -- Underground exit
      return {neighbor.get_transport_line(index-2)}
    end
  end
  if belt.type == "linked-belt" and belt.linked_belt_type == "input" then
    local neighbor = belt.linked_belt_neighbour
    if neighbor then
      return {neighbor.get_transport_line(index)}
    end
  end

  -- Search the belt entity outputs
  for _, output in pairs(belt.belt_neighbours.outputs) do
    local max_index = 2
    if output.type == "splitter" then
      max_index = 4
    end
    for i = 1, max_index do
      local output_line = output.get_transport_line(i)
      if line.line_equals(output_line) then
        return {output_line}
      end
    end
  end

  -- If the line does not match because the internal transport line changed,
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

function start_itemcam(player, item, entity, position)
  player.set_shortcut_toggled("itemcam", true)

  if player.cursor_stack
  and player.cursor_stack.valid_for_read
  and player.cursor_stack.name == "itemcam" then
    player.clear_cursor()
  end

  if player.character then
    player.character.walking_state = {walking = false}
  end

  local camera = {
    item = item,
    entity = entity,
    entity_type = entity.type,
    controller_type = player.controller_type,
    character = player.character,
    character_name = player.character and player.character.name,
    count = dropper_item_count(entity, item),
  }
  find_transport_line(entity, camera, position)
  global.cameras[player.index] = camera

  -- Swap to god controller
  if player.controller_type ~= defines.controllers.spectator then
    player.set_controller{type = defines.controllers.god}
  end

  -- Set initial zoom
  player.teleport(entity.position, entity.surface)
  player.zoom = 2

  -- Take screenshots
  --global.screenshot_count = 0
end

function exit_itemcam(player)
  player.set_shortcut_toggled("itemcam", false)

  local camera = global.cameras[player.index]
  if not camera then return end

  -- Delete camera
  global.cameras[player.index] = nil

  -- Search for a valid character
  local character = nil
  if camera.controller_type == defines.controllers.character then
    character = camera.character
    if not character or not character.valid then
      if camera.character_name and game.entity_prototypes[camera.character_name].type == "character" then
        character = player.create_character(camera.character_name)
      else
        character = player.create_character()
      end
    end
  end

  -- Swap back to old controller
  player.set_controller{
    type = camera.controller_type,
    character = character,
  }
end

--- Calculate a distance value using Pythagorean theorem.
--- We can skip the square root, since it is only used to compare two points.
function cmp_dist(a, b)
  return (a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y)
end

--- Return an item if it exists in the entity.
function select_item(entity, position)

  -- Check output inventory

  local inventory = entity.get_output_inventory()
  local item = random_item(inventory)
  if item then return item end

  -- Check inserter hand

  if entity.type == "inserter" then
    if not entity.held_stack.valid_for_read then return end
    return entity.held_stack.name
  end

  -- Check more inventories

  if not entity.has_items_inside() then
    return
  end

  if HAS_TRANSPORT_LINE[entity.type] then
    -- Start with transport lines in a random order
    local indexes = {}
    for i = 1, entity.get_max_transport_line_index() do
      table.insert(indexes, {index=i, distance=0})
    end
    shuffle(indexes)

    -- Sort transport lines by distance from selected position
    if position then
      for _, row in pairs(indexes) do
        local info = get_line_info(entity, row.index)
        local line_pos = {
          x = (info.start_pos.x + info.end_pos.x) / 2,
          y = (info.start_pos.y + info.end_pos.y) / 2,
        }
        if DEBUG then
          rendering.draw_circle{
            surface = entity.surface,
            target = line_pos,
            color = {r=1, g=0.7, b=0},
            radius = 0.1,
            width = 2,
            time_to_live = 300,
          }
        end
        row.distance = cmp_dist(position, line_pos)
      end
      table.sort(indexes, function (a, b) return a.distance < b.distance end)
    end

    -- Pick the closest transport line
    for _, row in pairs(indexes) do
      local line = entity.get_transport_line(row.index)
      item = random_item(line)
      if item then return item end
    end
    return

  elseif IS_ROBOT[entity.type] then
    inventory = entity.get_inventory(defines.inventory.robot_cargo)
    item = random_item(inventory)
    if item then return item end
    inventory = entity.get_inventory(defines.inventory.robot_repair)
    return random_item(inventory)

  elseif entity.type == "roboport" then
    inventory = entity.get_inventory(defines.inventory.roboport_material)
    return random_item(inventory)

  elseif entity.type == "cargo-wagon" then
    inventory = entity.get_inventory(defines.inventory.cargo_wagon)
    return random_item(inventory)

  elseif entity.type == "artillery-wagon" then
    inventory = entity.get_inventory(defines.inventory.artillery_wagon_ammo)
    return random_item(inventory)

  end

end

--- Is the entity crafting or burning a recipe that outputs an item?
function is_crafting_item(entity)
  if entity.type == "assembling-machine" or entity.type == "furnace" then
    if not entity.is_crafting() then return end
    for _, product in pairs(entity.get_recipe().products) do
      if product.type == "item" then
        return true
      end
    end

  elseif entity.type == "reactor" or entity.type == "burner-generator" then
    if entity.burner
    and entity.burner.currently_burning
    and entity.burner.currently_burning.burnt_result
    and entity.burner.currently_burning.burnt_result.product
    and entity.burner.currently_burning.burnt_result.product.type == "item" then
      return true
    end

  elseif entity.type == "mining-drill" then
    local mining_target = entity.mining_target
    if not mining_target then return end
    local products = mining_target.prototype.mineable_properties.products
    if not products then return end
    for _, product in pairs(products) do
      if product.type == "item" then
        return true
      end
    end
  end

end

--- Return random item from the inventory
function random_item(inventory)
  if not inventory then return end
  if inventory.get_item_count() == 0 then return end

  local start = math.random(#inventory)
  for i = start, #inventory do
    if inventory[i].valid_for_read then
      return inventory[i].name
    end
  end
  for i = 1, start-1 do
    if inventory[i].valid_for_read then
      return inventory[i].name
    end
  end
end

function dropper_item_count(entity, item)
  if not item then
    return 0
  end
  if HAS_TRANSPORT_LINE[entity] then
    -- Not an item dropper
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

  local offset = 0.5
  if belt.type == "loader" then
    offset = 1
  end

  start_pos.x = belt.position.x - offset * DX[input_direction]
  start_pos.y = belt.position.y - offset * DY[input_direction]
  end_pos.x = belt.position.x + offset * DX[belt.direction]
  end_pos.y = belt.position.y + offset * DY[belt.direction]

  return {
    input_direction = input_direction,
    start_pos = start_pos,
    end_pos = end_pos,
  }
end

function get_line_info(belt, index)
  local belt_info = get_belt_info(belt)
  local start_pos = belt.position
  local end_pos = belt.position
  local length = 0.5

  if belt.type == "transport-belt" then
    start_pos = line_position(belt_info.start_pos, belt_info.input_direction, index)
    end_pos = line_position(belt_info.end_pos, belt.direction, index)
    -- Adjust length of curved belts
    -- https://forums.factorio.com/viewtopic.php?p=554468#p554468
    local distance = math.abs(start_pos.x - end_pos.x) + math.abs(start_pos.y - end_pos.y)
    length = 1
    if distance < 1 then
      length = 106 / 256
    elseif distance > 1 then
      length = 295 / 256
    end

  elseif (belt.type == "underground-belt" and belt.belt_to_ground_type == "input" and index <= 2)
  or (belt.type == "linked-belt" and belt.linked_belt_type == "input")
  or (IS_LOADER[belt.type] and belt.loader_type == "input") then
    start_pos = line_position(belt_info.start_pos, belt.direction, index)
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif belt.type == "underground-belt" and belt.belt_to_ground_type == "input" and index > 2 then
    start_pos = line_position(belt.position, belt.direction, index)
    local neighbor = belt.neighbours
    if neighbor then
      -- Extend length to meet the paired underground belt
      length = math.abs(belt.position.x - neighbor.position.x) + math.abs(belt.position.y - neighbor.position.y)
    end
    end_pos.x = start_pos.x + DX[belt.direction] * length
    end_pos.y = start_pos.y + DY[belt.direction] * length

  elseif (belt.type == "underground-belt" and belt.belt_to_ground_type == "output")
  or (belt.type == "linked-belt" and belt.linked_belt_type == "output")
  or (IS_LOADER[belt.type] and belt.loader_type == "output") then
    end_pos = line_position(belt_info.end_pos, belt.direction, index)
    start_pos.x = end_pos.x - DX[belt.direction] * length
    start_pos.y = end_pos.y - DY[belt.direction] * length

  elseif belt.type == "splitter" then
    if index <= 4 then
    -- Input buffer takes up most of the belt
    -- https://forums.factorio.com/viewtopic.php?p=554468#p554468
      length = 179 / 256
    else
      length = 77 / 256
    end
    -- Pick the top or bottom side of the splitter
    local position = belt_info.start_pos
    position.x = position.x - DY[belt.direction] * SPLITTER_SIDE[index]
    position.y = position.y + DX[belt.direction] * SPLITTER_SIDE[index]
    -- Pick the correct line on the belt
    start_pos = line_position(position, belt.direction, index)
    -- The dividing line between the input and output is variable,
    -- so use one start_pos and end_pos for the entire splitter
    end_pos.x = start_pos.x + DX[belt.direction]
    end_pos.y = start_pos.y + DY[belt.direction]
  end

  return {
    start_pos = start_pos,
    end_pos = end_pos,
    length = length,
  }
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

--- Calculate transport line index from LuaEntity and LuaTransportLine
function get_line_index(belt, line)
  for i = 1, belt.get_max_transport_line_index() do
    if line == belt.get_transport_line(i) then
      return i
    end
  end
  return 0
end


script.on_init(on_init)
script.on_configuration_changed(on_configuration_changed)
script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_player_selected_area, on_player_selected_area)
script.on_event(defines.events.on_player_alt_selected_area, on_player_selected_area)
script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)
commands.add_command("itemcam", {"command-help.itemcam"}, on_console_command)
