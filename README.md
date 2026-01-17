# zap

**Fast and Safe Python Package Manager** - A blazingly fast Python package manager written in Zig.

## Features

- **Fast**: Written in Zig for maximum performance
- **Safe**: Built with Zig's memory safety guarantees
- **Dependency Resolution**: Automatically resolves and installs dependencies
- **pyproject.toml Support**: Standard Python project configuration (PEP 621)
- **Sync Command**: Install all dependencies from pyproject.toml with one command
- **Python Version Management**: Automatically detects and manages Python versions
- **Virtual Environments**: Creates and manages isolated Python environments
- **Lock Files**: Generates `zap.lock` for reproducible builds
- **Simple CLI**: Easy-to-use command-line interface

## Installation

### Build from Source

```bash
# Clone the repository
git clone <your-repo-url>
cd zap

# Build with Zig 0.15.2+
zig build -Doptimize=ReleaseFast
```

### System-wide Install 

```bash
# Install to /usr/local/bin (recommended)
sudo zig build -Doptimize=ReleaseFast --prefix /usr/local install

# Or with doas
doas zig build -Doptimize=ReleaseFast --prefix /usr/local install

# Or install to /usr
sudo zig build -Doptimize=ReleaseFast --prefix /usr install
```

### User-local Install 

```bash
# Install to ~/.local/bin
zig build -Doptimize=ReleaseFast --prefix ~/.local install

# Make sure ~/.local/bin is in your PATH
# Add to ~/.bashrc or ~/.zshrc:
export PATH="$HOME/.local/bin:$PATH"
```

### Quick Install (manual copy)

```bash
# Build and copy manually
zig build -Doptimize=ReleaseFast
cp zig-out/bin/zap ~/.local/bin/    # user-local
# or
sudo cp zig-out/bin/zap /usr/local/bin/  # system-wide
```

## Usage

### Initialize a New Project

```bash
# Initialize with default Python version
zap init

# Initialize with specific Python version
zap init --python 3.11
```

This creates:
- `.venv/` - Virtual environment directory
- `zap.lock` - Lock file for dependencies
- `pyproject.toml` - Project configuration (if it doesn't exist)

### Sync Dependencies from pyproject.toml

```bash
# Install all dependencies listed in pyproject.toml
zap sync
```

You can manually edit `pyproject.toml` to add dependencies:

```toml
[project]
name = "my-app"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "requests",
    "numpy",
    "pandas",
]
```

Then run `zap sync` to install them all at once.

### Install Packages

```bash
# Install one or more packages
zap append requests numpy pandas

# Packages are installed in the virtual environment,
# added to pyproject.toml, and recorded in zap.lock
```

### Remove Packages

```bash
# Remove one or more packages
zap remove pandas numpy

# Packages are uninstalled, removed from pyproject.toml, and zap.lock
```

### Run Python Scripts

```bash
# Run a Python script in the virtual environment
zap run script.py

# Pass arguments to the script
zap run script.py --arg1 value1 --arg2 value2
```

### Other Commands

```bash
# Show version
zap version

# Show help
zap help
```

## Lock File Format

`zap.lock` uses a simple TOML-like format:

```toml
# zap.lock - Fast and Safe Python Package Manager
# This file is auto-generated. Do not edit manually.

python = "3.11.5"

[[packages]]
name = "requests"
version = "2.31.0"

[[packages]]
name = "numpy"
version = "1.24.3"
```

## Architecture

### Project Structure

```
src/
├── main.zig       # Entry point and CLI router
├── cli.zig        # Command implementations
├── python.zig     # Python detection and version management
├── venv.zig       # Virtual environment management
├── pypi.zig       # PyPI JSON API integration and downloads
├── wheel.zig      # Wheel extraction and installation
├── package.zig    # Package installation/removal orchestration
├── pyproject.zig  # pyproject.toml parsing and management
└── lock.zig       # Lock file handling
```

### How It Works

1. **Python Detection** (`python.zig`): Searches for Python installations in order of preference (python3.14, 3.13, 3.12, 3.11, etc.)

2. **Virtual Environment** (`venv.zig`): Creates isolated Python environments using `python -m venv`

3. **PyPI Integration** (`pypi.zig`): Fetches package metadata from PyPI's JSON API, resolves dependencies, and downloads wheel files

4. **Wheel Extraction** (`wheel.zig`): Extracts wheel files (which are ZIP archives) and installs them to site-packages

5. **Package Management** (`package.zig`): Coordinates installation and removal of packages with dependency resolution

6. **Lock Files** (`lock.zig`): Maintains a reproducible record of installed packages and Python version

## Why Zig?

- **Performance**: im have nothing to do

## Requirements

- Zig 0.15.2 or later (for building)
- Python 3.9+ installed on your system

**No external dependencies!** zap uses native Zig implementations for:
- HTTP/HTTPS (via `std.http.Client`)
- ZIP extraction (via `std.zip`)
- JSON parsing (via `std.json`)

## Development

### Build

```bash
zig build
```

### Run Tests

```bash
zig build test
```

### Build for Release (Fast)

```bash
zig build -Doptimize=ReleaseFast
```

### Build for Release (Safe)

```bash
zig build -Doptimize=ReleaseSafe
```

## Roadmap

- [x] Direct PyPI integration
- [x] Dependency resolution
- [x] Wheel file extraction and installation
- [x] Native HTTP client (no curl!)
- [x] Native ZIP extraction (no unzip!)
- [x] pyproject.toml support (PEP 621)
- [x] Zero external dependencies
- [ ] Parallel package downloads
- [ ] Advanced dependency conflict resolution
- [ ] Package caching and reuse
- [ ] Workspace support
- [ ] Python version installation and management
- [ ] Cross-platform binaries (Windows, macOS)

## License

CUSTOM

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
