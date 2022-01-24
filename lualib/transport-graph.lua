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

local function expand_box(box, extra_tiles)
  local result = util.table.deepcopy(box)
  result.left_top.x = result.left_top.x - extra_tiles
  result.left_top.y = result.left_top.y - extra_tiles
  result.right_bottom.x = result.right_bottom.x + extra_tiles
  result.right_bottom.y = result.right_bottom.y + extra_tiles
  return result
end

local function add_edge(graph, belt, line, index)
  local edge = {
    head = {belt=belt, line=line, index=index}, -- splitter(5-8) or merging belt
    middle = {belt=belt, line=line, index=index},
    tail = nil, -- splitter(1-4) or merging belt
    sinks = {},
  }
  table.insert(graph.edges, edge)
  return edge
end

-- A "sink" is an entity that is likely to have items removed in the future
local function add_sink(edge, entity)
  -- Loaders
  local found = entity.belt.type == "loader" or entity.belt.type == "loader-1x1"

  -- Inserter targets
  if not found then
    local inserters = entity.belt.surface.find_entities_filtered{
      area = expand_box(entity.belt.bounding_box, global.INSERTER_SEARCH_DISTANCE),
      type = "inserter",
    }
    for _, inserter in pairs(inserters) do
      if inserter.pickup_target == entity.belt then
        found = true
      end
    end
  end

  if found then
    -- Add sink
    edge[entity.belt.unit_number] = {
      belt = entity.belt,
      line = entity.line,
      index = entity.index,
      enabled = true,
    }
  end
end

function get_line_index(belt, line)
  for i = 1, belt.get_max_transport_line_index() do
    if line == belt.get_transport_line(i) then
      return i
    end
  end
  return 0
end

-- Return an output line and its index
function get_output_line(entity)
  local belt = entity.belt
  local line = entity.line
  local index = entity.index
  -- 1. Search inside the belt entity and the linked neighbor
  if belt.type == "underground-belt" and belt.belt_to_ground_type == "input" then
    local neighbor = belt.neighbours
    if not neighbor then
      -- Dead end
      return nil
    elseif index <= 2 then
      -- Underground section
      return {belt=belt, line=belt.get_transport_line(index+2), index=index+2}
    else
      -- Underground exit
      return {belt=neighbor, line=neighbor.get_transport_line(index-2), index=index-2}
    end
  end
  if belt.type == "linked-belt" and belt.linked_belt_type == "input" then
    local neighbor = belt.linked_belt_neighbour
    if neighbor then
      return {belt=neighbor, line=neighbor.get_transport_line(index), index=index}
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
        return {belt=output, line=output_line, index=i}
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
  return {belt=owner, line=output_line, index=get_line_index(owner, output_line)}
end

local function transport_line_gap(entity)
  if not entity then return false end

  return false
end






function M.new(controller, belt, line, index)
  controller.graph = {
    position = {belt=belt, line=line, index=index},
    edges = {},
    is_complete = false,
  }
  controller.graph.current_edge = add_edge(controller.graph, belt, line, index)
end

function M.move_to(controller, belt, line, index)
  -- Find new edge
  local graph = controller.graph
  if graph.current_edge.tail and graph.current_edge.tail.line == graph.position.line then
    for _, edge in pairs(graph.edges) do
      if edge.head.line == line then
        graph.current_edge = edge
        break
      end
    end
  end
  -- Update position
  graph.position = {belt=belt, line=line, index=index}
  -- Disable sinks
  if graph.current_edge.sinks[belt.unit_number] then
    graph.current_edge.sinks[belt.unit_number].enabled = false
  end
end

function M.has_gap(controller)
  controller.search_count = 0
  local graph = controller.graph

  -- 1. Check middle for gaps
  if transport_line_gap(graph.current_edge.middle) then
    return true
  end

  -- 2. Check sinks for gaps
  for _, sink in pairs(graph.current_edge.sinks) do
    if sink.enabled and transport_line_gap(sink) then
      return true
    end
  end

  -- 3. Expand the graph by searching further down the line
  while graph.current_edge.middle do
    -- Limit search rate
    controller.search_count = controller.search_count + 1
    if controller.search_count > global.BELT_SEARCH_RATE then
      return true
    end

    local new_line = get_output_line(graph.current_edge.middle)

    -- Dead end
    if not new_line then
      graph.current_edge.tail = graph.current_edge.middle
      graph.current_edge.middle = nil
      break
    end

    -- Splitter creates 2 new edges
    if new_line.belt.type == "splitter" then
      graph.current_edge.tail = new_line
      graph.current_edge.middle = nil
      local index = new_line.index
      if index > 2 then
        index = index - 2
      end
      add_sink(graph.current_edge, new_line)
      add_edge(graph, new_line.belt, new_line.get_transport_line(index+4), index+4)
      add_edge(graph, new_line.belt, new_line.get_transport_line(index+6), index+6)
      break
    end

    -- Side merge creates 1 new edge
    local side_merge = get_side_merge(graph.current_edge.middle, new_line)
    if side_merge then
      graph.current_edge.tail = graph.current_edge.middle
      graph.current_edge.middle = nil
      local edge = add_edge(graph, new_line.belt, new_line.line, new_line.index)
      break
    end

  end


  -- 4. Check other edges for gaps

end




return M