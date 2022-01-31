local util = require "util"


--[[
  if we reach an already-pruned splitter, rebuild the map.

  grabbers in a circular branch are unpruneable

  https://en.wikipedia.org/wiki/Tarjan%27s_strongly_connected_components_algorithm

  breadth-first splitter search

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
    head = conveyor, -- splitter(5-8) or merging belt
    middle = conveyor,
    tail = nil, -- splitter(1-4) or merging belt
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

  -- 3. Dead-end splitters are buggy, don't try to follow them.
  -- https://forums.factorio.com/101435
  if belt.type == "splitter" then
    return nil
  end

  -- 4. If the line does not match because the internal transport line changed,
  -- use LuaTransportBelt.output_lines to find the new line
  local output_line = line.output_lines[1]
  if not output_line or output_line == line then
    -- Dead end
    return nil
  end
  local owner = output_line.owner
  return new_conveyor(owner, output_line, get_line_index(owner, output_line))
end

local function get_side_merge(input, output)
  -- TODO: Implement
  return false
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
      color = {r=0, g=0, b=1, a=1},
      radius = 0.3,
      width = 2,
      time_to_live = 2,
    }
  end

  -- Count items
  if #conveyor.line < conveyor.capacity then
    return true
  end

  -- TODO: Curved belt has fractional capacity, we need a more powerful test


  return false
end

--- Follow the edge of the graph
---@return boolean true if a gap is found or the limit is reached
local function expand_edge(graph, edge, limit)
  local count = 0
  while edge.middle do

    -- Limit search rate
    count = count + 1
    if count > limit then
      return true
    end

    local conveyor = get_output_conveyor(edge.middle)

    -- Dead end
    if not conveyor then
      edge.tail = edge.middle
      edge.middle = nil
      return false
    end

    -- Splitter creates 2 new edges
    if conveyor.belt.type == "splitter" then
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
        table.insert(edge.outputs, add_edge(graph, conveyor))
      else
        -- Expand the current edge
        add_sink(edge, conveyor)
        edge.middle = conveyor

        if DEBUG then
          rendering.draw_circle{
            surface = conveyor.belt.surface,
            target = conveyor.belt,
            color = {r=0, g=1, b=0, a=1},
            radius = 0.4,
            width = 2,
            time_to_live = 60,
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
  local result = nil
  for _, output in pairs(edge.outputs) do
    if edge_has_gap(graph, output, math.ceil(limit / #edge.outputs)) then
      result = output.head
    end
  end
  return result
end


-- Module definition
local M = {}

function M.new(item, belt, line, index)
  local graph = {
    item = item,
    current_conveyor = new_conveyor(belt, line, index),
    edges = {},
  }
  graph.current_edge = add_edge(graph, graph.current_conveyor)
  graph.current_edge.middle.is_start = true
  return graph
end

function M.move_to(graph, belt, line, index)
  -- Find new edge
  if graph.current_edge.tail
  and graph.current_edge.tail.line.valid
  and graph.current_conveyor.line.valid
  and graph.current_edge.tail.line == graph.current_conveyor.line then
    for _, edge in pairs(graph.current_edge.outputs) do
      if edge.head.line.valid and edge.head.line == line then
        graph.current_edge = edge
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
end

--- Is there a belt gap somewhere downstream?
---@return table conveyor The matching output line of the first splitter
function M.has_gap(graph)
  return edge_has_gap(graph, graph.current_edge, global.BELT_SEARCH_RATE)
end

return M