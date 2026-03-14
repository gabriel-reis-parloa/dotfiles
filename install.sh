#!/bin/bash
# install.sh — symlink dotfiles into place
# Run once after cloning. Safe to re-run; existing symlinks are skipped.

set -e
REPO="$(cd "$(dirname "$0")" && pwd)"

link() {
  local src="$REPO/$1"
  local dst="$HOME/$2"
  local dir
  dir=$(dirname "$dst")
  mkdir -p "$dir"
  if [ -L "$dst" ]; then
    echo "  skip (already linked): $dst"
  elif [ -e "$dst" ]; then
    echo "  WARN: $dst exists and is not a symlink — skipping (back it up manually if needed)"
  else
    ln -s "$src" "$dst"
    echo "  linked: $dst"
  fi
}

echo "Installing claude-code-setup symlinks..."
echo ""

link "home/.local/bin/claude-status"                ".local/bin/claude-status"
link "home/.local/bin/claude-ready"                 ".local/bin/claude-ready"
link "home/.local/bin/kitchen-gateway-status"       ".local/bin/kitchen-gateway-status"
link "home/.local/bin/README.md"                    ".local/bin/README.md"
link "home/bin/switch-context"                      "bin/switch-context"
link "home/.claude/hooks/patch-gateway-timeouts.sh" ".claude/hooks/patch-gateway-timeouts.sh"
link "home/.context/refresh-mcp-tokens.sh"          ".context/refresh-mcp-tokens.sh"

echo ""
echo "Setting execute permissions..."
chmod +x \
  "$REPO/home/.local/bin/claude-status" \
  "$REPO/home/.local/bin/claude-ready" \
  "$REPO/home/.local/bin/kitchen-gateway-status" \
  "$REPO/home/bin/switch-context" \
  "$REPO/home/.context/refresh-mcp-tokens.sh"
echo "  done"

echo ""
echo "VS Code tasks (copy manually to your workspace):"
echo "  cp $REPO/vscode/tasks.json ~/projects/parloa/.vscode/tasks.json"
echo ""
echo "Done. Edit scripts directly in $REPO — symlinks take effect immediately."
