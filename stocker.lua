-- stocker.lua
-- Applied Energistics Auto-Stocker for OpenComputers
-- Automatically maintains stock levels of items in ME system

local component = require("component")
local term = require("term")
local sides = require("sides")

-- Check if ME interface is available
if not component.isAvailable("me_interface") then
    print("Error: No ME Interface found!")
    print("Please connect an ME Interface Adapter to the computer.")
    os.exit(1)
end

local me = component.me_interface

-- Configuration: Define items to stock and their quantities
-- Format: {name = "minecraft:item_name", damage = 0, count = 64}
local stockList = {
    -- Example items (modify as needed)
    -- {name = "minecraft:iron_ingot", damage = 0, count = 64},
    -- {name = "minecraft:gold_ingot", damage = 0, count = 64},
}

-- Function to get current item count in ME system
local function getItemCount(itemName, itemDamage)
    local items = me.getItemsInNetwork()
    for _, item in pairs(items) do
        if item.name == itemName and item.damage == itemDamage then
            return item.size
        end
    end
    return 0
end

-- Function to craft an item
local function craftItem(itemName, itemDamage, quantity)
    local craftables = me.getCraftables()
    for _, craftable in pairs(craftables) do
        local itemStack = craftable.getItemStack()
        if itemStack.name == itemName and itemStack.damage == itemDamage then
            print("Requesting craft: " .. quantity .. "x " .. itemName)
            craftable.request(quantity)
            return true
        end
    end
    return false
end

-- Main stocking loop
local function runStocker()
    term.clear()
    print("=== ME Auto-Stocker ===")
    print("Monitoring stock levels...")
    print("")
    
    while true do
        for _, item in ipairs(stockList) do
            local currentCount = getItemCount(item.name, item.damage)
            local needed = item.count - currentCount
            
            if needed > 0 then
                print("Stock low: " .. item.name .. " (have: " .. currentCount .. ", want: " .. item.count .. ")")
                if craftItem(item.name, item.damage, needed) then
                    print("  -> Crafting requested")
                else
                    print("  -> No crafting pattern available")
                end
            end
        end
        
        -- Wait before checking again (30 seconds)
        os.sleep(30)
    end
end

-- Check if we have a valid stock list
if #stockList == 0 then
    print("Warning: Stock list is empty!")
    print("Edit stocker.lua to add items to monitor.")
    print("")
    print("Example configuration:")
    print('  {name = "minecraft:iron_ingot", damage = 0, count = 64},')
    print("")
    print("Press any key to exit...")
    term.read()
    os.exit(0)
end

-- Start the stocker
runStocker()
