#!/bin/sh
# Fetches the CraftOS ROM (bios.lua + rom/) and terminal font from CC:Tweaked so the
# mock harness can boot the real CraftOS instead of its built-in ports:
#   sh tools/fetch_rom.sh [dir]        (default dir: test/rom, git-ignored)
#   CC_ROM=test/rom/lua lua5.2 test/run.lua
set -e
DIR=${1:-test/rom}
COMMIT=c8b3f6af270cd74c7494e2bf45a9f377b90c9b29   # CC:Tweaked 1.120.2 (mc-1.20.x)
LUA=projects/core/src/main/resources/data/computercraft/lua
FONT=projects/core/src/main/resources/assets/computercraft/textures/gui/term_font.png
TMP="$DIR/checkout"
rm -rf "$TMP"
mkdir -p "$TMP"
git -C "$TMP" init -q
git -C "$TMP" remote add origin https://github.com/cc-tweaked/CC-Tweaked
git -C "$TMP" sparse-checkout set --no-cone "/$LUA/" "/$FONT"
git -C "$TMP" fetch -q --depth 1 --filter=blob:none origin "$COMMIT"
git -C "$TMP" checkout -q FETCH_HEAD
rm -rf "$DIR/lua"
cp -r "$TMP/$LUA" "$DIR/lua"
cp "$TMP/$FONT" "$DIR/term_font.png"
rm -rf "$TMP"
echo "ROM in $DIR/lua, font in $DIR/term_font.png"
