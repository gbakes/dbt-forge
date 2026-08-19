#!/usr/bin/env bash
# Runs the busted suite with the environment it actually needs on this
# machine. `busted` alone is not enough: luarocks installs busted against
# the system default Lua (5.4) unless told otherwise, which the luajit
# runtime `.busted` requires (5.1 ABI) cannot load; and even after
# installing the right rock tree, luajit's `-e '<script>' <file>` form
# (which the generated busted wrapper uses internally) fails to resolve
# `busted.runner` on this machine unless LUA_PATH/LUA_CPATH are exported.
# See .superpowers/sdd/2026-08-05-model-lineage/task-1-report.md for the
# full diagnosis. Run this script (not bare `busted`) from a clean shell.
set -euo pipefail

export PATH="$HOME/.luarocks/bin:$PATH"
export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$HOME/.luarocks/lib/lua/5.1/?.so;;"

exec busted "$@"
