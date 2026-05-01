# GregTech OpenComputers Scripts

A collection of OpenComputers Lua scripts for the GregTech New Horizons modpack (Minecraft 1.7.10).

## Installation

To install these scripts on your OpenComputer, run the following command:

```lua
wget https://raw.githubusercontent.com/bk5115545/gregtech-opencomputers/main/install.lua install.lua && install.lua
```

This will download and run the installer, which will automatically download all available scripts to your computer.

## Available Scripts

### stocker.lua
An Applied Energistics auto-stocker that maintains stock levels of items in your ME system.

**Requirements:**
- ME Controller connected to your OpenComputer (via Adapter)
- Crafting patterns set up in your ME system for items you want to stock

**Usage:**
1. Edit `stocker.lua` to configure which items to stock
2. Run: `/home/stocker.lua`

## Manual Installation

If you prefer to install scripts manually:

```lua
wget https://raw.githubusercontent.com/bk5115545/gregtech-opencomputers/main/stocker.lua /home/stocker.lua
```

## Contributing

Feel free to submit pull requests with additional scripts or improvements!

## License

See LICENSE file for details.
