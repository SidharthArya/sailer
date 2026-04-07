#!/bin/bash
set -e

echo "Sailer Compositor - Ubuntu/Debian Installer"
echo "=========================================="

# Check for Zig
if ! command -v zig &> /dev/null || [[ $(zig version) < "0.15.2" ]]; then
    echo "Warning: Zig 0.15.2 or later is required. Current: $(zig version 2>/dev/null || echo 'none')"
    echo "Please install it from https://ziglang.org/download/"
    exit 1
fi

echo "Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libwayland-dev \
    wayland-protocols \
    libxkbcommon-dev \
    libpixman-1-dev \
    libfreetype6-dev \
    libdbus-1-dev \
    python3-yaml \
    scdoc

# Check for wlroots 0.19
if ! pkg-config --exists "wlroots-0.19"; then
    echo "Warning: wlroots 0.19 not found via pkg-config."
    echo "You may need to build it from source or use a PPA."
    echo "Check https://gitlab.freedesktop.org/wlroots/wlroots"
    # exit 1 # Let the user decide if they want to try anyway
fi

echo "Building Sailer..."
zig build -Doptimize=ReleaseSafe

echo "Success! The binary is at zig-out/bin/sailer"
echo "To install system-wide, run: sudo cp zig-out/bin/sailer /usr/local/bin/"
