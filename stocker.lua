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

local PAGE_SIZE = 25
local CRAFTABLE_LIMIT = 9999 -- Set higher for real use, lower for debug

local STATUS_LIMIT = 10
local lastInputTime = os.clock()

local stockCache = {}
local STOCK_CACHE_TTL = 60

local fluidsCache = {data = nil, time = 0}
local FLUIDS_CACHE_TTL = 60

local debugEnabled = true

local colors = {
  white = 0xFFFFFF,
  red = 0xFF0000,
  green = 0x00FF00,
  yellow = 0xFFFF00,
  cyan = 0x00FFFF
}

bufferDirtyFlags = {
  header = true,
  craftable = true,
  craftingStatus = true,
  debug = true,
  input = true
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
  craftableLookup = {}
  local all = me.getCraftables()
  print("Loading craftables (Found ".. #all .." of "..CRAFTABLE_LIMIT..")...")
  for i, c in ipairs(all) do
    if i > CRAFTABLE_LIMIT then break end
    local stack = c.getItemStack()
    if stack then
      local fluidName = nil
      if stack.fluidDrop and stack.fluidDrop.name then
        fluidName = stack.fluidDrop.name
      end
      local key = stack.label .. "|" .. tostring(stack.damage)
      local craftable = {
        label = stack.label,
        name = stack.name,
        damage = stack.damage,
        fluidName = fluidName,
        request = c.request
      }
      craftablesList[#craftablesList+1] = craftable
      craftableLookup[key] = craftable
    end
    if i % 50 == 0 then print("  Loaded "..i) end
  end
  -- Sort craftablesList by label for efficient search
  table.sort(craftablesList, function(a, b) return a.label < b.label end)
  print("Done loading craftables.")
  bufferDirtyFlags.craftable = true
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
  bufferDirtyFlags.craftable = true
  return results
end

local debugLogs = {}

local function addDebugLog(message, logType)
  if not debugEnabled then 
    debugLogs = {}
    return
  end

  local color = colors.white -- Default color
  if logType == "success" or logType == nil then
    color = colors.green
  elseif logType == "failure" then
    color = colors.red
  elseif logType == "cooldown" then
    color = colors.yellow
  end

  table.insert(debugLogs, {message = message, color = color})
  if #debugLogs > 100 then -- Limit the log size to the last 100 entries
    table.remove(debugLogs, 1)
  end
  bufferDirtyFlags.debug = true
end

local function getStock(unlocalizedName, damage)
  local item = me.getItemInNetwork(unlocalizedName, damage)
  if item and item.size then
    addDebugLog("Lookup stock for item: " .. unlocalizedName .. ", found: " .. item.size)
    return item.size
  end
  -- Try fluids with cache
  local now = os.clock()
  if not fluidsCache.data or (now - fluidsCache.time > FLUIDS_CACHE_TTL) then
    fluidsCache.data = me.getFluidsInNetwork()
    fluidsCache.time = now
    addDebugLog("Updated fluids cache")
  end
  local fluids = fluidsCache.data
  if fluids then
    for _, f in ipairs(fluids) do
      if f.name == unlocalizedName then
        addDebugLog("Lookup fluid stock for: " .. unlocalizedName .. ", found: " .. (f.amount or 0))
        return f.amount or 0
      end
    end
  end
  addDebugLog("Lookup stock for item: " .. unlocalizedName .. " not found")
  return 0
end

local function getStockCached(unlocalizedName, damage)
  local cacheKey = unlocalizedName .. "|" .. tostring(damage)
  local now = os.clock()
  local entry = stockCache[cacheKey]
  if entry and (now - entry.time < STOCK_CACHE_TTL + math.random(0, STOCK_CACHE_TTL)) then -- Add jitter to cache expiration
    return entry.value
  else
    local value = getStock(unlocalizedName, damage)
    stockCache[cacheKey] = {value = value, time = now}
    return value
  end
end

local function getCraftableStock(c)
  local stock = getStockCached(c.name, c.damage) -- Use cached stock lookup
  if stock > 0 then
    return stock
  end
  if c.fluidName then
    return getStockCached(c.fluidName, 0) -- Use cached stock lookup for fluids
  end
  return 0
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
          addDebugLog("No craftable found for key: " .. key)
        else
          local stock = getCraftableStock(craftable)
          local crafting = currentlyCrafting[key] and currentlyCrafting[key].amount or 0
          addDebugLog("Found pattern for key: " .. key .. ", Stock: " .. stock .. ", Target: " .. target)
          local toRequest = target - (stock + crafting)
          if toRequest > 0 and not currentlyCrafting[key] then
            -- Check cooldown
            local cooldown = craftCooldowns[key] or 0
            if now < cooldown then
              addDebugLog("Cooldown active for " .. key .. " until " .. cooldown, "cooldown")
            else
              addDebugLog("Dispatching craft for " .. key .. ", amount: " .. toRequest)
              -- Dispatch craft logic here
              local batch = batchSizes[key]
              local reqAmount = batch and batch > 0 and math.min(batch, toRequest) or toRequest
              local ok, req = pcall(craftable.request, reqAmount)
              addDebugLog("Request result: " .. tostring(ok) .. ", " .. tostring(req), ok and "success" or "failure")
              if ok and req then
                bufferDirtyFlags.craftingStatus = true
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
                addDebugLog("Craft started for: " .. tostring(key), "success")
              elseif not ok then
                -- Failure: set cooldown
                local fails = (craftFailures[key] or 0) + 1
                craftFailures[key] = fails
                local delay = math.min(10 * fails, 60)
                craftCooldowns[key] = now + delay
                addDebugLog("Request error for: " .. tostring(key) .. ", " .. tostring(req) .. ", Cooldown: " .. delay .. "s", "failure")
              end
            end
          end
        end
        os.sleep(0.025) -- Sleep for 25ms between processing each craftable
      end
    end
    for key, v in pairs(currentlyCrafting) do
      if v.tracker.isCanceled() or v.tracker.isDone() then
        bufferDirtyFlags.craftingStatus = true
        currentlyCrafting[key] = nil
        -- Invalidate stock cache for this item
        local craftable = craftableLookup[key]
        if craftable then
          local cacheKey = craftable.name .. "|" .. tostring(craftable.damage)
          stockCache[cacheKey] = nil
        end
        addDebugLog("Craft finished/canceled for: " .. key, "success")
      end
    end
    addDebugLog("Sleeping...")
    os.sleep(10) -- Slow down craft progress checks
  end
end

local headerBuffer, craftableBuffer, debugBuffer, inputBuffer
local headerWidth, headerHeight, craftableWidth, craftableHeight, debugWidth, debugHeight, inputWidth, inputHeight

local function initializeBuffers()
  local w, h = gpu.getResolution()

  -- Header/Instructions Buffer
  headerWidth, headerHeight = w, 3
  headerBuffer = gpu.allocateBuffer(headerWidth, headerHeight)

  -- Craftables Buffer (Left Half)
  craftableWidth, craftableHeight = math.floor(w / 2), 27
  craftableBuffer = gpu.allocateBuffer(craftableWidth, craftableHeight)

  -- Crafting Status Buffer (Right Half)
  craftingStatusWidth, craftingStatusHeight = math.ceil(w / 2), 27
  craftingStatusBuffer = gpu.allocateBuffer(craftingStatusWidth, craftingStatusHeight)

  -- Debug Info Buffer
  debugWidth, debugHeight = w, h - headerHeight - craftableHeight - 1
  debugBuffer = gpu.allocateBuffer(debugWidth, debugHeight)

  -- Input Bar Buffer
  inputWidth, inputHeight = w, 1
  inputBuffer = gpu.allocateBuffer(inputWidth, inputHeight)
end

-- Table to track dirty flags for buffers
local bufferDirtyFlags = {
  header = true,
  craftable = true,
  craftingStatus = true,
  debug = true,
  input = true
}

local function renderHeader(search, page)
  gpu.setActiveBuffer(headerBuffer)
  gpu.fill(1, 1, headerWidth, headerHeight, " ")

  local y = 1
  gpu.setForeground(colors.cyan)
  gpu.set(1, y, "AE2 Autostocker - Search: " .. search .. " | Page " .. page)
  y = y + 1
  gpu.setForeground(colors.white)
  gpu.set(1, y, "Type to search, :n/:p for next/prev page, :q to quit, :r to reload craftables, :s to save levels, :d to toggle debug, :a to show all targets.")
  y = y + 1
  gpu.set(1, y, "Select a craftable by number to set stock level.")
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
end

local function renderCraftableData(results, startIdx, endIdx, page)
  gpu.setActiveBuffer(craftableBuffer)
  gpu.fill(1, 1, craftableWidth, craftableHeight, " ")

  local y = 1
  for i = startIdx, endIdx do
    local c = results[i]
    if c then
      local key = c.label .. "|" .. tostring(c.damage)
      local stock = getCraftableStock(c)
      local target = stockingLevels[key] or 0
      local crafting = currentlyCrafting[key] and currentlyCrafting[key].amount or 0

      -- Print label with increased width
      gpu.setForeground(colors.white)
      local labelText = string.format("%2d. %-43s", i, c.label) -- Increased width to 43 characters
      labelText = labelText .. string.rep(" ", 45 - #labelText) -- Pad with spaces to clear leftover characters
      gpu.set(1, y, labelText)

      -- Print stock with suffix and short name (S)
      local stockText = string.format("[S: %s", formatNumberWithSuffix(stock))
      stockText = stockText .. string.rep(" ", 10 - #stockText) -- Pad with spaces
      if target == 0 then
        gpu.setForeground(colors.white)
      elseif stock >= target then
        gpu.setForeground(colors.green)
      else
        gpu.setForeground(colors.red)
      end
      gpu.set(34, y, stockText)

      -- Print target with suffix and short name (T)
      gpu.setForeground(target == 0 and colors.white or colors.yellow)
      local targetText = string.format(" | T: %s", formatNumberWithSuffix(target))
      targetText = targetText .. string.rep(" ", 12 - #targetText) -- Pad with spaces
      gpu.set(46, y, targetText)

      -- Print crafting with suffix and short name (C)
      gpu.setForeground(colors.cyan)
      local craftingText = string.format(" | C: %s]", formatNumberWithSuffix(crafting))
      craftingText = craftingText .. string.rep(" ", 20 - #craftingText) -- Pad with spaces
      gpu.set(58, y, craftingText)

      y = y + 1
    end
  end
  gpu.set(1, y, string.format("-- Page %d/%d --", page, math.max(1, math.ceil(#results / PAGE_SIZE))))
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
end

local function renderCraftingStatus()
  gpu.setActiveBuffer(craftingStatusBuffer)
  gpu.fill(1, 1, craftingStatusWidth, craftingStatusHeight, " ")

  local y = 1
  gpu.set(1, y, "Crafting Status:")
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
  y = y + 1

  addDebugLog("Number of items in currentlyCrafting: " .. tostring(#currentlyCrafting))

  for key, v in pairs(currentlyCrafting) do
    local label, damage = key:match("^(.-)|(.+)$")
    local elapsed = os.clock() - (v.startTime or 0)
    gpu.set(1, y, string.format("%s [%s] x%d | %.1fs", label, damage, v.amount, elapsed))
    y = y + 1
    if y > craftingStatusHeight then break end -- Prevent overflow
  end
end

local function renderDebugInfo(debugLogs)
  gpu.setActiveBuffer(debugBuffer)
  gpu.fill(1, 1, debugWidth, debugHeight, " ")

  local y = 1
  gpu.set(1, y, "[DEBUG LOGGING]")
  y = y + 1
  gpu.set(1, y, "----------------------------------------------")
  y = y + 1
  for i = math.max(1, #debugLogs - debugHeight + 2), #debugLogs do
    local log = debugLogs[i]
    if type(log) == "table" then
      gpu.setForeground(log.color or colors.white)
      gpu.set(1, y, log.message)
    else
      gpu.setForeground(colors.white)
      gpu.set(1, y, log)
    end
    y = y + 1
  end
end

local function renderInputBar(input)
  gpu.setActiveBuffer(inputBuffer)
  gpu.fill(1, 1, inputWidth, inputHeight, " ")
  gpu.set(1, 1, "> " .. input)
end

local function renderUI(search, page, results, startIdx, endIdx, termHeight, input, debugLogs)
  -- Initialize buffers if not already done
  if not headerBuffer or not craftableBuffer or not debugBuffer or not craftingStatusBuffer or not inputBuffer then
    initializeBuffers()
  end

  -- Render header
  if bufferDirtyFlags.header then
    renderHeader(search, page)
    gpu.bitblt(0, 1, 1, headerWidth, headerHeight, headerBuffer, 1, 1)
    bufferDirtyFlags.header = false
  end

  -- Render craftables (left half)
  if bufferDirtyFlags.craftable then
    renderCraftableData(results, startIdx, endIdx, page)
    gpu.bitblt(0, 1, 4, craftableWidth, craftableHeight, craftableBuffer, 1, 1)
    bufferDirtyFlags.craftable = false
  end

  -- Render crafting status (right half)
  if bufferDirtyFlags.craftingStatus then
    renderCraftingStatus()
    gpu.bitblt(0, craftableWidth + 1, headerHeight, craftingStatusWidth, craftingStatusHeight, craftingStatusBuffer, 1, 1)
    bufferDirtyFlags.craftingStatus = false
  end

  -- Render debug info
  if bufferDirtyFlags.debug then
    renderDebugInfo(debugLogs)
    gpu.bitblt(0, 1, craftableHeight + 4, debugWidth, debugHeight, debugBuffer, 1, 1)
    bufferDirtyFlags.debug = false
  end

  -- Render input bar
  if bufferDirtyFlags.input then
    renderInputBar(input or "")
    gpu.bitblt(0, 1, termHeight, inputWidth, inputHeight, inputBuffer, 1, 1)
    bufferDirtyFlags.input = false
  end

  gpu.setActiveBuffer(0)
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
    started = os.clock()

    local _, _, char, code = table.unpack(ev)
    if code == keyboard.keys.enter then
      term.clearLine()
      bufferDirtyFlags.input = true
      return buffer
    elseif code == keyboard.keys.back then
      if #buffer > 0 then
        buffer = buffer:sub(1, -2)
        term.clearLine()
        io.write("> " .. buffer)
        bufferDirtyFlags.input = true
      end
    elseif char and char >= 32 and char <= 126 then
      local ch = string.char(char)
      buffer = buffer .. ch
      io.write(ch)
      bufferDirtyFlags.input = true
    end
  end
end

local function main()
  load()
  getAllCraftables()
  local managerThread = thread.create(requestManagerThread)

  local search = ""
  local page = 1
  local _, termHeight = term.getViewport()
  local onlyTargets = false

  while true do
    local results

    if debugEnabled then
      bufferDirtyFlags.debug = true -- Force debug buffer to be dirty in debug mode
    end

    if onlyTargets then
      results = {}
      for key, target in pairs(stockingLevels) do
        if target and target > 0 then
          local craftable = craftableLookup[key]
          if craftable then
            results[#results+1] = craftable
          end
        end
      end
    else
      results = searchCraftables(search, onlyTargets)
    end

    local totalPages = math.max(1, math.ceil(#results / PAGE_SIZE))
    if page > totalPages then page = totalPages end
    if page < 1 then page = 1 end
    local startIdx = (page - 1) * PAGE_SIZE + 1
    local endIdx = math.min(page * PAGE_SIZE, #results)
    if not startIdx or not endIdx or startIdx > endIdx then startIdx, endIdx = 1, 0 end

    renderUI(search, page, results, startIdx, endIdx, termHeight, input, debugLogs)
    local input = getInputWithTimeout(termHeight, 1)

    if input == nil or input == "" then
      -- No input; refresh UI and continue
    elseif input == ":q" then
      break
    elseif input == ":r" then
      getAllCraftables()
      results = searchCraftables(search, onlyTargets) -- Update results after reloading craftables
      bufferDirtyFlags.craftable = true
    elseif input == ":s" then
      save()
    elseif input == ":n" then
      page = page + 1
      bufferDirtyFlags.craftable = true
    elseif input == ":p" then
      page = page - 1
      bufferDirtyFlags.craftable = true
    elseif input == ":d" then
      debugEnabled = not debugEnabled
      debugLogs = {}
    elseif input == ":a" then
      onlyTargets = not onlyTargets
      search = ""
      page = 1
      bufferDirtyFlags.craftable = true
    elseif input:match("^:t ") then
      onlyTargets = true
      search = input:sub(4)
      page = 1
      bufferDirtyFlags.craftable = true
    elseif tonumber(input) and results[tonumber(input)] then
      local c = results[tonumber(input)]
      local key = c.label .. "|" .. tostring(c.damage)
      renderUI(search, page, results, startIdx, endIdx, termHeight, debugLogs)
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
      bufferDirtyFlags.craftable = true -- Mark craftable buffer dirty when stock levels change
    else
      onlyTargets = false
      if search ~= input then
        bufferDirtyFlags.craftable = true -- Mark craftable buffer dirty when search changes
        search = input
      end
      search = input or ""
      page = 1
    end
  end

  if managerThread and managerThread:status() == "running" then
    managerThread:kill() -- Terminate the thread to prevent hanging
  end

  gpu.freeAllBuffers() -- Frees all buffers and resets the buffer index to 0
  save()
end

main()