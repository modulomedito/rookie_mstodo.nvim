#!/usr/bin/env bash
# Builds the todo-cli dependency (https://github.com/mehmetseckin/todo-cli)
# for rookie_mstodo.nvim, into <plugin>/deps/bin/.
#
# Order of attempts:
#   1. already built binary works            -> skip
#   2. .NET SDK available                    -> build from source (pinned ref)
#   3. `todo` already on $PATH               -> use it (with a warning)
#   4. otherwise                             -> fail with instructions
#
# Note: prebuilt GitHub release binaries of todo-cli are published with
# assembly trimming enabled, which breaks their JSON output at runtime.
# That is why this script builds from source instead of downloading a release.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_DIR="$PLUGIN_DIR/deps"
BIN_DIR="$DEPS_DIR/bin"
SRC_DIR="$DEPS_DIR/src/todo-cli"

REPO_URL="https://github.com/mehmetseckin/todo-cli"
# Pinned commit on master (2026-08-07): `todo add item <subject> --list <name>`
# syntax, `-o json` output, `--all` listing. Change to move to another ref.
REF="3d2be440feceac0fdfb6d7a015c38003c83c28a8"

log() { printf "[rookie_mstodo] %s\n" "$*"; }
die() { printf "[rookie_mstodo] ERROR: %s\n" "$*" >&2; exit 1; }

detect_rid() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  local os_part arch_part
  case "$os" in
    Linux)               os_part="linux" ;;
    Darwin)              os_part="osx" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) os_part="win" ;;
    *) die "unsupported OS: $os" ;;
  esac
  case "$arch" in
    x86_64|amd64|AMD64|x64) arch_part="x64" ;;
    arm64|aarch64|ARM64)    arch_part="arm64" ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  echo "${os_part}-${arch_part}"
}

RID="$(detect_rid)"
EXE="todo"
[ "$RID" = "win-x64" ] && EXE="todo.exe"

# 1. Already built and working?
if [ -f "$BIN_DIR/$EXE" ] && [ -f "$BIN_DIR/.ref" ] && [ "$(cat "$BIN_DIR/.ref")" = "$REF" ]; then
  if "$BIN_DIR/$EXE" --version >/dev/null 2>&1; then
    log "todo-cli already built at $BIN_DIR/$EXE, skipping"
    exit 0
  fi
  log "existing binary is broken, rebuilding"
fi

# 2. Build from source with the .NET SDK
if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q .; then
  log "building todo-cli ($REF) for $RID with dotnet (this takes a few minutes)..."
  rm -rf "$SRC_DIR" "$DEPS_DIR/todo-cli.tar.gz"
  mkdir -p "$DEPS_DIR"
  curl -fSL "$REPO_URL/archive/$REF.tar.gz" -o "$DEPS_DIR/todo-cli.tar.gz" \
    || die "failed to download todo-cli source"
  tar -xzf "$DEPS_DIR/todo-cli.tar.gz" -C "$DEPS_DIR"
  rm -f "$DEPS_DIR/todo-cli.tar.gz"
  EXTRACTED="$(find "$DEPS_DIR" -maxdepth 1 -type d -name 'todo-cli-*' | head -n1)"
  [ -n "$EXTRACTED" ] || die "could not find extracted source directory"
  mkdir -p "$DEPS_DIR/src"
  mv "$EXTRACTED" "$SRC_DIR"

  # Patch: allow non-interactive deletion via TODO_CLI_ASSUME_YES=1.
  # Upstream `todo remove item` always opens an interactive Inquirer.cs
  # confirmation, which crashes when stdout is not a console (e.g. when
  # spawned from Neovim). The patch only bypasses the prompt when the
  # environment variable is explicitly set; default behaviour is unchanged.
  REMOVE_HANDLER="$SRC_DIR/src/Todo.CLI/Handlers/RemoveCommandHandler.cs"
  if grep -q "TODO_CLI_ASSUME_YES" "$REMOVE_HANDLER"; then
    log "non-interactive patch already present"
  elif grep -q "if (_userInteraction.Confirm(message))" "$REMOVE_HANDLER"; then
    PATCH_TMP="$REMOVE_HANDLER.tmp"
    sed 's|if (_userInteraction.Confirm(message))|if (Environment.GetEnvironmentVariable("TODO_CLI_ASSUME_YES") == "1" \|\| _userInteraction.Confirm(message))|' \
      "$REMOVE_HANDLER" > "$PATCH_TMP"
    mv "$PATCH_TMP" "$REMOVE_HANDLER"
    grep -q "TODO_CLI_ASSUME_YES" "$REMOVE_HANDLER" \
      || die "failed to patch RemoveCommandHandler.cs"
    log "patched: non-interactive 'remove item' via TODO_CLI_ASSUME_YES=1"
  else
    log "WARNING: could not patch RemoveCommandHandler.cs (upstream changed?)."
    log "         Deleting a task will fall back to an interactive terminal."
  fi

  # PublishTrimmed=false is essential: trimming breaks System.Text.Json
  # reflection-based serialization, which is how `-o json` output works.
  dotnet publish "$SRC_DIR/src/Todo.CLI/Todo.CLI.csproj" \
    -c Release \
    -r "$RID" \
    -p:PublishTrimmed=false \
    -o "$BIN_DIR" \
    || die "dotnet publish failed"

  echo "$REF" > "$BIN_DIR/.ref"
  "$BIN_DIR/$EXE" --version >/dev/null 2>&1 || die "built binary failed to run"
  log "built todo-cli at $BIN_DIR/$EXE"
  exit 0
fi

# 3. Fall back to a system installation
if command -v todo >/dev/null 2>&1; then
  log "dotnet SDK not found; using 'todo' from PATH"
  log "NOTE: GitHub release builds of todo-cli have broken JSON output (trimming)."
  log "      If listing fails with a serialization error, install the .NET SDK"
  log "      (https://dotnet.microsoft.com/download) and re-run:"
  log "        bash $PLUGIN_DIR/scripts/install.sh"
  exit 0
fi

die "cannot build todo-cli: no .NET SDK and no 'todo' on PATH.
Install the .NET SDK (https://dotnet.microsoft.com/download) and re-run:
  bash $PLUGIN_DIR/scripts/install.sh
Or install a working todo-cli yourself and set opts.cmd in setup()."
