#!/bin/bash

echo "Building for GNULINUX AMD64..."
zig build -Dtarget=x86_64-linux-gnu
cp zig-out/bin/zap zap-linux-x86_64

echo "Building for GNULINUX AARCH64..."
zig build -Dtarget=aarch64-linux-gnu
cp zig-out/bin/zap zap-linux-aarch64

echo "Building for MACOS AMD64..."
zig build -Dtarget=x86_64-macos
cp zig-out/bin/zap zap-macos-x86_64

echo "Building for MACOS ARM64 (Apple Silicon)..."
zig build -Dtarget=aarch64-macos
cp zig-out/bin/zap zap-macos-aarch64
