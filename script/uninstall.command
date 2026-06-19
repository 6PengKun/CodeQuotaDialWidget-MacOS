#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/local-config.env"
APP_NAME="CodeQuotaDialXcode"
INSTALL_BASE="/Applications"
WIDGET_EXTENSION_NAME="CodeQuotaDialWidgetExtension.appex"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CODEX_LABEL="local.codex-quota-dial.refresh"
CLAUDE_LABEL="local.claude-quota-dial.refresh"
GLM_LABEL="local.glm-quota-dial.refresh"
ANTIGRAVITY_LABEL="local.antigravity-quota-dial.refresh"
CODEX_PLIST="$LAUNCH_AGENTS_DIR/$CODEX_LABEL.plist"
CLAUDE_PLIST="$LAUNCH_AGENTS_DIR/$CLAUDE_LABEL.plist"
GLM_PLIST="$LAUNCH_AGENTS_DIR/$GLM_LABEL.plist"
ANTIGRAVITY_PLIST="$LAUNCH_AGENTS_DIR/$ANTIGRAVITY_LABEL.plist"
USER_GUI_DOMAIN="gui/$(id -u)"
GROUP_CONTAINERS_DIR="$HOME/Library/Group Containers"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
INCLUDE_PROJECT_BUILD=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--include-project-build]

Uninstalls Code Quota Dial Widget from this macOS user account.

Options:
  --include-project-build  Also remove .build under this checkout.
  -h, --help               Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-project-build)
      INCLUDE_PROJECT_BUILD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

INSTALL_APP="$INSTALL_BASE/$APP_NAME.app"

remove_path() {
  local target_path="$1"

  if [[ -e "$target_path" || -L "$target_path" ]]; then
    echo "==> Removing $target_path"
    rm -rf "$target_path"
  else
    echo "==> Not found: $target_path"
  fi
}

unload_launch_agent() {
  local label="$1"
  local plist_path="$2"

  if [[ -f "$plist_path" ]]; then
    launchctl bootout "$USER_GUI_DOMAIN" "$plist_path" >/dev/null 2>&1 || true
  fi
  launchctl bootout "$USER_GUI_DOMAIN/$label" >/dev/null 2>&1 || true
  launchctl remove "$label" >/dev/null 2>&1 || true
}

unregister_widget() {
  local appex_path="$INSTALL_APP/Contents/PlugIns/$WIDGET_EXTENSION_NAME"

  if [[ -d "$appex_path" ]]; then
    echo "==> Unregistering widget extension"
    pluginkit -r "$appex_path" >/dev/null 2>&1 || true
  fi

  if [[ -x "$LSREGISTER" && -d "$INSTALL_APP" ]]; then
    "$LSREGISTER" -u "$INSTALL_APP" >/dev/null 2>&1 || true
  fi
}

remove_group_containers() {
  typeset -a group_paths
  typeset -U group_paths

  if [[ -n "${CODEX_APP_GROUP:-}" ]]; then
    group_paths+=("$GROUP_CONTAINERS_DIR/$CODEX_APP_GROUP")
  fi

  if [[ -n "${CLAUDE_APP_GROUP:-}" ]]; then
    group_paths+=("$GROUP_CONTAINERS_DIR/$CLAUDE_APP_GROUP")
  fi

  if [[ -n "${GLM_APP_GROUP:-}" ]]; then
    group_paths+=("$GROUP_CONTAINERS_DIR/$GLM_APP_GROUP")
  fi

  if [[ -n "${ANTIGRAVITY_APP_GROUP:-}" ]]; then
    group_paths+=("$GROUP_CONTAINERS_DIR/$ANTIGRAVITY_APP_GROUP")
  fi

  group_paths+=(
    "$GROUP_CONTAINERS_DIR/group.local.codex-token-monitor"
    "$GROUP_CONTAINERS_DIR/group.local.claude-quota-monitor"
    "$GROUP_CONTAINERS_DIR/group.local.glm-quota-monitor"
    "$GROUP_CONTAINERS_DIR/group.local.antigravity-quota-monitor"
  )

  local group_path
  for group_path in "$GROUP_CONTAINERS_DIR"/*codex-token-monitor(N) "$GROUP_CONTAINERS_DIR"/*claude-quota-monitor(N) "$GROUP_CONTAINERS_DIR"/*glm-quota-monitor(N) "$GROUP_CONTAINERS_DIR"/*antigravity-quota-monitor(N); do
    group_paths+=("$group_path")
  done

  for group_path in "${group_paths[@]}"; do
    remove_path "$group_path"
  done
}

remove_project_build_outputs() {
  remove_path "$PROJECT_ROOT/.build"
}

remove_runtime_outputs() {
  remove_path "$PROJECT_ROOT/Runtime/codex/CodexQuotaSnapshotTool"
  remove_path "$PROJECT_ROOT/Runtime/codex/logs"
  remove_path "$PROJECT_ROOT/Runtime/claude/ClaudeQuotaSnapshotTool"
  remove_path "$PROJECT_ROOT/Runtime/claude/logs"
  remove_path "$PROJECT_ROOT/Runtime/glm/GLMQuotaSnapshotTool"
  remove_path "$PROJECT_ROOT/Runtime/glm/logs"
  remove_path "$PROJECT_ROOT/Runtime/antigravity/AntigravityQuotaSnapshotTool"
  remove_path "$PROJECT_ROOT/Runtime/antigravity/logs"
  rmdir "$PROJECT_ROOT/Runtime/codex" "$PROJECT_ROOT/Runtime/claude" "$PROJECT_ROOT/Runtime/glm" "$PROJECT_ROOT/Runtime/antigravity" "$PROJECT_ROOT/Runtime" >/dev/null 2>&1 || true
}

echo "==> Unloading launch agents"
unload_launch_agent "$CODEX_LABEL" "$CODEX_PLIST"
unload_launch_agent "$CLAUDE_LABEL" "$CLAUDE_PLIST"
unload_launch_agent "$GLM_LABEL" "$GLM_PLIST"
unload_launch_agent "$ANTIGRAVITY_LABEL" "$ANTIGRAVITY_PLIST"

echo "==> Stopping app and widget services"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
killall WidgetKitExtensionHost >/dev/null 2>&1 || true
killall chronod >/dev/null 2>&1 || true
killall iconservicesagent >/dev/null 2>&1 || true
killall Dock >/dev/null 2>&1 || true

unregister_widget

remove_path "$INSTALL_APP"
remove_path "$CODEX_PLIST"
remove_path "$CLAUDE_PLIST"
remove_path "$GLM_PLIST"
remove_path "$ANTIGRAVITY_PLIST"
remove_group_containers
remove_runtime_outputs
remove_path "$HOME/Library/Caches/com.apple.chrono"

if [[ "$INCLUDE_PROJECT_BUILD" -eq 1 ]]; then
  echo "==> Removing project build outputs"
  remove_project_build_outputs
fi

echo
echo "Uninstall complete."
