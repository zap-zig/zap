# Contributing to zap

Thank you for your interest in contributing to zap! This document provides guidelines for contributing.

## Getting Started

### Prerequisites

- Zig 0.15.2 or later
- Python 3.9+ (for testing)
- Git

### Building

```bash
git clone https://github.com/YOUR_USERNAME/zap.git
cd zap
zig build
```

### Running Tests

```bash
zig build test
```

## How to Contribute

### Reporting Bugs

1. Check existing issues to avoid duplicates
2. Create a new issue with:
   - Clear description of the bug
   - Steps to reproduce
   - Expected vs actual behavior
   - Zig version and OS

### Suggesting Features

1. Open an issue describing the feature
2. Explain the use case
3. Discuss implementation approach

### Submitting Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Ensure code compiles: `zig build`
5. Run tests: `zig build test`
6. Commit with clear message
7. Push to your fork
8. Open a Pull Request

## Code Style

- Follow Zig's official style guide
- Use descriptive variable names
- Add comments for complex logic
- Keep functions small and focused
- Handle all errors explicitly

## Project Structure

```
src/
├── main.zig        # CLI entry point
├── cli.zig         # Command implementations
├── python.zig      # Python detection
├── venv.zig        # Virtual environment
├── pypi.zig        # PyPI API client
├── http.zig        # HTTP client
├── zip.zig         # ZIP extraction
├── wheel.zig       # Wheel handling
├── package.zig     # Package management
├── pyproject.zig   # pyproject.toml
└── lock.zig        # Lock file
```

## Areas for Contribution

Check `TODO.md` for a detailed list. High-impact areas:

- [ ] Package caching
- [ ] Parallel downloads
- [ ] Better dependency resolution
- [ ] More test coverage
- [ ] Documentation improvements

## Questions?

Feel free to open an issue for any questions!
