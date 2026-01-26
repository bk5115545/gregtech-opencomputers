# Copilot Instructions for GregTech OpenComputers Scripts

Welcome to the GregTech OpenComputers Scripts project! This document provides guidance for AI coding agents to effectively contribute to this repository. Please follow these instructions to ensure consistency and maintainability.

## Project Overview
This repository contains Lua scripts designed for use with the OpenComputers mod in the GregTech New Horizons modpack (Minecraft 1.7.10). The scripts automate various tasks, such as managing stock levels in an Applied Energistics ME system.

### Key Files
- `install.lua`: The installer script that downloads and sets up all available scripts on an OpenComputer. It ensures the installation directory exists, downloads the required files from the GitHub repository, and provides a summary of the installation process.
- `stocker.lua`: A memory-safe auto-stocker for Applied Energistics 2 (AE2) systems. It interacts with the ME Controller connected to the OpenComputer via an Adapter. The script includes features such as:
  - Caching of stock levels and fluids to optimize performance.
  - Management of batch sizes for crafting operations.
  - Lookup and management of craftable items in the ME system.

## Developer Workflows

### Testing Scripts
- Test scripts directly on an OpenComputer in the GregTech New Horizons modpack.
- Use the `wget` command to download scripts to the OpenComputer for testing.
  ```lua
  wget https://raw.githubusercontent.com/bk5115545/gregtech-opencomputers/main/<script_name>.lua /home/<script_name>.lua
  ```
- Run the script using the following command:
  ```
  /home/<script_name>.lua
  ```

### Debugging
- Use `print()` statements to debug scripts. Logs will appear in the OpenComputer console.
- Ensure that the scripts handle errors gracefully and provide meaningful error messages to the user.

## Project-Specific Conventions
- Scripts should be written in Lua and follow Lua best practices.
- Use descriptive variable and function names to improve readability.
- Include comments to explain the purpose and functionality of code sections, but avoid adding comments to the end of lines solely to explain changes.
- Ensure compatibility with the OpenComputers API and the GregTech New Horizons modpack.

## Integration Points
- Scripts interact with the Applied Energistics ME system via an ME Controller connected to the OpenComputer.
- Ensure that the ME Controller is properly configured with crafting patterns for the items managed by the scripts.

## Adding New Scripts
- Place new scripts in the root directory of the repository.
- Update the `install.lua` script to include the new script in the installation process.
- We do not submit pull requests. Instead, we directly commit to the main branch and allow the operator to push changes.

## License
This project is licensed under the MIT License. See the `LICENSE` file for details.