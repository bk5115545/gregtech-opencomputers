-- Text-based, memory-safe AE2 autostocker for OpenComputers
local component = require("component")
local term = require("term")
local gpu = component.gpu
local batchSizes = {}
local serialization = require("serialization")
local event = require("event")
local thread = require("thread")
local keyboard = require("keyboard")

local me = component.me_controller
local craftablesList = {}
local stockingLevels = {}
local currentlyCrafting = {}
local craftableLookup = {}

local PAGE_SIZE = 20
local CRAFTABLE_LIMIT = 9999 -- Set higher for real use, lower for debug

local STATUS_LIMIT = 10
local lastInputTime = os.clock()

local stockCache = {}
local STOCK_CACHE_TTL = 15 -- seconds

local fluidsCache = {data = nil, time = 0}
local FLUIDS_CACHE_TTL = 3 -- seconds

local debugEnabled = false

local colors = {
  white = 0xFFFFFF,
  red = 0xFF0000,
  green = 0x00FF00,
  yellow = 0xFFFF00,
  cyan = 0x00FFFF
}

component.gpu.setResolution(160, 50)

local function save()
  local file1 = io.open("/home/stockingLevels", "w")
  file1:write(serialization.serialize(stockingLevels))
  file1:close()
  local file2 = io.open("/home/batchSizes", "w")
  file2:write(serialization.serialize(batchSizes))
  file2:close()
end

local function load()
  local file1 = io.open("/home/stockingLevels", "r")
  if file1 then
    stockingLevels = serialization.unserialize(file1:read("*a")) or {}
    file1:close()
  end
  local file2 = io.open("/home/batchSizes", "r")
  if file2 then
    batchSizes = serialization.unserialize(file2:read("*a")) or {}
    file2:close()
  end
end


local function buildCraftableLookup()
  craftableLookup = {}
  for _, c in ipairs(craftablesList) do
    local key = c.label .. "|" .. tostring(c.damage)
    craftableLookup[key] = c
  end
end

local function getAllCraftables()
  craftablesList = {}
  local all = me.getCraftables()
  print("Loading craftables (max "..CRAFTABLE_LIMIT.." of "..#all..")...")
  for i, c in ipairs(all) do
    if i > CRAFTABLE_LIMIT then break end
    local stack = c.getItemStack()
    local fluidName = nil
    if stack and stack.fluidDrop and stack.fluidDrop.name then
      fluidName = stack.fluidDrop.name
    end
    craftablesList[#craftablesList+1] = {
      label = stack.label,
      name = stack.name or stack.unlocalizedName,
      damage = stack.damage,
      request = c.request,
      fluidName = fluidName
    }
    if i % 50 == 0 then print("  Loaded "..i.."/") end
  end
  print("Done loading craftables.")
  buildCraftableLookup()
end

local function searchCraftables(query, onlyTargets)
  query = query:lower()
  local results = {}
  for _, c in ipairs(craftablesList) do
    local key = c.label .. "|" .. tostring(c.damage)
    if (not onlyTargets or (stockingLevels[key] and stockingLevels[key] > 0))
      and c.label:lower():find(query, 1, true) then
      results[#results+1] = c
    end
  end
  return results
end

local function getStock(unlocalizedName, damage)
  local item = me.getItemInNetwork(unlocalizedName, damage)
  if item and item.size then
    return item.size
  end
  -- Try fluids with cache
  local now = os.clock()
  if not fluidsCache.data or (now - fluidsCache.time > FLUIDS_CACHE_TTL) then
    fluidsCache.data = me.getFluidsInNetwork()
    fluidsCache.time = now
  end
  local fluids = fluidsCache.data
  if fluids then
    for _, f in ipairs(fluids) do
      if f.name == unlocalizedName then
        return f.amount or 0
      end
    end
  end
  return 0
end

local function getStockCached(unlocalizedName, damage)
  local cacheKey = unlocalizedName .. "|" .. tostring(damage)
  local now = os.clock()
  local entry = stockCache[cacheKey]
  if entry and (now - entry.time < STOCK_CACHE_TTL) then
    return entry.value
  else
    local value = getStock(unlocalizedName, damage)
    stockCache[cacheKey] = {value = value, time = now}
    return value
  end
end

local function getCraftableStock(c)
  local stock = getStock(c.name, c.damage)
  if stock > 0 then
    return stock
  end
  if c.fluidName then
    return getStock(c.fluidName, 0)
  end
  return 0
end

local function debugPrint(...)
  if debugEnabled then
    print("[DEBUG]", ...)
  end
end

local function printCraftingTracker()
  local trackerList = {}
  for key, v in pairs(currentlyCrafting) do
    local label, damage = key:match("^(.-)|(.+)$")
    local elapsed = os.clock() - (v.startTime or 0)
    trackerList[#trackerList+1] = {
      key = key,
      label = label,
      damage = damage,
      amount = v.amount,
      elapsed = elapsed
    }
  end
  table.sort(trackerList, function(a, b) return a.elapsed > b.elapsed end)
  print("Active Crafts (oldest first):")
  print("----------------------------------------------")
  for i = 1, STATUS_LIMIT do
    local t = trackerList[i]
    if t then
      print(string.format("%s [%s] x%d | %.1fs", t.label, t.damage, t.amount, t.elapsed))
    else
      print("")
    end
  end
end

local craftCooldowns = {}
local craftFailures = {}

local function requestManagerThread()
  while true do
    local now = os.clock()
    for key, target in pairs(stockingLevels) do
      if target and target > 0 then
        local craftable = craftableLookup[key]
        if not craftable then
          debugPrint("No craftable found for key:", key)
        else
          local stock = getCraftableStock(craftable)
          local crafting = currentlyCrafting[key] and currentlyCrafting[key].amount or 0
          debugPrint("Found craftable for key:", key, "Stock:", stock, "Target:", target)
          local toRequest = target - (stock + crafting)
          if toRequest > 0 and not currentlyCrafting[key] then
            -- Check cooldown
            local cooldown = craftCooldowns[key] or 0
            if now < cooldown then
              debugPrint("Cooldown active for", key, "until", cooldown)
            else
              local batch = batchSizes[key]
              local reqAmount = batch and batch > 0 and math.min(batch, toRequest) or toRequest
              local ok, req = pcall(craftable.request, reqAmount)
              debugPrint("Request result:", ok, req)
              if ok and req then
                currentlyCrafting[key] = {tracker = req, amount = reqAmount, startTime = os.clock()}
                craftFailures[key] = 0
                -- Gradually reduce cooldown
                if craftCooldowns[key] then
                  local remaining = craftCooldowns[key] - now
                  if remaining > 10 then
                    craftCooldowns[key] = now + math.max(10, remaining / 2)
                  else
                    craftCooldowns[key] = nil
                  end
                end
                debugPrint("Craft started for:", key)
              elseif not ok then
                -- Failure: set cooldown
                local fails = (craftFailures[key] or 0) + 1
                craftFailures[key] = fails
                local delay = math.min(10 * fails, 60)
                craftCooldowns[key] = now + delay
                debugPrint("Request error for:", key, req, "Cooldown:", delay, "s")
              end
            end
          end
        end
      end
    end
    for key, v in pairs(currentlyCrafting) do
      if v.tracker.isCanceled() or v.tracker.isDone() then
        currentlyCrafting[key] = nil
        -- Invalidate stock cache for this item
        local craftable = craftableLookup[key]
        if craftable then
          local cacheKey = craftable.name .. "|" .. tostring(craftable.damage)
          stockCache[cacheKey] = nil
        end
        debugPrint("Craft finished/canceled for:", key)
      end
    end
    os.sleep(10) -- Slow down craft progress checks
  end
end

local uiBuffer = nil
local bufferWidth, bufferHeight = gpu.getResolution()

local function renderUI(search, page, results, startIdx, endIdx, termHeight)
  -- Allocate buffer if needed
  local w, h = gpu.getResolution()
  if not uiBuffer or bufferWidth ~= w or bufferHeight ~= h then
    if uiBuffer then pcall(gpu.freeBuffer, uiBuffer) end
    uiBuffer = gpu.allocateBuffer(w, h)
    bufferWidth, bufferHeight = w, h
  end
  gpu.setActiveBuffer(uiBuffer)
  gpu.fill(1, 1, w, h, " ")
  local y = 1
  gpu.setForeground(colors.cyan)
  gpu.set(1, y, "AE2 Autostocker - Search: " .. search .. " | Page "..page)
  y = y + 1
  gpu.setForeground(colors.white)
  gpu.set(1, y, "Type to search, :n/:p for next/prev page, :q to quit, :r to reload craftables, :s to save levels, :d to toggle debug.")
  y = y + 1
  gpu.set(1, y, "Select a craftable by number to set stock level.")
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
  y = y + 1
  local visibleResults = {}
  for i = startIdx, endIdx do
    local c = results[i]
    if c then
      visibleResults[#visibleResults+1] = c
      local key = c.label .. "|" .. tostring(c.damage)
      local stock = getCraftableStock(c)
      local target = stockingLevels[key] or 0
      local crafting = currentlyCrafting[key] and currentlyCrafting[key].amount or 0
      local line = string.format("%2d. %-32s ", i, c.label)
      local x = 1
      gpu.setForeground(colors.cyan)
      gpu.set(x, y, string.format("%2d.", i))
      x = x + 3
      gpu.setForeground(colors.white)
      gpu.set(x, y, string.format("%-32s ", c.label))
      x = x + 33
      -- Stock color
      if stock >= target and target > 0 then
        gpu.setForeground(colors.green)
      elseif target > 0 then
        gpu.setForeground(colors.red)
      else
        gpu.setForeground(colors.white)
      end
      gpu.set(x, y, string.format("[Stock: %d", stock))
      x = x + #("[Stock: "..stock)
      gpu.setForeground(colors.white)
      gpu.set(x, y, " | Target: "..target)
      x = x + #(" | Target: "..target)
      if crafting > 0 then
        gpu.setForeground(colors.yellow)
        gpu.set(x, y, " | Crafting: "..crafting)
        x = x + #(" | Crafting: "..crafting)
        gpu.setForeground(colors.white)
      else
        gpu.set(x, y, " | Crafting: 0")
        x = x + #(" | Crafting: 0")
      end
      gpu.set(x, y, "]")
      gpu.setForeground(colors.white)
      y = y + 1
    end
  end
  gpu.set(1, y, string.format("-- Page %d/%d --", page, math.max(1, math.ceil(#results / PAGE_SIZE))))
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
  y = y + 1
  -- Print tracker below
  local trackerY = y
  local trackerList = {}
  for key, v in pairs(currentlyCrafting) do
    local label, damage = key:match("^(.-)|(.+)$")
    local elapsed = os.clock() - (v.startTime or 0)
    trackerList[#trackerList+1] = {
      key = key,
      label = label,
      damage = damage,
      amount = v.amount,
      elapsed = elapsed
    }
  end
  table.sort(trackerList, function(a, b) return a.elapsed > b.elapsed end)
  gpu.set(1, y, "Active Crafts (oldest first):")
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
  y = y + 1
  for i = 1, STATUS_LIMIT do
    local t = trackerList[i]
    if t then
      gpu.set(1, y, string.format("%s [%s] x%d | %.1fs", t.label, t.damage, t.amount, t.elapsed))
    else
      gpu.set(1, y, "")
    end
    y = y + 1
  end
  gpu.setActiveBuffer(0)
  gpu.bitblt(0, 1, 1, w, h, uiBuffer, 1, 1)
  -- Move input line to bottom
  term.setCursor(1, termHeight)
  term.clearLine()
end

local function getInputWithTimeout(termHeight, timeout)
  term.setCursor(1, termHeight)
  term.clearLine()
  io.write("> ")

  local buffer = ""
  local started = os.clock()

  while true do
    local remaining = timeout - (os.clock() - started)
    if remaining <= 0 then
      return nil
    end

    local ev = {event.pull(remaining, "key_down")}
    if #ev == 0 then
      return nil
    end

    local _, _, char, code = table.unpack(ev)
    if code == keyboard.keys.enter then
      term.clearLine()
      return buffer
    elseif code == keyboard.keys.back then
      if #buffer > 0 then
        buffer = buffer:sub(1, -2)
        term.clearLine()
        io.write("> " .. buffer)
      end
    elseif char and char >= 32 and char <= 126 then
      local ch = string.char(char)
      buffer = buffer .. ch
      io.write(ch)
    end
  end
end

local function main()
  load()
  getAllCraftables()
  thread.create(requestManagerThread)

  local search = ""
  local page = 1
  local _, termHeight = term.getViewport()
  local onlyTargets = false

  while true do
    local results = searchCraftables(search, onlyTargets)
    local totalPages = math.max(1, math.ceil(#results / PAGE_SIZE))
    if page > totalPages then page = totalPages end
    if page < 1 then page = 1 end
    local startIdx = (page - 1) * PAGE_SIZE + 1
    local endIdx = math.min(page * PAGE_SIZE, #results)
    if not startIdx or not endIdx or startIdx > endIdx then startIdx, endIdx = 1, 0 end

    renderUI(search, page, results, startIdx, endIdx, termHeight)
    local input = getInputWithTimeout(termHeight, 1)

    if input == nil or input == "" then
      -- No input; refresh UI and continue
    elseif input == ":q" then
      break
    elseif input == ":r" then
      getAllCraftables()
    elseif input == ":s" then
      save()
    elseif input == ":n" then
      page = page + 1
    elseif input == ":p" then
      page = page - 1
    elseif input == ":d" then
      debugEnabled = not debugEnabled
      print("Debug logging is now", debugEnabled and "enabled" or "disabled")
    elseif input:match("^:t ") then
      onlyTargets = true
      search = input:sub(4)
      page = 1
    elseif tonumber(input) and results[tonumber(input)] then
      local c = results[tonumber(input)]
      local key = c.label .. "|" .. tostring(c.damage)
      renderUI(search, page, results, startIdx, endIdx, termHeight)
      term.setCursor(1, termHeight)
      term.clearLine()
      io.write("Set target stock for " .. c.label .. " (current: " .. (stockingLevels[key] or 0) .. ") [amount [batch]]: ")
      local entry = io.read()
      local amount, batch = entry:match("^(%d+)%s*(%d*)$")
      amount = tonumber(amount)
      batch = tonumber(batch)
      if amount then
        stockingLevels[key] = amount
        if batch and batch > 0 then
          batchSizes[key] = batch
        else
          batchSizes[key] = nil
        end
      end
    else
      onlyTargets = false
      search = input or ""
      page = 1
    end
  end

  if uiBuffer then pcall(gpu.freeBuffer, uiBuffer) end
  save()
end

main()