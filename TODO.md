# ZAP - Development Checklist

## Project Stats
- **Total Lines of Code**: ~1,623 lines of Zig
- **External Dependencies**: 0 (zero!)
- **Binary Size**: ~8 MB (vs uv's 51 MB)

---

## DONE - Core Features

### CLI & Commands
- [x] `zap init` - Initialize project with venv
- [x] `zap init --python <version>` - Specify Python version
- [x] `zap append <packages...>` - Install packages
- [x] `zap remove <packages...>` - Remove packages
- [x] `zap sync` - Install from pyproject.toml
- [x] `zap run <script.py>` - Run Python script in venv
- [x] `zap version` - Show version
- [x] `zap help` - Show help

### Python Management
- [x] Auto-detect Python installations (3.9-3.14)
- [x] Validate Python is functional before use
- [x] Support `--python` flag for version selection

### Virtual Environment
- [x] Manual venv creation (fast! ~0.1s)
- [x] Create directory structure (`bin/`, `lib/`, `site-packages/`)
- [x] Symlink Python executable
- [x] Generate `pyvenv.cfg`
- [x] Generate `activate` script

### PyPI Integration
- [x] Fetch package metadata from PyPI JSON API
- [x] Parse package name and version
- [x] Parse dependencies (`requires_dist`)
- [x] Find compatible wheel (cpXX, py3, none-any)
- [x] Fallback to sdist if no wheel

### Package Installation
- [x] Download wheel files from PyPI
- [x] Extract wheel (ZIP) to cache
- [x] Install to site-packages
- [x] Recursive dependency installation

### Package Removal
- [x] Remove package directory
- [x] Remove .dist-info directory

### Native Implementations (No External Tools!)
- [x] HTTP/HTTPS client (`std.http.Client`)
- [x] ZIP extraction (`std.zip`)
- [x] JSON parsing (`std.json`)
- [x] File system operations (`std.fs`)

### Project Files
- [x] `zap.lock` - Lock file generation
- [x] `zap.lock` - Lock file parsing
- [x] `pyproject.toml` - Generation on init
- [x] `pyproject.toml` - Parsing
- [x] `pyproject.toml` - Auto-update on append/remove

---

## TODO - For Production Ready

### HIGH PRIORITY

#### Package Caching
- [ ] Cache downloaded wheels in `~/.cache/zap/`
- [ ] Check cache before downloading
- [ ] Cache invalidation strategy
- [ ] `zap cache clean` command

#### Dependency Resolution (Critical!)
- [ ] Handle version constraints (`>=`, `<=`, `==`, `~=`, `!=`)
- [ ] Version conflict detection
- [ ] Better dependency tree resolution
- [ ] Skip conditional deps properly (`;extra==`, `;python_version`)
- [ ] Handle circular dependencies

#### Error Handling
- [ ] Better error messages for network failures
- [ ] Handle PyPI rate limiting
- [ ] Graceful handling of missing packages
- [ ] Recovery from partial installations
- [ ] Validate wheel before extraction

#### Lock File Improvements
- [ ] Store full dependency tree in lock
- [ ] `zap install --frozen` (exact versions from lock)
- [ ] Hash verification for packages
- [ ] Lock file version/format

### MEDIUM PRIORITY

#### Performance
- [ ] Parallel package downloads (use `std.Thread`)
- [ ] Parallel dependency resolution
- [ ] Skip already-installed packages
- [ ] Incremental sync (only install new deps)

#### More Commands
- [ ] `zap list` - List installed packages
- [ ] `zap show <package>` - Show package info
- [ ] `zap update <package>` - Update specific package
- [ ] `zap update` - Update all packages
- [ ] `zap freeze` - Output requirements.txt format
- [ ] `zap search <query>` - Search PyPI

#### pyproject.toml
- [ ] Parse version constraints from deps
- [ ] Support `[project.optional-dependencies]`
- [ ] Support `[tool.zap]` config section
- [ ] Preserve comments and formatting on edit

#### Virtual Environment
- [ ] `zap venv create` - Explicit venv creation
- [ ] `zap venv remove` - Remove venv
- [ ] Custom venv path support
- [ ] Fish/Zsh activation scripts

### LOW PRIORITY

#### Python Version Management (like pyenv)
- [ ] `zap python install 3.12` - Download Python
- [ ] `zap python list` - List available versions
- [ ] `zap python use 3.12` - Set default version
- [ ] Download from python-build-standalone

#### Source Distributions
- [ ] Build sdist packages (run setup.py)
- [ ] Handle packages with native extensions
- [ ] Compile C extensions

#### Advanced Features
- [ ] Workspace support (monorepos)
- [ ] Private PyPI index support
- [ ] Git dependencies
- [ ] Local path dependencies
- [ ] Editable installs (`-e`)

---

## TODO - For GitHub/Codeberg Release

### Repository Setup
- [ ] Choose license (MIT recommended)
- [ ] Create LICENSE file
- [ ] Update README with actual repo URL
- [ ] Add CONTRIBUTING.md
- [ ] Add CODE_OF_CONDUCT.md
- [ ] Create .gitignore

### Documentation
- [ ] Installation instructions (done!)
- [ ] Usage examples
- [ ] API documentation
- [ ] Architecture overview
- [ ] Comparison with uv/pip/poetry

### CI/CD
- [ ] GitHub Actions workflow
- [ ] Build for Linux x86_64
- [ ] Build for Linux aarch64
- [ ] Build for macOS x86_64
- [ ] Build for macOS aarch64
- [ ] Build for Windows (future)
- [ ] Run tests on PR
- [ ] Release automation

### Testing
- [ ] Unit tests for each module
- [ ] Integration tests
- [ ] Test with different Python versions
- [ ] Test with complex packages (numpy, etc.)
- [ ] Edge case testing

### Release
- [ ] Semantic versioning
- [ ] Changelog (CHANGELOG.md)
- [ ] GitHub Releases with binaries
- [ ] Update version in cli.zig

---

## File Structure (Current)

```
zap/
├── build.zig           # Zig build configuration
├── build.zig.zon       # Package manifest
├── README.md           # Documentation
├── TODO.md             # This file
├── src/
│   ├── main.zig        # Entry point, CLI router (40 lines)
│   ├── cli.zig         # Command implementations (225 lines)
│   ├── python.zig      # Python detection (101 lines)
│   ├── venv.zig        # Venv management (192 lines)
│   ├── pypi.zig        # PyPI API client (194 lines)
│   ├── http.zig        # Native HTTP client (64 lines)
│   ├── zip.zig         # Native ZIP extraction (26 lines)
│   ├── wheel.zig       # Wheel handling (82 lines)
│   ├── package.zig     # Package install/remove (173 lines)
│   ├── pyproject.zig   # pyproject.toml (317 lines)
│   ├── lock.zig        # Lock file handling (186 lines)
│   └── root.zig        # Library root (23 lines)
└── zig-out/
    └── bin/
        └── zap         # Built binary (~8 MB)
```

---

## Quick Wins (Easy to Implement)

1. **`zap list`** - Just iterate site-packages .dist-info dirs
2. **LICENSE file** - Copy MIT license text
3. **`.gitignore`** - Standard Zig gitignore
4. **Skip installed** - Check if package exists before download
5. **`zap cache clean`** - Delete .zap-cache directory

---

## Known Issues

1. **Dependency parsing** - Doesn't handle complex version specs
2. **Conditional deps** - Installs all deps even platform-specific
3. **Lock file** - Sometimes empty after install
4. **Large packages** - May timeout on slow connections
5. **No progress bar** - Silent during large downloads

---

## Performance Comparison

| Operation | zap | uv | Notes |
|-----------|-----|-----|-------|
| Init | 0.1s | 0.08s | zap is competitive! |
| Install (simple) | 0.7s | 0.5s | Close |
| Install (complex) | 3-5s | 0.5s | Need caching + parallel |
| Binary size | 8 MB | 51 MB | zap wins 6.4x |
