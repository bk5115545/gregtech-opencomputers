-- install.lua
-- Installer for GregTech OpenComputers scripts
-- Run with: wget https://raw.githubusercontent.com/bk5115545/gregtech-opencomputers/main/install.lua install.lua && install.lua

local shell = require("shell")
local fs = require("filesystem")

-- Configuration
local REPO_OWNER = "bk5115545"
local REPO_NAME = "gregtech-opencomputers"
local BRANCH = "main"
local BASE_URL = "https://raw.githubusercontent.com/" .. REPO_OWNER .. "/" .. REPO_NAME .. "/" .. BRANCH .. "/"

-- Installation directory
local INSTALL_DIR = "/home/"

-- List of files to download
local FILES = {
    "stocker.lua",
}

-- Helper function to download a file
local function downloadFile(filename, targetPath)
    local url = BASE_URL .. filename
    print("Downloading: " .. filename)
    print("  From: " .. url)
    print("  To: " .. targetPath)
    
    local result, reason = shell.execute("wget -f " .. url .. " " .. targetPath)
    
    if result == false or result == nil then
        print("  [ERROR] Failed to download: " .. (reason or "unknown error"))
        return false
    end
    
    print("  [OK] Download complete")
    return true
end

-- Main installation function
local function install()
    print("=====================================")
    print("GregTech OpenComputers Installer")
    print("=====================================")
    print("")
    
    -- Create installation directory if it doesn't exist
    if not fs.exists(INSTALL_DIR) then
        print("Creating directory: " .. INSTALL_DIR)
        fs.makeDirectory(INSTALL_DIR)
    end
    
    print("Installing to: " .. INSTALL_DIR)
    print("")
    
    local successCount = 0
    local failCount = 0
    
    -- Download each file
    for _, filename in ipairs(FILES) do
        local targetPath = INSTALL_DIR .. filename
        
        if downloadFile(filename, targetPath) then
            successCount = successCount + 1
        else
            failCount = failCount + 1
        end
        
        print("")
    end
    
    -- Summary
    print("=====================================")
    print("Installation Summary:")
    print("  Success: " .. successCount)
    print("  Failed: " .. failCount)
    print("=====================================")
    print("")
    
    if failCount == 0 then
        print("Installation complete!")
        print("")
        print("Available programs:")
        for _, filename in ipairs(FILES) do
            print("  - " .. filename)
        end
        print("")
        print("To run stocker: /home/stocker.lua")
        return true
    else
        print("Installation completed with errors.")
        print("Please check your internet connection and try again.")
        return false
    end
end

-- Run the installer
local success = install()

if success then
    os.exit(0)
else
    os.exit(1)
end
