#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
GENERATED_DIR="$PROJECT_ROOT/.build/generated"
APP_NAME="CodeQuotaDialXcode"
XCODEPROJ="$PROJECT_ROOT/XcodeApp/CodeQuotaDialXcode.xcodeproj"
SCHEME="$APP_NAME"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
WIDGET_EXTENSION_NAME="CodeQuotaDialWidgetExtension.appex"
RUNTIME_DIR="$PROJECT_ROOT/Runtime"
CODEX_RUNTIME_DIR="$RUNTIME_DIR/codex"
CLAUDE_RUNTIME_DIR="$RUNTIME_DIR/claude"
GLM_RUNTIME_DIR="$RUNTIME_DIR/glm"
ANTIGRAVITY_RUNTIME_DIR="$RUNTIME_DIR/antigravity"
USAGE_RUNTIME_DIR="$RUNTIME_DIR/usage"
CODEX_TOOL_RUNTIME="$CODEX_RUNTIME_DIR/CodexQuotaSnapshotTool"
CLAUDE_TOOL_RUNTIME="$CLAUDE_RUNTIME_DIR/ClaudeQuotaSnapshotTool"
GLM_TOOL_RUNTIME="$GLM_RUNTIME_DIR/GLMQuotaSnapshotTool"
ANTIGRAVITY_TOOL_RUNTIME="$ANTIGRAVITY_RUNTIME_DIR/AntigravityQuotaSnapshotTool"
USAGE_TOOL_RUNTIME="$USAGE_RUNTIME_DIR/UsageQuotaSnapshotTool"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
RUNTIME_CONFIG_FILE="$HOME/Library/Application Support/CodeQuotaDial/runtime-config.json"
CODEX_LABEL="local.codex-quota-dial.refresh"
CLAUDE_LABEL="local.claude-quota-dial.refresh"
GLM_LABEL="local.glm-quota-dial.refresh"
ANTIGRAVITY_LABEL="local.antigravity-quota-dial.refresh"
USAGE_LABEL="local.usage-quota-dial.refresh"
CODEX_PLIST="$LAUNCH_AGENTS_DIR/$CODEX_LABEL.plist"
CLAUDE_PLIST="$LAUNCH_AGENTS_DIR/$CLAUDE_LABEL.plist"
GLM_PLIST="$LAUNCH_AGENTS_DIR/$GLM_LABEL.plist"
ANTIGRAVITY_PLIST="$LAUNCH_AGENTS_DIR/$ANTIGRAVITY_LABEL.plist"
USAGE_PLIST="$LAUNCH_AGENTS_DIR/$USAGE_LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
USER_GUI_DOMAIN="gui/$(id -u)"
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
MARKETING_VERSION_VALUE="1.0"

# Every install setting is either a sensible constant default (below) or
# auto-detected (signing — see resolve_signing), so the install needs no config
# file at all. The rare override is passed as an
# environment variable on the command line, e.g.:
#   TEAM_ID=XXXXXXXXXX ./script/install.command          # pin one of several signing identities
#   REFRESH_INTERVAL=60 ./script/install.command         # change the refresh cadence
# The `:=` form below lets such env vars win while still defaulting when unset.
: "${INSTALL_BASE:=/Applications}"
: "${REFRESH_INTERVAL:=120}"
: "${PATH_PREFIX:=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin}"

list_signing_identities() {
  # The display names of every valid Apple Development identity in the keychain,
  # one per line (e.g. "Apple Development: name (XXXXXXXXXX)").
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*[0-9A-Fa-f]\{40\}[[:space:]]*"\(Apple Development: .*\)"$/\1/p'
}

detect_team_id_from_signature() {
  # The 10-char Team ID, read from a real signature. This is authoritative: the
  # parenthetical in the identity name is the *certificate* id, not the Team ID,
  # so we sign a throwaway probe and read its TeamIdentifier instead.
  local signing_identity="$1"
  local probe_dir="$GENERATED_DIR/signing-probe"
  local probe="$probe_dir/probe"
  local team_id

  mkdir -p "$probe_dir"
  cp /usr/bin/true "$probe"
  codesign --force --sign "$signing_identity" --timestamp=none "$probe" >/dev/null 2>&1 || true
  team_id="$(installed_team_id "$probe")"
  rm -rf "$probe_dir"

  printf '%s\n' "$team_id"
}

installed_team_id() {
  local app_path="$1"
  codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1
}

resolve_signing() {
  # SIGNING_IDENTITY, TEAM_ID and the five App Groups are fully derivable on a
  # machine that can sign at all, so they are auto-detected on every run — no
  # config file needed. The only ambiguity is a keychain with several Apple
  # Development identities; there the user pins one by passing SIGNING_IDENTITY
  # (or TEAM_ID) as an environment variable, which this honours as an override.
  if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    local -a identities
    identities=("${(@f)$(list_signing_identities)}")
    identities=("${(@)identities:#}")  # drop empties
    if (( ${#identities} == 0 )); then
      echo "未找到 Apple Development 签名身份。请先打开 Xcode 用 Apple ID 登录后重试。" >&2
      exit 1
    elif (( ${#identities} > 1 )); then
      echo "检测到多个 Apple Development 签名身份，无法自动判断该用哪个：" >&2
      printf '  - %s\n' "${identities[@]}" >&2
      echo "请重新运行并指定其一，例如：" >&2
      echo "  SIGNING_IDENTITY=\"${identities[1]}\" ./script/install.command" >&2
      echo "（或改用 TEAM_ID=XXXXXXXXXX）" >&2
      exit 1
    fi
    SIGNING_IDENTITY="${identities[1]}"
  fi

  if [[ -z "${TEAM_ID:-}" ]]; then
    TEAM_ID="$(detect_team_id_from_signature "$SIGNING_IDENTITY")"
  fi
  if [[ -z "$TEAM_ID" ]]; then
    echo "无法从签名证书推断 Team ID（签名探针失败）。请重新运行并指定 TEAM_ID=XXXXXXXXXX ./script/install.command" >&2
    exit 1
  fi

  # App Groups are a naming convention keyed by Team ID — never user-facing.
  : "${CODEX_APP_GROUP:="${TEAM_ID}.group.local.codex-token-monitor"}"
  : "${CLAUDE_APP_GROUP:="${TEAM_ID}.group.local.claude-quota-monitor"}"
  : "${GLM_APP_GROUP:="${TEAM_ID}.group.local.glm-quota-monitor"}"
  : "${ANTIGRAVITY_APP_GROUP:="${TEAM_ID}.group.local.antigravity-quota-monitor"}"
  : "${USAGE_APP_GROUP:="${TEAM_ID}.group.local.usage-quota-monitor"}"

  echo "==> Using signing identity: $SIGNING_IDENTITY"
  echo "==> Using Team ID: $TEAM_ID"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

write_runtime_config() {
  # Proxy and remote SSH hosts are runtime data the app edits live, so they live
  # in this shared JSON file (read by both the app and the snapshot tools on
  # every refresh) rather than baked into the binaries. Seed it on first install
  # only — from the shell's proxy environment / any USAGE_REMOTE_HOST env var —
  # and never clobber later in-app edits. Normally left empty and set in the app.
  if [[ -f "$RUNTIME_CONFIG_FILE" ]]; then
    echo "==> Keeping existing runtime config: $RUNTIME_CONFIG_FILE"
    return
  fi

  echo "==> Seeding runtime config: $RUNTIME_CONFIG_FILE"
  mkdir -p "$(dirname "$RUNTIME_CONFIG_FILE")"

  # Prefer HTTPS_PROXY (every quota endpoint is https), then HTTP_PROXY, ALL_PROXY.
  local proxy="${HTTPS_PROXY:-${HTTP_PROXY:-${ALL_PROXY:-}}}"

  local hosts_json="" host
  local -a parts
  parts=("${(@s:,:)${USAGE_REMOTE_HOST:-}}")
  for host in "${parts[@]}"; do
    host="${host// /}"
    [[ -z "$host" ]] && continue
    if [[ -n "$hosts_json" ]]; then hosts_json+=", "; fi
    hosts_json+="\"$(json_escape "$host")\""
  done

  cat > "$RUNTIME_CONFIG_FILE" <<EOF
{
  "proxyURL" : "$(json_escape "$proxy")",
  "remoteHosts" : [$hosts_json]
}
EOF
}

write_coded_sources() {
  # Only the app-group identifiers are signing-bound and therefore baked in here.
  # Proxy and remote-host settings are pure runtime data that the app must be
  # able to change without a rebuild, so they live in the shared runtime config
  # (see write_runtime_config / RuntimeConfig.swift), not in generated sources.
  cat > "$PROJECT_ROOT/Sources/CodexQuotaCore/AppGroupConfig.generated.swift" <<EOF
import Foundation

public enum CodexQuotaAppGroup {
    public static let identifier = "$CODEX_APP_GROUP"
}
EOF

  cat > "$PROJECT_ROOT/Sources/GLMQuotaCore/AppGroupConfig.generated.swift" <<EOF
import Foundation

public enum GLMQuotaAppGroup {
    public static let identifier = "$GLM_APP_GROUP"
}
EOF

  cat > "$PROJECT_ROOT/Sources/ClaudeQuotaCore/AppGroupConfig.generated.swift" <<EOF
import Foundation

public enum ClaudeQuotaAppGroup {
    public static let identifier = "$CLAUDE_APP_GROUP"
}
EOF

  cat > "$PROJECT_ROOT/Sources/AntigravityQuotaCore/AppGroupConfig.generated.swift" <<EOF
import Foundation

public enum AntigravityQuotaAppGroup {
    public static let identifier = "$ANTIGRAVITY_APP_GROUP"
}
EOF

  cat > "$PROJECT_ROOT/Sources/UsageQuotaCore/AppGroupConfig.generated.swift" <<EOF
import Foundation

public enum UsageQuotaAppGroup {
    public static let identifier = "$USAGE_APP_GROUP"
}
EOF
}

write_entitlements() {
  mkdir -p "$GENERATED_DIR"

  cat > "$GENERATED_DIR/CodeQuotaDialXcode.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$CODEX_APP_GROUP</string>
		<string>$CLAUDE_APP_GROUP</string>
		<string>$GLM_APP_GROUP</string>
		<string>$ANTIGRAVITY_APP_GROUP</string>
		<string>$USAGE_APP_GROUP</string>
	</array>
</dict>
</plist>
EOF

  cat > "$GENERATED_DIR/CodeQuotaDialWidgetExtension.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$CODEX_APP_GROUP</string>
		<string>$CLAUDE_APP_GROUP</string>
		<string>$GLM_APP_GROUP</string>
		<string>$ANTIGRAVITY_APP_GROUP</string>
		<string>$USAGE_APP_GROUP</string>
	</array>
</dict>
</plist>
EOF

  cat > "$GENERATED_DIR/RuntimeTool.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$CODEX_APP_GROUP</string>
		<string>$CLAUDE_APP_GROUP</string>
		<string>$GLM_APP_GROUP</string>
		<string>$ANTIGRAVITY_APP_GROUP</string>
		<string>$USAGE_APP_GROUP</string>
	</array>
</dict>
</plist>
EOF
}

write_launch_agent() {
  local label="$1"
  local tool_path="$2"
  local plist_path="$3"

  mkdir -p "$LAUNCH_AGENTS_DIR"

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$tool_path</string>
	</array>
	<key>StartInterval</key>
	<integer>$REFRESH_INTERVAL</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
		<key>USER</key>
		<string>$USER</string>
		<key>LOGNAME</key>
		<string>$LOGNAME</string>
		<key>PATH</key>
		<string>$PATH_PREFIX:/usr/bin:/bin:/usr/sbin:/sbin</string>
EOF

  # Proxy is no longer injected via the launch agent environment: the snapshot
  # tools read the proxy from the shared runtime config and pass it to curl via
  # --proxy, so it can be changed in the app without rewriting these plists.

  cat >> "$plist_path" <<EOF
	</dict>
	<key>StandardOutPath</key>
	<string>$(dirname "$tool_path")/logs/refresh.out.log</string>
	<key>StandardErrorPath</key>
	<string>$(dirname "$tool_path")/logs/refresh.err.log</string>
</dict>
</plist>
EOF
}

write_machine_specific_config() {
  echo "==> Writing machine-specific config"
  write_coded_sources
  write_entitlements
  write_runtime_config
}

clear_build_cache() {
  if [[ -d "$PROJECT_ROOT/.build" ]]; then
    # Snapshot tools are built via SwiftPM. Clearing `.build` avoids stale local
    # package state causing path/cache-related build failures on this machine.
    echo "==> Clearing local build cache"
    rm -rf "$PROJECT_ROOT/.build"
  fi
}

build_app() {
  echo "==> Building app"
  xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -sdk macosx \
    -derivedDataPath "$DERIVED_DATA" \
    CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
    MARKETING_VERSION="$MARKETING_VERSION_VALUE" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

build_snapshot_tools() {
  echo "==> Building snapshot tools"
  BIN_PATH="$(swift build --package-path "$PROJECT_ROOT" -c release --show-bin-path)"
  swift build --package-path "$PROJECT_ROOT" -c release --product CodexQuotaSnapshotTool
  swift build --package-path "$PROJECT_ROOT" -c release --product ClaudeQuotaSnapshotTool
  swift build --package-path "$PROJECT_ROOT" -c release --product GLMQuotaSnapshotTool
  swift build --package-path "$PROJECT_ROOT" -c release --product AntigravityQuotaSnapshotTool
  swift build --package-path "$PROJECT_ROOT" -c release --product UsageQuotaSnapshotTool
}

install_snapshot_tools() {
  echo "==> Installing snapshot tools"
  mkdir -p "$CODEX_RUNTIME_DIR/logs" "$CLAUDE_RUNTIME_DIR/logs" "$GLM_RUNTIME_DIR/logs" "$ANTIGRAVITY_RUNTIME_DIR/logs" "$USAGE_RUNTIME_DIR/logs"
  cp "$BIN_PATH/CodexQuotaSnapshotTool" "$CODEX_TOOL_RUNTIME"
  cp "$BIN_PATH/ClaudeQuotaSnapshotTool" "$CLAUDE_TOOL_RUNTIME"
  cp "$BIN_PATH/GLMQuotaSnapshotTool" "$GLM_TOOL_RUNTIME"
  cp "$BIN_PATH/AntigravityQuotaSnapshotTool" "$ANTIGRAVITY_TOOL_RUNTIME"
  cp "$BIN_PATH/UsageQuotaSnapshotTool" "$USAGE_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$CODEX_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$CLAUDE_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$GLM_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$ANTIGRAVITY_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$USAGE_TOOL_RUNTIME"
}

install_app() {
  echo "==> Installing app to $INSTALL_BASE"
  mkdir -p "$INSTALL_BASE"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_APP"
  cp -R "$BUILD_APP" "$INSTALL_APP"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/CodeQuotaDialWidgetExtension.entitlements" \
    "$INSTALL_APP/Contents/PlugIns/$WIDGET_EXTENSION_NAME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/CodeQuotaDialXcode.entitlements" \
    "$INSTALL_APP"
}

verify_installed_team_id() {
  local signed_team_id
  signed_team_id="$(installed_team_id "$INSTALL_APP")"
  if [[ -n "$signed_team_id" && "$signed_team_id" != "$TEAM_ID" ]]; then
    echo "Installed app TeamIdentifier ($signed_team_id) does not match TEAM_ID ($TEAM_ID)." >&2
    echo "Re-run with the matching identity, e.g. TEAM_ID=$signed_team_id ./script/install.command" >&2
    exit 1
  fi
}

reload_launch_agent() {
  local plist_path="$1"

  launchctl bootout "$USER_GUI_DOMAIN" "$plist_path" >/dev/null 2>&1 || true
  launchctl bootstrap "$USER_GUI_DOMAIN" "$plist_path"
}

install_launch_agents() {
  echo "==> Installing launch agents"
  write_launch_agent "$CODEX_LABEL" "$CODEX_TOOL_RUNTIME" "$CODEX_PLIST"
  write_launch_agent "$CLAUDE_LABEL" "$CLAUDE_TOOL_RUNTIME" "$CLAUDE_PLIST"
  write_launch_agent "$GLM_LABEL" "$GLM_TOOL_RUNTIME" "$GLM_PLIST"
  write_launch_agent "$ANTIGRAVITY_LABEL" "$ANTIGRAVITY_TOOL_RUNTIME" "$ANTIGRAVITY_PLIST"
  write_launch_agent "$USAGE_LABEL" "$USAGE_TOOL_RUNTIME" "$USAGE_PLIST"
  reload_launch_agent "$CODEX_PLIST"
  reload_launch_agent "$CLAUDE_PLIST"
  reload_launch_agent "$GLM_PLIST"
  reload_launch_agent "$ANTIGRAVITY_PLIST"
  reload_launch_agent "$USAGE_PLIST"
}

prime_snapshots() {
  echo "==> Priming fresh snapshots"
  "$CODEX_TOOL_RUNTIME"
  "$CLAUDE_TOOL_RUNTIME"
  "$GLM_TOOL_RUNTIME"
  "$ANTIGRAVITY_TOOL_RUNTIME"
  "$USAGE_TOOL_RUNTIME"
}

refresh_app_registration() {
  echo "==> Refreshing app registration"
  local appex="$INSTALL_APP/Contents/PlugIns/$WIDGET_EXTENSION_NAME"
  # The build leaves a copy of the app under DerivedData. If LaunchServices keeps
  # it registered, WidgetKit can bind a placed widget to that (unsigned) copy and
  # render blank. Drop it so only the installed /Applications copy is launchable.
  "$LSREGISTER" -u "$BUILD_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null
  # Drop the stale widget-extension registration and re-add the new binary, so
  # WidgetKit/PluginKit don't keep serving the previous build from cache.
  pluginkit -r "$appex" >/dev/null 2>&1 || true
  pluginkit -a "$appex" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/com.apple.chrono" >/dev/null 2>&1 || true
  killall WidgetKitExtensionHost >/dev/null 2>&1 || true
  killall -9 chronod >/dev/null 2>&1 || true
  killall iconservicesagent >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
  open "$INSTALL_APP"
}

print_summary() {
  echo
  echo "Done."
  echo "Runtime config (edit in-app): $RUNTIME_CONFIG_FILE"
  echo "App:    $INSTALL_APP"
  echo "Build:  $BUILD_VERSION"
  echo "Codex:  $CODEX_TOOL_RUNTIME"
  echo "Claude: $CLAUDE_TOOL_RUNTIME"
  echo "GLM:    $GLM_TOOL_RUNTIME"
  echo "Antigravity: $ANTIGRAVITY_TOOL_RUNTIME"
  echo "Usage:  $USAGE_TOOL_RUNTIME"
}

main() {
  # No config file: defaults above cover a clean run, signing is auto-detected,
  # and any rare override comes from the environment (e.g. TEAM_ID=...).
  resolve_signing

  INSTALL_APP="$INSTALL_BASE/$APP_NAME.app"

  clear_build_cache
  write_machine_specific_config
  build_app
  build_snapshot_tools
  install_snapshot_tools
  install_app
  verify_installed_team_id
  install_launch_agents
  prime_snapshots
  refresh_app_registration
  print_summary
}

main "$@"
