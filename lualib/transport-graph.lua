local util = require "util"


--[[
  Ideas not yet implemented:

  Grabbers in a circular branch are unpruneable

  2:1 splitter inputs should move at half speed

  Temporarily cache non-side-merge sinks in one table

  Handle circuit controlled belts

  Handle belts marked for deconstruction

  Rebuild graph if any entity is destroyed

--]]

local DEBUG = true
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
local IS_LOADER = {
  ["loader"] = true,
  ["loader-1x1"] = true,
}
-- CURVE_TYPE[input_direction][output_direction][line_index]
local CURVE_TYPE = {
  [defines.direction.north] = {
    [defines.direction.north] = {},
    [defines.direction.east] = {"outer", "inner"},
    [defines.direction.south] = {},
    [defines.direction.west] = {"inner", "outer"},
  },
  [defines.direction.east] = {
    [defines.direction.north] = {"inner", "outer"},
    [defines.direction.east] = {},
    [defines.direction.south] = {"outer", "inner"},
    [defines.direction.west] = {},
  },
  [defines.direction.south] = {
    [defines.direction.north] = {},
    [defines.direction.east] = {"inner", "outer"},
    [defines.direction.south] = {},
    [defines.direction.west] = {"outer", "inner"},
  },
  [defines.direction.west] = {
    [defines.direction.north] = {"outer", "inner"},
    [defines.direction.east] = {},
    [defines.direction.south] = {"inner", "outer"},
    [defines.direction.west] = {},
  },
}

local function expand_box(box, extra_tiles)
  local result = util.table.deepcopy(box)
  result.left_top.x = result.left_top.x - extra_tiles
  result.left_top.y = result.left_top.y - extra_tiles
  result.right_bottom.x = result.right_bottom.x + extra_tiles
  result.right_bottom.y = result.right_bottom.y + extra_tiles
  return result
end

local function get_belt_curve_type(belt, index)
  -- Only transport belts can be curved
  if belt.type ~= "transport-belt" then return end

  -- Merging belts are always straight
  local inputs = belt.belt_neighbours.inputs
  if #inputs ~= 1 then return end

  local input_direction = belt.direction

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

  return CURVE_TYPE[input_direction][belt.direction][index]
end

--- Conveyor is a collection of belt, line, and index
local function new_conveyor(belt, line, index)
  local conveyor = {
    belt = belt,
    line = line,
    index = index,
    curve_type = get_belt_curve_type(belt, index),
    capacity = 2,
  }

  if conveyor.curve_type == "inner" then
    -- Round down capacity for curved belts
    conveyor.capacity = 1
  elseif belt.type == "transport-belt" then
    -- Increased capacity for straight belts and outer curves
    conveyor.capacity = 4
  elseif index > 2 and belt.type == "underground-belt" then
    -- Variable length for underground section
    local p = belt.neighbours.position
    local distance = math.abs(belt.position.x - p.x) + math.abs(belt.position.y - p.y)
    conveyor.capacity = distance * 4
  end

  return conveyor
end

--- An "edge" is a simple section of the graph between two splitters/merges
local function add_edge(graph, conveyor)
  local edge = {
    head = conveyor, -- splitter line 5-8 or merge output
    middle = conveyor,
    tail = nil, -- splitter line 1-4 or merge input
    sinks = {},
    outputs = {},
  }
  graph.edges[conveyor.belt.unit_number.."-"..conveyor.index] = edge
  return edge
end

--- A "sink" is a conveyor that is likely to have items removed in the future
local function add_sink(edge, conveyor)
  -- Loaders
  local found = conveyor.belt.type == "loader" or conveyor.belt.type == "loader-1x1"

  -- Inserter targets
  if not found then
    local inserters = conveyor.belt.surface.find_entities_filtered{
      area = expand_box(conveyor.belt.bounding_box, global.INSERTER_SEARCH_DISTANCE),
      type = "inserter",
    }
    for _, inserter in pairs(inserters) do
      if inserter.pickup_target == conveyor.belt then
        found = true
        break
      end
    end
  end

  -- Add sink
  if found then
    edge.sinks[conveyor.belt.unit_number] = conveyor
  end
end

--- Calculate transport line index from LuaEntity and LuaTransportLine
local function get_line_index(belt, line)
  for i = 1, belt.get_max_transport_line_index() do
    if line == belt.get_transport_line(i) then
      return i
    end
  end
  return 0
end

--- Return the downstream conveyor
local function get_output_conveyor(conveyor)
  local belt = conveyor.belt
  local line = conveyor.line
  local index = conveyor.index
  if not line.valid then return nil end

  -- 1. Search inside the belt entity and the linked neighbor
  if belt.type == "underground-belt" and belt.belt_to_ground_type == "input" then
    local neighbor = belt.neighbours
    if not neighbor then
      -- Dead end
      return nil
    elseif index <= 2 then
      -- Underground section
      return new_conveyor(belt, belt.get_transport_line(index+2), index+2)
    else
      -- Underground exit
      return new_conveyor(neighbor, neighbor.get_transport_line(index-2), index-2)
    end
  end
  if belt.type == "linked-belt" and belt.linked_belt_type == "input" then
    local neighbor = belt.linked_belt_neighbour
    if neighbor then
      return new_conveyor(neighbor, neighbor.get_transport_line(index), index)
    end
  end

  -- 2. Search the belt entity outputs
  for _, output in pairs(belt.belt_neighbours.outputs) do
    local max_index = 2
    if output.type == "splitter" then
      max_index = 4
    end
    for i = 1, max_index do
      local output_line = output.get_transport_line(i)
      if line.line_equals(output_line) then
        return new_conveyor(output, output_line, i)
      end
    end
  end

  -- 3. If the line does not match because the internal transport line changed,
  -- use LuaTransportBelt.output_lines to find the new line
  local output_line = line.output_lines[1]
  if not output_line or output_line == line then
    -- Dead end
    return nil
  end
  local owner = output_line.owner
  return new_conveyor(owner, output_line, get_line_index(owner, output_line))
end

--- Test if input is side merging to output
---@return number|nil position merge position, or nil if no merge
local function get_side_merge(input, output)
  -- Straight line (same direction)
  if input.belt.direction == output.belt.direction then
    return nil
  end

  -- Underground inputs will never side merge
  if input.index <= 2
  and (input.belt.type == "underground-belt" or input.belt.type == "linked-belt") then
    return nil
  end

  -- Impossible to side merge onto these outputs
  if output.belt.type == "splitter"
  or output.belt.type == "loader"
  or output.belt.type == "loader-1x1" then
    return nil
  end

  -- Straight line (opposite direction)
  if DX[input.belt.direction] == DX[output.belt.direction]
  or DY[input.belt.direction] == DY[output.belt.direction] then
    return nil
  end

  -- Find merge position by comparing it to an inner/outer curve
  local position = 0.99609375
  local new_capacity = 4
  if output.belt.type == "transport-belt"
  and CURVE_TYPE[input.belt.direction][output.belt.direction][input.index] == "inner" then
    position = 0.49609375
    new_capacity = 2
  end

  -- Find the second input belt that we are merging with
  for _, belt in pairs(output.belt.belt_neighbours.inputs) do
    if belt.direction == output.belt.direction then
      output.capacity = new_capacity
      return position
    end
  end

  -- Nothing to merge with, so treat it like a curve
  return nil
end

--- Is there a belt gap on this entity?
local function conveyor_has_gap(conveyor)
  if not conveyor then return false end
  if not conveyor.line.valid then return false end

  -- Ignore starting belt
  if conveyor.is_start then
    return false
  end

  if DEBUG then
    rendering.draw_circle{
      surface = conveyor.belt.surface,
      target = conveyor.belt,
      color = {r=0, g=0, b=1},
      radius = 0.3,
      width = 2,
      time_to_live = 2,
    }
  end

  -- Count items
  if #conveyor.line < conveyor.capacity then
    if DEBUG then
      rendering.draw_circle{
        surface = conveyor.belt.surface,
        target = conveyor.belt,
        color = {r=1, g=0, b=1},
        radius = 0.2,
        width = 2,
        time_to_live = 300,
      }
    end
    return true
  end

  -- There could still be gaps if the belt is at max capacity,
  -- because curve capacity is rounded down,
  -- and the belt at the end of the line rounds item count up.

  if conveyor.curve_type == "inner" then
    -- Test 2 possible gap positions
    return conveyor.line.can_insert_at(0.1015625)
      or conveyor.line.can_insert_at(0.390625)
  end

  if conveyor.curve_type == "outer" then
    -- Test 5 possible gap positions
    return conveyor.line.can_insert_at(0.57421875)
      or conveyor.line.can_insert_at(0.34375)
      or conveyor.line.can_insert_at(0.8046875)
      or conveyor.line.can_insert_at(0.11328125)
      or conveyor.line.can_insert_at(1.03515625)
  end

  if conveyor.capacity == 4 then
    -- Test 4 possible gap positions
    return conveyor.line.can_insert_at(0.375)
      or conveyor.line.can_insert_at(0.625)
      or conveyor.line.can_insert_at(0.125)
      or conveyor.line.can_insert_at(0.875)
  end

  -- Splitter has extra gaps built in, ignore them
  if conveyor.belt.type == "splitter" or IS_LOADER[conveyor.belt.type] then
    return false
  end

  -- Test 2 possible gap positions
  if(conveyor.line.can_insert_at(0.125)
    or conveyor.line.can_insert_at(0.375)) then
      rendering.draw_circle{
        surface = conveyor.belt.surface,
        target = conveyor.belt,
        color = {r=1, g=0, b=1},
        radius = 0.2,
        width = 2,
        time_to_live = 300,
      }
    end
  return conveyor.line.can_insert_at(0.125)
    or conveyor.line.can_insert_at(0.375)
end

--- Follow the edge of the graph
---@return boolean true if a gap is found
local function expand_edge(graph, edge, limit)
  while edge.middle do

    -- Limit search rate
    if graph.count >= limit then
      return graph.result_at_limit
    end
    graph.count = graph.count + 1

    local conveyor = get_output_conveyor(edge.middle)

    -- Dead end
    if not conveyor then
      edge.tail = edge.middle
      edge.middle = nil
      return false
    end

    -- Splitter creates 2 new edges
    if conveyor.belt.type == "splitter" and conveyor.index <= 4 then
      add_sink(edge, conveyor)
      edge.tail = conveyor
      edge.middle = nil

      -- Treat both input lanes the same. This may be unrealistic if
      -- there is input_priority, but it is good enough for now.
      local index = conveyor.index
      if index > 2 then
        index = index - 2
      end

      -- Splitter filter subtracts 1 edge
      local output1_enabled = true
      local output2_enabled = true
      local priority = conveyor.belt.splitter_output_priority
      if priority ~= "none" then
        local filter = conveyor.belt.splitter_filter
        if filter then
          if filter.name == graph.item then
            output1_enabled = (priority == "left")
            output2_enabled = (priority == "right")
          else
            output1_enabled = (priority == "right")
            output2_enabled = (priority == "left")
          end
        end
      end

      -- Add edge #1
      if output1_enabled then
        table.insert(edge.outputs, add_edge(
          graph,
          new_conveyor(conveyor.belt, conveyor.belt.get_transport_line(index+4), index+4)
        ))
      end

      -- Add edge #2
      if output2_enabled then
        table.insert(edge.outputs, add_edge(
          graph,
          new_conveyor(conveyor.belt, conveyor.belt.get_transport_line(index+6), index+6)
        ))
      end
    else
      -- Side merge creates 1 new edge
      local side_merge = get_side_merge(edge.middle, conveyor)
      if side_merge then
        edge.tail = edge.middle
        edge.middle = nil
        local new_edge = add_edge(graph, conveyor)
        add_sink(new_edge, conveyor)
        new_edge.side_merge = side_merge
        table.insert(edge.outputs, new_edge)
      else
        -- Expand the current edge
        add_sink(edge, conveyor)
        edge.middle = conveyor

        if DEBUG then
          rendering.draw_circle{
            surface = conveyor.belt.surface,
            target = conveyor.belt,
            color = {r=0, g=1, b=0},
            radius = 0.4,
            width = 2,
            time_to_live = 300,
          }
        end

      end
    end

    -- Stop searching if we find a gap
    if conveyor_has_gap(conveyor) then
      return true
    end

  end
  return false
end

--- Is there a belt gap somewhere on this edge?
---@return table conveyor The matching output line of the first splitter
local function edge_has_gap(graph, edge, limit)
  -- Only visit the edge once per tick
  if edge.tick == game.tick then
    return nil
  end
  edge.tick = game.tick

  -- Check middle for gaps
  if edge.middle and edge.middle.line.valid
  and (not graph.current_conveyor.line.valid or graph.current_conveyor.line ~= edge.middle.line)
  and conveyor_has_gap(edge.middle) then
    return edge.head
  end

  if next(edge.sinks) then
    -- Ignore upstream sinks in the current edge
    local disable_upstream_sinks = false
    if edge.head.line.valid and edge.head.line == graph.current_edge.head.line then
      disable_upstream_sinks = true
    end

    -- Check sinks for gaps
    for _, sink in pairs(edge.sinks) do
      if (not disable_upstream_sinks or not sink.disabled) and conveyor_has_gap(sink) then
        return edge.head
      end
    end
  end

  -- Expand the edge until we reach a vertex
  if edge.middle and expand_edge(graph, edge, limit) then
    return edge.head
  end

  -- Recursively check the downstream edges

  if #edge.outputs == 0 then
    return nil
  end

  if #edge.outputs == 1 then
    if edge.outputs[1].side_merge
    and edge.outputs[1].head.line.valid
    and not edge.outputs[1].head.line.can_insert_at(edge.outputs[1].side_merge) then
      -- Side merge is blocked by a full straight belt
      return nil
    else
      return edge_has_gap(graph, edge.outputs[1], limit)
    end
  end

  -- Splitter output
  if edge == graph.current_edge then
    -- Ideally we would spend 50% of the limit searching each path.
    -- But if one path terminates early, we want to spend 100% of the limit
    -- searching the other path.
    -- So 67% on the first path is a compromise.
    -- TODO: Find a way to spend 100% of the limit efficiently
    local result1 = edge_has_gap(graph, edge.outputs[1], math.ceil((limit - graph.count) * 0.67))
    local result2 = edge_has_gap(graph, edge.outputs[2], limit)
    if result1 and result2 then
      -- Avoid favoring one side of a splitter
      return edge.outputs[math.random(1,2)].head
    elseif result1 then
      return edge.outputs[1].head
    elseif result2 then
      return edge.outputs[2].head
    end
  else
    -- Just find the first gap
    for _, output in pairs(edge.outputs) do
      if edge_has_gap(graph, output, limit) then
        return output.head
      end
    end
  end

  return nil
end


-- Module definition
local M = {}

function M.new(item, belt, line, index)
  local graph = {
    item = item,
    current_conveyor = new_conveyor(belt, line, index),
    edges = {},
    result_at_limit = true,
  }
  graph.current_edge = add_edge(graph, graph.current_conveyor)
  graph.current_edge.middle.is_start = true
  return graph
end

function M.new_from_loader(item, container, loader)
  local graph = {
    item = item,
    edges = {},
    result_at_limit = false,
  }

  -- The first edge is a fake conveyor made from the container
  graph.current_conveyor = {
    belt = container,
    line = container,
    index = 0,
    capacity = 0,
    is_start = true,
  }
  graph.current_edge = add_edge(graph, graph.current_conveyor)
  graph.current_edge.tail = graph.current_edge.middle
  graph.current_edge.middle = nil

  -- Shuffle lanes
  local index = math.random(2)

  -- The output edges are the lanes of the loader
  table.insert(graph.current_edge.outputs, add_edge(
    graph,
    new_conveyor(loader, loader.get_transport_line(index), index)
  ))
  table.insert(graph.current_edge.outputs, add_edge(
    graph,
    new_conveyor(loader, loader.get_transport_line(3-index), 3-index)
  ))
  return graph
end

--- Update the transport graph position
---@return number|nil position belt position of side merge, if it exists
function M.move_to(graph, belt, line, index)
  local side_merge = nil

  -- Find new edge
  if graph.current_edge.tail
  and graph.current_edge.tail.line.valid
  and graph.current_conveyor.line.valid
  and graph.current_edge.tail.line == graph.current_conveyor.line then
    for _, edge in pairs(graph.current_edge.outputs) do
      if edge.head.line.valid and edge.head.line == line then
        graph.current_edge = edge
        side_merge = edge.side_merge
        break
      end
    end
  end

  -- Update position
  graph.current_conveyor = new_conveyor(belt, line, index)

  -- Disable sinks
  -- TODO: Stop if the current edge loops back on itself
  if graph.current_edge.sinks[belt.unit_number] then
    graph.current_edge.sinks[belt.unit_number].disabled = true
  end

  return side_merge
end

--- Is there a belt gap somewhere downstream?
---@return table conveyor The matching output line of the first splitter
function M.has_gap(graph)
  graph.count = 0
  return edge_has_gap(graph, graph.current_edge, global.BELT_SEARCH_RATE)
end

return M