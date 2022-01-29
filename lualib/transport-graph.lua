local util = require "util"

local M = {}

--[[
  blockers - side merges and low-priority splitters
  grabbers - any one of these will keep the belt moving
  splitters - reaching this will prune one branch

  passing a grabber will prune it

  if we reach an already-pruned splitter, rebuild the map.

  grabbers in a circular branch are unpruneable

  filter splitters are really just a belt

  https://en.wikipedia.org/wiki/Tarjan%27s_strongly_connected_components_algorithm

--]]

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

  -- Round down capacity for curved belts
  if conveyor.curve_type == "inner" then
    conveyor.capacity = 1
  elseif belt.type == "transport-belt" then
    conveyor.capacity = 4
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
    edge[conveyor.belt.unit_number] = conveyor
  end
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

--- Return the downstream conveyor
function get_output_conveyor(conveyor)
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

local function conveyor_gap(conveyor)
  if not conveyor then return false end
  if not conveyor.line.valid then return false end


  return false
end

--- Follow the edge of the graph, returning true if a gap is found
local function expand_edge(graph, edge)
  while edge.middle do

    -- Limit search rate
    graph.search_count = graph.search_count + 1
    if graph.search_count > global.BELT_SEARCH_RATE then
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
      local index = conveyor.index
      if index > 2 then
        index = index - 2
      end
      add_edge(graph, new_conveyor(conveyor.belt, conveyor.belt.get_transport_line(index+4), index+4))
      add_edge(graph, new_conveyor(conveyor.belt, conveyor.belt.get_transport_line(index+6), index+6))
    else
      -- Side merge creates 1 new edge
      local side_merge = get_side_merge(edge.middle, conveyor)
      if side_merge then
        edge.tail = edge.middle
        edge.middle = nil
        add_edge(graph, conveyor)
      else
        -- Expand the current edge
        add_sink(edge, conveyor)
        edge.middle = conveyor
      end
    end

    -- Stop searching if we find a gap
    if conveyor_gap(conveyor) then
      return true
    end

  end
  return false
end

function M.new(belt, line, index)
  local graph = {
    current_conveyor = {belt=belt, line=line, index=index},
    edges = {},
    is_complete = false,
  }
  graph.current_edge = add_edge(graph, current_conveyor)
  return graph
end

function M.move_to(graph, belt, line, index)
  -- Find new edge
  if graph.current_edge.tail
  and graph.current_edge.tail.line.valid
  and graph.current_conveyor.line.valid
  and graph.current_end.line == graph.current_conveyor.line then
    for _, edge in pairs(graph.edges) do
      if edge.head.line.valid and edge.head.line == line then
        graph.current_edge = edge
        break
      end
    end
  end

  -- Update position
  graph.current_conveyor = {belt=belt, line=line, index=index}

  -- Disable sinks
  if graph.current_edge.sinks[belt.unit_number] then
    graph.current_edge.sinks[belt.unit_number].disabled = true
  end
end

function M.has_gap(graph)
  graph.search_count = 0

  -- 1. Check middle for gaps
  if conveyor_gap(graph.current_edge.middle) then
    return true
  end

  -- 2. Check sinks for gaps
  for _, sink in pairs(graph.current_edge.sinks) do
    if sink.enabled and conveyor_gap(sink) then
      return true
    end
  end

  -- 3. Expand the edge until we reach a vertex
  if expand_edge(graph, graph.current_edge) then
    return true
  end

  -- 4. Check other edges for gaps

end




return M