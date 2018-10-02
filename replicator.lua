Replicator:drop
               --------------.
           --[[| _  _  _  _  |____________________________
          /   |  || || || ||_|___             _      _   /;
         /.--------------.      /|___       +(_)    (/) //
        / |  _  _  _  _  |     / ___ \      _          //
       /  |  || || || || |____/ ___ \(\)  -(_)        //
      /   |  || || || || |    | /  \(\)   _          //
     /    |______________|____|/   (\)  -(_)        //
    / _                                 _      _   //
   / (\)  Replicator v.42             +(_)    (=) //
  /______________________________________________//
  `-------------------------------------------- ]]

require 'lib/class'
require 'lib/serpent'
require 'lib/utils'
require 'lib/items'

local defaultConfig = {
  state_file = 'state/state.lua',
  position_file = 'state/position.lua',
  storage_file = 'state/storage.lua',
  name_file = 'state/name.txt',
  error_log = 'error.log',
  max_fuel = 1600,
  refuel_treshhold = 0.6,
  lumberjack_interval = 200,
  reeds_interval = 200,
  stuck_count = 200,
  mining_area = 30,
  base_height = 18,
  base_spacing = 20,
}

local startingState = {
  have_base = false,
  have_disk_drive = false,
  have_floppy = false,
  have_baby = false,
  num_babies = 0,
  mining_fails = 0,
}

local cardinal = enum {'north', 'east', 'south', 'west'}

local startingPosition = {
  x = 0, y = 0, z = 0,
  bearing = cardinal.north,
}

local startingMaterials = Materials.fromTable {
  'crafting_table', 'diamond_pickaxe', {'coal', 12}, {'cobblestone', 40},
  {'dirt', 5}, {'log', 10}, {'reeds', 2}, {'sapling', 6}, {'water_bucket', 2}
}

local relocatingMaterials = Materials.fromTable {
  {'cobblestone', 40}, {'dirt', 7}, {'log', 10}, {'reeds', 2},
  {'sapling', 6}, {'water_bucket', 2}
}

local inventoryMaterials = Materials.fromTable {
  {'cobblestone', 64 * 2}, {'dirt', 32}, {'coal', 64},
}

local storageMaterials = Materials.fromTable {
  {'redstone', 64 * 3}, {'sand', 64 * 2}, 'log', 'iron_ore', 'diamond',
  'reeds', 'sapling', 'glass_pane', 'iron_ingot', 'ComputerCraft:Computer',
  'bucket', 'water_bucket', 'diamond_pickaxe', 'crafting_table'
}

local miningMaterials = Materials.fromTable {
  'coal_ore', 'diamond_ore', 'iron_ore', 'lit_redstone_ore',
  'redstone_ore', 'sand'
}

local unwantedMaterials = Materials.fromTable {
  'brown_mushroom', 'cactus', 'carrots', 'deadbush', 'double_plant', 'flint',
  'leaves', 'leaves2', 'log2', 'melon_block', 'melon_seeds', 'melon_stem',
  'potatoes', 'pumpkin', 'pumpkin_seeds', 'pumpkin_stem', 'red_flower',
  'red_mushroom', 'tallgrass', 'torch', 'vine', 'waterlily', 'web', 'wheat',
  'wheat_seeds', 'yellow_flower', 'water', 'flowing_water'
}

local Storage = class('Storage')

function Storage:initialize(position, filename, replicator)
  self.position = position
  self.filename = filename
  self.replicator = replicator
  if fs.exists(self.filename) then
    local file = fs.open(self.filename, 'r')
    local success, data = serpent.load(file.readAll())
    if success then
      self.top = Materials:new(data.top)
      self.bottom = Materials:new(data.bottom)
    else
      error('Corrupted materials data.')
    end
  else
    self.top = Materials:new({})
    self.bottom = Materials:new({})
  end
end

function Storage:reset()
  self.top = Materials:new({})
  self.bottom = Materials:new({})
  self:write()
end

function Storage:count(item)
  return self.top:count(item) + self.bottom:count(item)
end

function Storage:store(item, count)
  if not comparePosition(self.replicator.position, self.position) then
    error('Not at storage.')
  end

  local item = Item.resolve(item)
  if count == nil then
    count = item.count
  end

  local topCount = self.top:count(item)
  local bottomCount = self.bottom:count(item)

  local direction, storage

  if topCount == 0 and bottomCount == 0 then
    if self.bottom:numMaterials() > self.top:numMaterials() then
      direction = 'up'
      storage = self.top
    else
      direction = 'down'
      storage = self.bottom
    end
  else
    if bottomCount > topCount then
      direction = 'down'
      storage = self.bottom
    else
      direction = 'up'
      storage = self.top
    end
  end

  storage:addItem(item, count)
  self.replicator:drop(item, count, direction)
  self:write()
end

function Storage:retrieve(item, count)
  if not comparePosition(self.replicator.position, self.position) then
    error('Not at storage.')
  end

  local item = Item.resolve(item)
  local retrieved = 0

  local topCount = self.top:count(item)
  local bottomCount = self.bottom:count(item)

  if count == nil then
    count = item.count
  end

  if count > (topCount + bottomCount) then
    error('Not enough items in storage.')
  end

  while retrieved < count do

    self.replicator:compactInventory()

    local slot = self.replicator:getEmptySlot()
    if slot == nil then
      error('No space in inventory.')
    end

    turtle.select(slot)
    local direction, input, output, outFn

    if topCount > bottomCount then
      direction = 'up'
      input = self.top
      output = self.bottom
      turtle.suckUp()
      outFn = turtle.dropDown
    else
      direction = 'down'
      input = self.bottom
      output = self.top
      turtle.suckDown()
      outFn = turtle.dropUp
    end

    local slotItem = self.replicator:inspect(slot)
    if slotItem == nil then
      error('Storage inconsistency.')
    end

    input:removeItem(slotItem)
    self:write()

    local need = count - retrieved
    if slotItem.name == item.name then
      if slotItem.count > need then
        self:store(slotItem, slotItem.count - need)
        retrieved = retrieved + need
      else
        retrieved = retrieved + slotItem.count
      end
    else
      outFn()
      output:addItem(slotItem)
      self:write()
    end

    topCount = self.top:count(item)
    bottomCount = self.bottom:count(item)
  end
end

function Storage:write()
  local file = fs.open(self.filename, 'w')
  file.write(serpent.dump({top=self.top, bottom=self.bottom}))
  file.close()
end

local Replicator = class('Replicator')

function Replicator:initialize(config)
  self.config = {}
  for key,default in pairs(defaultConfig) do
    if config and config[key] then
      self.config[key] = config[key]
    else
      self.config[key] = default
    end
  end
  if fs.exists(self.config.state_file) then
    local file = fs.open(self.config.state_file, 'r')
    local success, data = serpent.load(file.readAll())
    if success then
      self.state = data
    else
      error('Corrupted state data.')
    end
  else
    self.state = copy(startingState)
  end
  if fs.exists(self.config.position_file) then
    local file = fs.open(self.config.position_file, 'r')
    local success, data = serpent.load(file.readAll())
    if success then
      self.position = data
    else
      error('Corrupted position data.')
    end
  else
    self.position = copy(startingPosition)
  end
  self.storage = Storage:new({x=1,y=0,z=0}, self.config.storage_file, self)
  self.lastLumberTrip = -self.config.lumberjack_interval
  self.lastReedsTrip = -self.config.reeds_interval
end

function Replicator:simpleMove(direction, steps)
  if steps == nil then
    steps = 1
  end

  local move, attack, detect, dig, axis, delta

  if direction == 'forward' or direction == nil then
    move = turtle.forward
    attack = turtle.attack
    detect = turtle.detect
    dig = turtle.dig

    if self.position.bearing == cardinal.north then
      axis = 'y'
      delta = 1
    elseif self.position.bearing == cardinal.south then
      axis = 'y'
      delta = -1
    elseif self.position.bearing == cardinal.east then
      axis = 'x'
      delta = 1
    elseif self.position.bearing == cardinal.west then
      axis = 'x'
      delta = -1
    else
      error('Invalid bearing.')
    end

  elseif direction == 'up' then
    move = turtle.up
    attack = turtle.attackUp
    detect = turtle.detectUp
    dig = turtle.digUp

    axis = 'z'
    delta = 1

  elseif direction == 'down' then
    move = turtle.down
    attack = turtle.attackDown
    detect = turtle.detectDown
    dig = turtle.digDown

    axis = 'z'
    delta = -1

  else
    error('Invalid direction.')
  end

  local successfulMove, tries
  for _ = 1,steps do
    successfulMove = false
    tries = 0
    while not successfulMove do
      local block = self:inspect(direction)
      if block then
        if not isTurtle(block) then
          dig()
        else
          local side
          if direction == nil or direction == 'forward' then
            side = 'front'
          elseif direction == 'up' then
            side = 'top'
          else
            side = 'bottom'
          end
          if peripheral.isPresent(side) and not peripheral.call(side, 'isOn') then
            -- dig turtles that are off
            dig()
          elseif math.random() < 0.2 then
            -- do the anti-collison dance
            if turtle.forward() then
              sleep(3) while not turtle.back() do end
            elseif turtle.down() then
              sleep(3) while not turtle.up() do end
            else
              turtle.turnLeft()
              if turtle.forward() then
                sleep(3) while not turtle.back() do end
              end
              turtle.turnRight()
            end
          end
        end
      end
      if not move() then
        if turtle.getFuelLevel() == 0 then
          self:refuel()
        else
          attack()
        end
      else
        successfulMove = true
        self.position[axis] = self.position[axis] + delta
        self:writePosition()
      end
      tries = tries + 1
      if tries > self.config.stuck_count then
        error('Got stuck')
      end
    end
  end
end

function Replicator:move(axis, position)
  if type(axis) == 'table' then
    self:move('x', axis.x)
    self:move('y', axis.y)
    self:move('z', axis.z)
    if axis.bearing then self:turn(axis.bearing) end
    return
  end
  local steps = difference(self.position[axis], position)
  if steps == 0 then
    return
  end
  local increase = self.position[axis] < position
  local direction = 'forward'
  if axis == 'x' then
    if increase then self:turn(cardinal.east) else self:turn(cardinal.west) end
  elseif axis == 'y' then
    if increase then self:turn(cardinal.north) else self:turn(cardinal.south) end
  elseif axis == 'z' then
    if increase then direction = 'up' else direction = 'down' end
  else
    error('Invalid axis.')
  end
  self:simpleMove(direction, steps)
end

function Replicator:turn(direction)
  if direction == 'right' then
    direction = ((self.position.bearing - 1 + 1) % 4) + 1
  elseif direction == 'left' then
    direction = ((self.position.bearing - 1 - 1) % 4) + 1
  end

  local delta = (direction - self.position.bearing + 2) % 4 - 2
  local numTurns = math.abs(delta)

  local step, turn
  if delta > 0 then
    turn = turtle.turnRight
    step = 1
  else
    turn = turtle.turnLeft
    step = -1
  end

  for _ = 1,numTurns do
    while not turn() do end
    self.position.bearing = ((self.position.bearing - 1 + step) % 4) + 1
    self:writePosition()
  end
end

function Replicator:getEmptySlot()
  for slotIdx = 1,16 do
    local slotItem = self:inspect(slotIdx)
    if slotItem == nil then
      return slotIdx
    end
  end
  return null
end

function Replicator:inspect(slotOrDirection)
  if slotOrDirection == nil or type(slotOrDirection) == 'string' then
    local inspect
    if slotOrDirection == nil or slotOrDirection == 'forward' then
      inspect = turtle.inspect
    elseif slotOrDirection == 'up' then
      inspect = turtle.inspectUp
    elseif slotOrDirection == 'down' then
      inspect = turtle.inspectDown
    else
      error('Invalid direction.')
    end
    local success, data = inspect()
    if success then
      return Item.fromTable(data)
    else
      return nil
    end
  elseif type(slotOrDirection) == 'number' then
    if slotOrDirection > 16 or slotOrDirection < 1 then
      error('Invalid slot.')
    end
    local item = Item.resolve(turtle.getItemDetail(slotOrDirection))
    if item then
      item.slot = slotOrDirection
    end
    return item
  else
    error('Invalid argument.')
  end
end

function Replicator:inspectAll(filter)
  local filter = Item.resolve(filter)
  local items = {}
  for slotIdx = 1,16 do
    local slotItem = self:inspect(slotIdx)
    if slotItem ~= nil and (filter == nil or slotItem.name == filter.name) then
      table.insert(items, slotItem)
    end
  end
  return items
end

function Replicator:detect(item, direction)
  local item = Item.resolve(item)
  local detected = self:inspect(direction)
  if detected and (item == nil or item.name == detected.name) then
    return true
  end
  return false
end

function Replicator:detectAny(materials, direction)
  local materials = Materials.resolve(materials)
  local detected = self:inspect(direction)
  return materials:count(detected) > 0
end

-- Selects an item
function Replicator:select(item)
  local item = Item.resolve(item)
  if not item then return nil end
  for slotIdx = 1,16 do
    local slotItem = self:inspect(slotIdx)
    if slotItem ~= nil and slotItem.name == item.name then
      turtle.select(slotIdx)
      return item
    end
  end
  return nil
end

function Replicator:count(item)
  local item = Item.resolve(item)
  local count = 0
  for slotIdx = 1,16 do
    local slotItem = self:inspect(slotIdx)
    if slotItem ~= nil and slotItem.name == item.name then
      count = count + slotItem.count
    end
  end
  return count
end

function Replicator:place(item, direction)
  local item = Item.resolve(item)

  local place
  if direction == nil or direction == 'forward' then
    place = turtle.place
  elseif direction == 'up' then
    place = turtle.placeUp
  elseif direction == 'down' then
    place = turtle.placeDown
  else
    error('Invalid direction.')
  end

  if self:select(item) then
    return place()
  end
  return false
end

function Replicator:drop(item, count, direction)
  local item = Item.resolve(item)

  local drop
  if direction == nil or direction == 'forward' then
    drop = turtle.drop
  elseif direction == 'up' then
    drop = turtle.dropUp
  elseif direction == 'down' then
    drop = turtle.dropDown
  else
    error('Invalid direction.')
  end

  local items = self:inspectAll(item)
  local function compare(a, b) return a.count < b.count end
  table.sort(items, compare)

  local dropped = 0
  if count == nil then
    local total = 0
    for _,slotItem in ipairs(items) do
      total = total + slotItem.count
    end
    count = total
  end

  for _,item in ipairs(items) do
      local toDrop = math.min(item.count, count - dropped)
      if toDrop > 0 then
        turtle.select(item.slot)
        drop(toDrop)
        dropped = dropped + toDrop
      end
  end

  return dropped
end

function Replicator:exec(instructions)
  local selectedItem = nil
  for cmd in string.gmatch(instructions, '%S+') do
    local control = string.lower(string.sub(cmd, 0, 1))
    if control == '!' then
      selectedItem = self:select(string.sub(cmd, 2))
    elseif control == 'x' or control == 'y' or control == 'z' then
      self:move(control, tonumber(string.sub(cmd, 2)))
    else
      cmd = string.upper(cmd)
      if     cmd == 'F'  then self:simpleMove('forward')
      elseif cmd == 'U'  then self:simpleMove('up')
      elseif cmd == 'D'  then self:simpleMove('down')
      elseif cmd == 'P'  then self:place(selectedItem)
      elseif cmd == 'PD' then self:place(selectedItem, 'down')
      elseif cmd == 'PU' then self:place(selectedItem, 'up')
      elseif cmd == 'L'  then self:turn('left')
      elseif cmd == 'R'  then self:turn('right')
      elseif cmd == 'N'  then self:turn(cardinal.north)
      elseif cmd == 'E'  then self:turn(cardinal.east)
      elseif cmd == 'S'  then self:turn(cardinal.south)
      elseif cmd == 'W'  then self:turn(cardinal.west)
      elseif cmd == 'SF' then turtle.suck()
      elseif cmd == 'SD' then turtle.suckDown()
      elseif cmd == 'SU' then turtle.suckUp()
      elseif cmd == 'Q'  then turtle.dig()
      elseif cmd == 'QU' then turtle.digUp()
      elseif cmd == 'QD' then turtle.digDown()
      else error('Invalid command.') end
    end
  end
end

function Replicator:refuel(ignoreLimit)
  if turtle.getFuelLevel() == 'unlimited' then
    return 0
  end

  local fuelLevel = turtle.getFuelLevel()
  local fuelLimit = self.config.max_fuel

  if ignoreLimit == true then
    fuelLimit = turtle.getFuelLimit()
  end

  if fuelLevel > fuelLimit - 80 then -- 1 coal gives 80 fuel
    return 0
  end

  local coalStacks = self:inspectAll('coal')
  if table.getn(coalStacks) == 0 then
    if fuelLevel == 0 then
      error('Out of fuel')
    end
    return 0
  end

  local function compare(a, b) return a.count < b.count end
  table.sort(coalStacks, compare)

  local numWanted = math.ceil((fuelLimit - fuelLevel) / 80)
  local numConsumed = 0

  for _,item in ipairs(coalStacks) do
    local consume = math.min(item.count, numWanted - numConsumed)
    if consume > 0 then
      turtle.select(item.slot)
      turtle.refuel(consume)
      numConsumed = numConsumed + consume
    end
  end

  return numConsumed
end

function Replicator:craft(recipe, amount, move)
  local recipe = Recipe.resolve(recipe)
  if amount == nil then amount = 1 end
  if move == nil then move = true end

  local craftSlotMap = {1, 2, 3, 5, 6, 7, 9, 10, 11}
  local storageSlotMap = {4, 8, 12, 13, 14, 15, 16}

  local materials = recipe:getMaterials(amount)
  local items = materials:getItems()

  if not self:haveMaterials(materials) then
    error('Not enough materials for recipe.')
  end

  if materials:numMaterials() > 6 then
    error('Recipe too complex. Max 6 materials.')
  end

  for _,item in ipairs(items) do
    if item.count > 64 then
      error('Can not craft using using multiple stacks of the same material.')
    end
  end

  if move then
    self:move('y', 2)
  end

  -- -- Drop everything but the needed materials in pit/chest
  for _,item in ipairs(self:inspectAll()) do
    if materials.data[item.name] == nil then
      self:drop(item, nil, 'down')
    end
  end
  for _,item in ipairs(items) do
    self:drop(item, self:count(item) - item.count, 'down')
  end

  -- Sort the material types in different slots
  for i,item in ipairs(items) do
    local storageSlot = storageSlotMap[i]
    local slotItem  = self:inspect(storageSlot)
    if slotItem and slotItem.name ~= item.name then
      turtle.select(storageSlot)
      turtle.transferTo(self:getEmptySlot())
    end
    self:select(item)
    turtle.transferTo(storageSlot)
  end

  -- Arrange recipe
  for i,item in ipairs(items) do
    turtle.select(storageSlotMap[i])
    for slotIdx,slotItem in pairs(recipe.items) do
      if item.name == slotItem.name then
        turtle.transferTo(craftSlotMap[slotIdx], slotItem.count * amount)
      end
    end
  end

  -- Finally craft
  turtle.select(1)
  turtle.craft()

  -- Pickup dropped items
  while turtle.suckDown() do end

  -- Go home
  if move then
    self:move('y', 0)
  end
end

function Replicator:smelt(item, fuel)
  local item = Item.resolve(item)
  local fuel = Item.resolve(fuel)
  self:exec [[ Z1 W ]]
  self:drop(fuel, fuel.count)
  self:exec [[ Z2 X-1 ]]
  self:drop(item, item.count, 'down')
  self:exec [[ X0 Z0 X-1 ]]
  sleep(item.count * 10)
  while turtle.suckUp() do end
  self:exec [[ X0 ]]
end

function Replicator:retrieve(item, count)
  self:move(self.storage.position)
  self.storage:retrieve(item, count)
  self:move(startingPosition)
end

function Replicator:store(item, count)
  self:move(self.storage.position)
  self.storage:store(item, count)
  self:move(startingPosition)
end

function Replicator:writePosition()
  local file = fs.open(self.config.position_file, 'w')
  file.write(serpent.dump(self.position))
  file.close()
end

function Replicator:writeState()
  local file = fs.open(self.config.state_file, 'w')
  file.write(serpent.dump(self.state))
  file.close()
end

function Replicator:haveMaterials(materials)
  local materials = Materials.resolve(materials)
  for name,count in pairs(materials.data) do
    local have = self:count(name)
    if self.state.have_base then
      have = have + self.storage:count(name)
    end
    if have < count then
      return false
    end
  end
  return true
end

function Replicator:prepareMaterials(materials)
  local materials = Materials.resolve(materials)
  for _,item in ipairs(materials:getItems()) do
    local inInventory = self:count(item)
    local inStorage = self.storage:count(item)
    if item.count > inInventory then
      self:move(self.storage.position)
      self.storage:retrieve(item, item.count - inInventory)
    end
  end
  self:move(startingPosition)
end

function Replicator:compactInventory()
  for targetIdx = 1,16 do
    local target = self:inspect(targetIdx)
    if target then
      for slotIdx = targetIdx+1,16 do
        local slotItem = self:inspect(slotIdx)
        if slotItem and slotItem.name == target.name and turtle.getItemSpace(targetIdx) > 0 then
          turtle.select(slotIdx)
          turtle.transferTo(targetIdx)
        end
      end
    end
  end
end

function Replicator:inventoryCleaning()
  for _,item in ipairs(inventoryMaterials:getItems()) do
    local itemCount = self:count(item)
    local materialCount = inventoryMaterials:count(item)
    if itemCount > materialCount then
      if item.name == 'minecraft:coal' then
        itemCount = itemCount - self:refuel(true)
      end
      self:drop(item, itemCount - materialCount, 'down')
    end
  end

  for _,item in ipairs(self:inspectAll()) do
    if item.name == 'minecraft:sapling' and (item.metadata == 5 or item.metadata == 3) then
      self:drop(item, nil, 'down')
    end
    if unwantedMaterials:count(item) > 0 then
      self:drop(item, nil, 'down')
    end
    local maxStored = storageMaterials:count(item)
    if maxStored > 1 then
      local toDrop = self.storage:count(item) + item.count - maxStored
      if toDrop > 0 then
        self:drop(item, toDrop, 'down')
      end
    end
  end

  if comparePosition(self.position, startingPosition) then
    for _,item in ipairs(storageMaterials:getItems()) do
      local itemCount = self:count(item)
      if itemCount > 0 then
        self:move(self.storage.position)
        self.storage:store(item, itemCount)
      end
    end
    self:move(startingPosition)

    for _,item in ipairs(self:inspectAll()) do
      if not inventoryMaterials.data[item.name] then
        self:drop(item, nil, 'down')
      end
    end
  end
end

function Replicator:drawBackground()
  local w, h = term.getSize()
  for x = 1,w do
    for y = 1,h do
      if math.random() < 0.3 then
        term.setCursorPos(x, y)
        if math.random() < 0.5 then
          term.write('1')
        else
          term.write('0')
        end
      end
    end
  end
end

function Replicator:drawStartingScreen()
  local w, h = term.getSize()
  local status = {}
  local materials = Materials.resolve(startingMaterials)
  for name,count in pairs(materials.data) do
    local have = self:count(name)
    if count > have then
      table.insert(status, '  ' .. Item.fromString(name):displayName())
      table.insert(status, '                ' .. count - have)
    end
  end

  term.clear()
  term.setCursorPos(w, h)
  textutils.tabulate(status)

  term.setCursorPos(3, 2)
  term.write('INSERT MATERIALS')
end

function Replicator:findBaseSpot()
  local foundBase = false
  local walk = RandomWalk:new()

  self:move('z', -3)

  while not foundBase do
    local pos = walk:next()
    if pos == false then
      walk = RandomWalk:new(walk.position)
      pos = walk:next()
    end

    local x = pos.x * self.config.base_spacing
    local y = pos.y * self.config.base_spacing

    self:move('x', x - 1)
    self:move('y', y)
    self:move('z', -2)

    if not self:detect('cobblestone', 'up') then
      foundBase = true
      self:move('x', x)
      self:move('z', -1)
    else
      self:move('z', -3)
    end
  end
end

function Replicator:buildBase()
  self:exec [[
    N !cobblestone P L P L L U N F F D PD P E P W P U F F D PD F PD L F PD
    L F PD P R P U F R F PD F R F !dirt PD F PD !cobblestone F R PD F PD F PD F
    PD R F R F !water_bucket PD L F R F PD F U R !reeds PD F PD F D
    !cobblestone F PD F PD F R F PD F PD F PD F R F PD F PD R F PD F PD F PD R
    !dirt F PD R F PD F PD R R U !sapling PD F PD F PD L F F D L F F F R F F F N
  ]]
  self.position = copy(startingPosition)
  self:writePosition()
  self:exec [[ Y2 ]]
  self:craft(Recipes.planks, 7, false)
  self:craft(Recipes.chest, 3, false)
  self:exec [[ Y2 !chest PD Y0 X1 PU PD X0 ]]
  self:craft(Recipes.furnace, 1)
  self:exec [[ W !furnace U P D N ]]
  if self:count('coal') == 0 then
    self:smelt('log', 'planks')
  end
  self:exec [[ Y2 ]]
  self:craft(Recipes.stick, 1, false)
  self:craft(Recipes.torch, 1, false)
  self:exec [[ Y6 Z1 X-1 !torch PD F PD F PD F F Y0 E F F PD F D X0 ]]
  self.state.have_base = true
  self:writeState()
end

function Replicator:logRefuel()
  local minLogs = 10
  local numLogs = self.storage:count('log')
  if turtle.getFuelLevel() < 80 then
    minLogs = 3
  end
  if numLogs >= minLogs then
    numLogs = math.min(numLogs, 10)
    self:retrieve('log', numLogs)
    self:smelt('log', 'log')
    if numLogs - 2 > 1 then
      self:smelt({'log', numLogs - 2}, 'coal')
    end
    self:refuel()
  end
end

function Replicator:mine(shafts)
  if not shafts then shafts = 1 end

  function spinmine()
    for i=1,4 do
      local block = self:inspect()
      if block then
        if miningMaterials:count(block) > 0 or
          (self:count('cobblestone') < 124 and block.name == 'minecraft:stone') or
          (self:count('dirt') < 32 and block.name == 'minecraft:dirt') then
          turtle.dig()
        end
      end
      if i ~= 4 then
        self:turn('left')
      end
    end
    if self.position.z % 8 == 0 then
      self:inventoryCleaning()
      self:compactInventory()
    end
  end

  local moveHeight = -math.random(5, 10)
  local area = math.floor(self.config.mining_area / 5)
  local tries = 0

  self:move('z', moveHeight)
  self:move('x', math.random(-area, area) * 5)
  self:move('y', math.random(-area, area) * 5)

  for _ = 1,shafts do
    local foundSpot = false
    repeat
      while not self:detect(nil, 'down') or self:detectAny(unwantedMaterials, 'down') do
        self:simpleMove('down')
      end
      if self:detect('cobblestone', 'down') then
        tries = tries + 1
        if tries > 20 then
          self.state.mining_fails = self.state.mining_fails + 1
          self:writeState()
          return
        end
        self:simpleMove('up', 2)
        if math.random() < 0.5 then
          if math.random() < 0.5 then
            self:turn('left')
          else
            self:turn('right')
          end
        end
        self:exec [[ F F L F R ]]
      else
        foundSpot = true
      end
    until foundSpot

    self:simpleMove('down')
    for i = 1,4 do
      turtle.dig()
      self:place('cobblestone')
      self:turn('left')
    end
    self:simpleMove('down')
    self:place('cobblestone', 'up')

    local startZ = self.position.z
    local atBottom = false
    while not atBottom do
      local below = self:inspect('down')
      if isTurtle(below) then
        return
      end
      if below and below.name == 'minecraft:bedrock' then
        atBottom = true
      else
        self:simpleMove('down')
        spinmine()
      end
    end

    self:exec [[ !cobblestone U PD U PD U PD U PD U PD ]]

    foundSpot = false
    repeat
      if math.random() < 0.5 then
        if math.random() < 0.5 then
          self:turn('left')
        else
          self:turn('right')
        end
      end
      self:exec [[ F F L F R ]]
      while not self:detectAny({'cobblestone', 'bedrock'}, 'down') do
        self:simpleMove('down')
      end
      if not self:detect('cobblestone', 'down') then
        foundSpot = true
      else
        tries = tries + 1
        if tries > 20 then
          self.state.mining_fails = self.state.mining_fails + 1
          self:writeState()
          return
        end
      end
    until foundSpot

    while not self:detect('bedrock', 'down') do
      self:simpleMove('down')
    end

    local numCobble = 0
    while self.position.z < startZ do
      spinmine()
      self:simpleMove('up')
      if numCobble < 6 then
        self:exec [[ !cobblestone PD ]]
        numCobble = numCobble + 1
      end
    end

    self:simpleMove('up')
    for i = 1,4 do
      turtle.dig()
      self:place('cobblestone')
      self:turn('left')
    end
    self:simpleMove('up')
    self:place('cobblestone', 'down')
  end

  self:move('z', moveHeight)
  self:exec [[ X0 Y0 Z0 ]]
end

function Replicator:findSand()
  self:move('z', -5)
  self:move('x', math.random(-10, 10))
  self:move('y', math.random(-10, 10))
  while not self:inspect('down') do
    self:simpleMove('down')
  end

  local pos = {x=0, y=0}
  local gridSize = 10
  local visited = {}
  local foundSand = false
  local numSteps = 0
  local numTries = 0

  visited[pos.x .. pos.y] = true

  while not foundSand and numSteps < 200 and numTries < 20 do
    local axis = 'x'
    if math.random() > 0.5 then axis = 'y' end
    local dir = 1
    if math.random() > 0.5 then dir = -1 end
    local nextPos = {x=pos.x, y=pos.y}
    nextPos[axis] = nextPos[axis] + dir
    if not visited[nextPos.x .. nextPos.y] then
      numTries = 0
      pos = nextPos
      visited[pos.x .. pos.y] = true
      for _ = 1,gridSize do
        local stepsDown = 0
        local onGround = false
        while not onGround do
          local below = self:inspect('down')
          if below and below.name == 'minecraft:sand' then
            foundSand = true
          end
          if (not below or unwantedMaterials:count(below) > 0) and stepsDown < 6 then
            self:simpleMove('down')
            numSteps = numSteps + 1
            stepsDown = stepsDown + 1
          else
            onGround = true
          end
        end
        if foundSand then break end
        local inFront = self:inspect()
        while inFront and unwantedMaterials:count(inFront) == 0 do
          self:simpleMove('up')
          numSteps = numSteps + 1
          inFront = self:inspect()
        end
        self:move(axis, self.position[axis] + 1)
        numSteps = numSteps + 1
      end
    else
      numTries = numTries + 1
    end
  end

  local numBacktracks = 0
  while foundSand do
    while self:detect('sand', 'down') do
      self:simpleMove('down')
    end
    while self:detect('sand') do
      numBacktracks = 0
      turtle.dig() sleep(0.5)
      if self:count('sand') >= 64 then
        foundSand = false
        break
      end
    end
    self:simpleMove()
    local turns = 0
    while not self:detect('sand') do
      self:turn('right')
      turns = turns + 1
      if turns > 2 then
        if numBacktracks < 2 then
          self:turn('left')
          self:simpleMove()
          numBacktracks = numBacktracks + 1
        else
          foundSand = false
        end
        break
      end
    end
  end

  self:exec [[ Z-7 X0 Y0 Z0 ]]
end

function Replicator:lumberjack()
  local saplingCount = self.storage:count('sapling')
  if saplingCount > 0 then
    self:retrieve('sapling', math.min(3, saplingCount))
  end
  self:exec [[ Y4 ]]
  for pos=1,3 do
    self:move('x', -pos)
    self:turn(cardinal.north)
    if self:detect('log') then
      local leafStart, above
      local height = 0
      repeat
        above = self:detect(nil, 'up')
        height = height + 1
        self:simpleMove('up')
        if leafStart == nil and above then
          leafStart = math.max(height, 2)
        end
      until not above and not self:detect()
      if not leafStart then leafStart = height end
      self:exec [[ F ]]
      while self.position.z > leafStart do
        self:exec [[ F D Q R F Q R F F F Q R F F Q R F F Q R F L ]]
      end
      while self.position.z > 2 do
        self:simpleMove('down')
      end
      self:exec [[ D QD !sapling PD S F D ]]
    elseif not self:detect('sapling') then
      self:exec [[ !sapling P ]]
    end
  end
  self:exec [[ X0 Y0 ]]
  if self.storage:count('sapling') > 60 then
    self:drop('sapling', nil, 'down')
  end
  self.lastLumberTrip = os.clock()
end

function Replicator:reedsjack()
  self:exec [[ Z2 Y1 X-3 W Q D Q Y2 Z2 W Q D Q Z0 X0 Y0 ]]
  self.lastReedsTrip = os.clock()
end

function Replicator:buildDiskDrive()
  self:smelt({'cobblestone', 7}, {'coal', 1})
  self:exec [[ Y2 ]]
  self:craft(Recipes.diskDrive, 1, false)
  self:exec [[ Y2 E !ComputerCraft:Peripheral P Y0 ]] -- tries to place disk drive after going up 2 blocks then returns to y 0
  self.state.have_disk_drive = true
  self:writeState()
end

function Replicator:buildFloppy()
  self:move('y', 2)
  self:craft(Recipes.paper, 1, false)
  self:craft(Recipes.floppyDisk, 1, false)
  self:exec [[ Y2 E ]]
  self:drop('ComputerCraft:disk_expanded', 1) -- drops floppy into disk drive
  self:setupFloppy('front')
  self.state.have_floppy = true
  self:writeState()
  self:move(startingPosition)
end

function Replicator:setupFloppy(direction)
  local deps = {
    'lib/class.lua',
    'lib/items.lua',
    'lib/serpent.lua',
    'lib/utils.lua',
  }

  -- Sometimes the disk drive won't show up
  local diskTries = 0
  local diskPath = nil
  while diskPath == nil do
    if diskTries > 20 then
      error('Unable to access disk drive.')
    end
    diskPath = disk.getMountPath(direction) -- tries to mount floppy
    if diskTries > 10 then
      self:simpleMove('up')
      sleep(1)
      self:simpleMove('down')
      sleep(10)
    end
    sleep(2)
    diskTries = diskTries + 1
  end

  disk.setLabel(direction, 'rEpliCatoR v.' .. self.state.num_babies)

  fs.makeDir(diskPath .. '/lib')
  fs.makeDir(diskPath .. '/state')

  for _,dep in ipairs(deps) do
    local filename = diskPath .. '/' .. dep
    fs.delete(filename)
    fs.copy(dep, filename)
  end

  fs.delete(diskPath .. '/startup')
  fs.copy('bootstrap', diskPath .. '/startup')

  local startupSource
  if fs.exists('replicator') then
    startupSource = 'replicator'
  else
    startupSource = 'startup'
  end

  fs.delete(diskPath .. '/replicator')
  fs.copy(startupSource, diskPath .. '/replicator')

  local nameFile = fs.open(diskPath .. '/' .. self.config.name_file, 'w')
  local name = os.getComputerLabel()
  if name == nil then
    name = 'r'
  end

  nameFile.writeLine(name .. '-' .. self.state.num_babies)
  nameFile.close()
end

function Replicator:updateFloppy()
  self:exec [[ Y2 E ]]
  self:setupFloppy('front')
  self:move(startingPosition)
end

function Replicator:isInBase()
  return comparePosition(self.position, startingPosition)
end

function Replicator:haveEnoughFuel()
  return turtle.getFuelLevel() > self.config.max_fuel * self.config.refuel_treshhold
end

function Replicator:loop()
  self:drawBackground()
  self:compactInventory()

  if not self.state.have_base then
    while not self:haveMaterials(startingMaterials) do
      self:drawStartingScreen()
      sleep(0.5)
    end

    for _ = 1,20 do
      self:drawBackground()
      sleep(0.1)
    end

    self:select('crafting_table')
    turtle.equipLeft()

    self:select('diamond_pickaxe')
    turtle.equipRight()

    self:refuel()

    local haveParent = fs.exists(self.config.name_file)
    if haveParent then
      -- Figure out bearing since turtles are placed differently
      -- depending on the world orientation of the parent.
      while not self:detect('ComputerCraft:Peripheral') do
        self:turn('left')
      end

      self.position = {x=1, y=1, z=0, bearing=cardinal.north}
      self:writePosition()
      self:findBaseSpot()
    else
      self:simpleMove('up', self.config.base_height)
    end

    self:buildBase()
    return
  end

  if not self:isInBase() then
    -- Not at home position at loop start means we lost power
    if self.position.z < 0 then
      -- Below platform, should be ok just to plow our way home
      self:exec [[ Z-8 Y0 X0 Z0 ]]
    else
      -- In base probably, navigate more carefully
      while self.position.z < 8 do
        while self:inspect('up') do
          while self:inspect() do
            self:turn('left')
          end
          self:simpleMove()
        end
        self:simpleMove('up')
      end
      self:exec [[ X0 Y0 Z0 ]]
    end
    return
  end

  self:inventoryCleaning()
  self:compactInventory()

  if self.storage:count('log') < 120 or self.storage:count('sapling') < 16 then
    if os.clock() - self.lastLumberTrip > self.config.lumberjack_interval then
      self:lumberjack()
      return
    end
  end

  if not self:haveEnoughFuel() then
    if self:count('coal') > 16 then
      self:refuel()
    else
      self:logRefuel()
    end
  end

  if not self:haveEnoughFuel() then
    self:logRefuel()
    sleep(2)
    return
  end

  if self.storage:count('reeds') < 20 then
    if os.clock() - self.lastReedsTrip > self.config.reeds_interval then
      self:reedsjack()
      return
    end
  end

  if self.state.mining_fails > 5 and self:haveMaterials(relocatingMaterials) then
    local optionalMaterials = Materials.fromTable {
      'diamond', 'iron_ore', 'sand', 'redstone', 'diamond_pickaxe'
    }
    self:move(self.storage.position)
    local items = concat(relocatingMaterials:getItems(), optionalMaterials:getItems())
    for _,item in ipairs(items) do
      local count = self.storage:count(item)
      if count > 0 then
        self.storage:retrieve(item, math.min(count, 64))
      end
    end
    self:move(startingPosition)
    if self:count('cobblestone') > 64 then
      self:drop('cobblestone', self:count('cobblestone') - 64, 'down')
    end
    self.storage:reset()
    self.state.mining_fails = 0
    self.state.have_base = false
    self.state.have_baby = false
    self.state.have_floppy = false
    self.state.have_disk_drive = false
    self:writeState()
    self:exec [[ !dirt D PU D PU ]]
    self:findBaseSpot()
    self:buildBase()
    return
  end

  if self.storage:count('sand') < 6 and self.storage:count('glass_pane') == 0 then
    self:findSand()
    return
  end

  if not self.state.have_disk_drive then
    local driveMaterials = {{'cobblestone', 7}, {'redstone', 2}, {'coal', 1}}
    if self:haveMaterials(driveMaterials) then
      self:prepareMaterials(driveMaterials)
      self:buildDiskDrive()
    else
      self:mine(1)
    end
    return
  end

  if not self.state.have_floppy then
    local floppyMaterials = {{'redstone', 1}, {'reeds', 3}}
    if self:haveMaterials(floppyMaterials) then
      self:prepareMaterials(floppyMaterials)
      self:buildFloppy()
    else
      self:mine(1)
    end
    return
  end

  if self:haveMaterials{{'iron_ore', 8}, 'coal'} and self.storage:count('iron_ingot') < 16 then
    self:prepareMaterials{{'iron_ore', 8}, 'coal'}
    self:smelt({'iron_ore', 8}, 'coal')
    self:store('iron_ingot', 8)
    return
  end

  if self:haveMaterials{{'sand', 6}, {'coal', 1}} and self.storage:count('glass_pane') < 1 then
    self:prepareMaterials{{'sand', 6}, {'coal', 1}}
    self:smelt({'sand', 6}, {'coal', 1})
    self:craft(Recipes.glassPane, 1)
    return
  end

  local computerMaterials = {{'cobblestone', 7}, 'redstone', 'glass_pane', 'coal'}
  if self:haveMaterials(computerMaterials) and self.storage:count('ComputerCraft:Computer') < 1 then
    self:prepareMaterials(computerMaterials)
    self:smelt({'cobblestone', 7}, 'coal')
    self:craft(Recipes.computer)
    self:store('ComputerCraft:Computer')
    return
  end

  if self.state.have_baby == false then
    local turtleMaterials = {'ComputerCraft:Computer', {'log', 2}, {'iron_ingot', 7}}
    if self:haveMaterials(turtleMaterials) then
      self:prepareMaterials(turtleMaterials)
      self:move('y', 2)
      self:craft(Recipes.planks, 2, false)
      self:craft(Recipes.chest, 1, false)
      self:craft(Recipes.turtle, 1, false)
      self:exec [[ Y1 E !ComputerCraft:Turtle P ]]
      self:move(startingPosition)
      self.state.have_baby = true
      self.state.num_babies = self.state.num_babies + 1
      self:writeState()
      return
    end
  end

  if self:haveMaterials{{'bucket', 2}} and self.storage:count('water_bucket') < 2 then
    self:prepareMaterials{{'bucket', 2}}
    self:exec [[ Y1 X-2 !bucket PD X-3 PD X0 Y0 ]]
    return
  end

  if self.state.have_baby == true then
    if self:haveMaterials{{'iron_ingot', 6}} and self.storage:count('bucket') < 2 then
      self:prepareMaterials{{'iron_ingot', 6}}
      self:craft(Recipes.bucket, 2)
      return
    end
    if self:haveMaterials{'log', {'diamond', 3}} and self.storage:count('diamond_pickaxe') < 1 then
      self:prepareMaterials{'log', {'diamond', 3}}
      self:move('y', 2)
      self:craft(Recipes.planks, 1, false)
      self:craft(Recipes.stick, 2, false)
      self:craft(Recipes.diamondPick, 1, false)
      self:move('y', 0)
      return
    end
    if self:haveMaterials{'log'} and self.storage:count('crafting_table') < 1 then
      self:prepareMaterials{'log'}
      self:move('y', 2)
      self:craft(Recipes.planks, 1, false)
      self:craft(Recipes.craftingTable, 1, false)
      self:move('y', 0)
      return
    end
    if self:haveMaterials(startingMaterials) then
      self:updateFloppy()
      self:prepareMaterials(startingMaterials)
      self:exec [[ Y1 E ]]
      for _,item in ipairs(startingMaterials:getItems()) do
        self:drop(item, item.count)
      end
      -- give extra starting materials if possible
      local extraMaterials = Materials:new({})
      local checkMaterials = Materials.fromTable {
        {'sand', 12}, {'log', 32}, {'diamond', 6}, {'iron_ore', 16},
        {'redstone', 16}, {'reeds', 6}, {'coal', 32}, {'sapling', 16},
      }

      for _,item in ipairs(checkMaterials:getItems()) do
        local inStorage = self.storage:count(item)
        local maxGive = 64
        if inStorage > item.count then
          maxGive = 64 - startingMaterials:count(item)
          extraMaterials:addItem(item, math.min(maxGive, math.floor(inStorage / 2)))
        end
      end

      if extraMaterials:numMaterials() > 0 then
        self:exec [[ Y0 ]]
        self:prepareMaterials(extraMaterials)
        self:exec [[ Y1 E ]]
        for _,item in ipairs(extraMaterials:getItems()) do
          self:drop(item, item.count)
        end
      end

      peripheral.call('front', 'turnOn')
      self.state.have_baby = false
      self:writeState()
      self:move(startingPosition)
      return
    end
  end

  self:mine(math.random(1, 2))
end

function Replicator:run()
  self.running = true
  while self.running do
    local status, err = pcall(self.loop, self)
    if not status then
      local h = fs.open(self.config.error_log, 'a')
      h.writeLine(err)
      h.close()

      term.clear()
      term.setCursorPos(3, 2)
      term.write('ERROR')
      term.setCursorPos(3, 5)
      term.write(err)
      term.setCursorPos(1, 7)

      self:stop()

      if turtle.getFuelLevel() == 0 then
        os.shutdown()
      else
        sleep(600)
        os.reboot()
      end
    end
  end
end

function Replicator:stop()
  self.running = false
end

term.setBackgroundColor(colors.white)
term.setTextColor(colors.black)
term.setCursorBlink(false)
term.clear()

replicator = Replicator:new()
replicator:run()
