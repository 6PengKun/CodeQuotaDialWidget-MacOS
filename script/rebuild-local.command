#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/local-config.env"
CONFIG_TEMPLATE="$PROJECT_ROOT/local-config.example.env"
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
CODEX_TOOL_RUNTIME="$CODEX_RUNTIME_DIR/CodexQuotaSnapshotTool"
CLAUDE_TOOL_RUNTIME="$CLAUDE_RUNTIME_DIR/ClaudeQuotaSnapshotTool"
GLM_TOOL_RUNTIME="$GLM_RUNTIME_DIR/GLMQuotaSnapshotTool"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CODEX_LABEL="local.codex-quota-dial.refresh"
CLAUDE_LABEL="local.claude-quota-dial.refresh"
GLM_LABEL="local.glm-quota-dial.refresh"
CODEX_PLIST="$LAUNCH_AGENTS_DIR/$CODEX_LABEL.plist"
CLAUDE_PLIST="$LAUNCH_AGENTS_DIR/$CLAUDE_LABEL.plist"
GLM_PLIST="$LAUNCH_AGENTS_DIR/$GLM_LABEL.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
USER_GUI_DOMAIN="gui/$(id -u)"
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
MARKETING_VERSION_VALUE="1.0"

detect_team_id_from_certificate() {
  local team_id
  team_id="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -n 1)"
  if [[ -z "$team_id" ]]; then
    team_id="$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -n 1)"
  fi
  printf '%s\n' "$team_id"
}

detect_signing_identity() {
  local team_id="${1:-}"
  local identity
  if [[ -n "$team_id" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n "s/.*\"\\(Apple Development: .*(${team_id})\\)\"/\\1/p" | head -n 1)"
  fi
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -n 1)"
  fi
  if [[ -z "$identity" ]]; then
    echo "Failed to detect an Apple Development signing identity. Open Xcode once, sign in with an Apple ID, then retry." >&2
    exit 1
  fi
  printf '%s\n' "$identity"
}

detect_team_id_from_signature() {
  local signing_identity="$1"
  local probe_dir="$GENERATED_DIR/signing-probe"
  local probe="$probe_dir/probe"
  local team_id

  mkdir -p "$probe_dir"
  cp /usr/bin/true "$probe"
  codesign --force --sign "$signing_identity" --timestamp=none "$probe" >/dev/null
  team_id="$(installed_team_id "$probe")"
  rm -rf "$probe_dir"

  printf '%s\n' "$team_id"
}

installed_team_id() {
  local app_path="$1"
  codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1
}

ensure_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    return
  fi

  local certificate_team_id
  local team_id
  local signing_identity
  certificate_team_id="$(detect_team_id_from_certificate)"
  signing_identity="$(detect_signing_identity "$certificate_team_id")"
  team_id="$(detect_team_id_from_signature "$signing_identity")"
  if [[ -z "$team_id" ]]; then
    team_id="$certificate_team_id"
  fi
  if [[ -z "$team_id" ]]; then
    echo "Failed to detect a Team ID from the signing certificate. Open Xcode once, sign in with an Apple ID, then retry." >&2
    exit 1
  fi
  sed \
    -e "s#__TEAM_ID__#$team_id#g" \
    -e "s#__SIGNING_IDENTITY__#$signing_identity#g" \
    "$CONFIG_TEMPLATE" > "$CONFIG_FILE"
  echo "Created $CONFIG_FILE"
}

write_coded_sources() {
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

  if [[ "$label" == "$CODEX_LABEL" ]]; then
    cat >> "$plist_path" <<EOF
		<key>CODEX_HOME</key>
		<string>$CODEX_HOME</string>
EOF
  fi

  if [[ -n "${HTTP_PROXY:-}" ]]; then
    cat >> "$plist_path" <<EOF
		<key>HTTP_PROXY</key>
		<string>$HTTP_PROXY</string>
EOF
  fi

  if [[ -n "${HTTPS_PROXY:-}" ]]; then
    cat >> "$plist_path" <<EOF
		<key>HTTPS_PROXY</key>
		<string>$HTTPS_PROXY</string>
EOF
  fi

  if [[ -n "${ALL_PROXY:-}" ]]; then
    cat >> "$plist_path" <<EOF
		<key>ALL_PROXY</key>
		<string>$ALL_PROXY</string>
EOF
  fi

  if [[ -n "${NO_PROXY:-}" ]]; then
    cat >> "$plist_path" <<EOF
		<key>NO_PROXY</key>
		<string>$NO_PROXY</string>
EOF
  fi

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

require_config() {
  : "${TEAM_ID:?TEAM_ID is required}"
  : "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"
  : "${CODEX_APP_GROUP:?CODEX_APP_GROUP is required}"
  : "${CLAUDE_APP_GROUP:?CLAUDE_APP_GROUP is required}"
  : "${GLM_APP_GROUP:?GLM_APP_GROUP is required}"
  : "${INSTALL_BASE:?INSTALL_BASE is required}"
  : "${REFRESH_INTERVAL:?REFRESH_INTERVAL is required}"
  : "${CODEX_HOME:?CODEX_HOME is required}"
  : "${PATH_PREFIX:?PATH_PREFIX is required}"
}

write_machine_specific_config() {
  echo "==> Writing machine-specific config"
  write_coded_sources
  write_entitlements
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
}

install_snapshot_tools() {
  echo "==> Installing snapshot tools"
  mkdir -p "$CODEX_RUNTIME_DIR/logs" "$CLAUDE_RUNTIME_DIR/logs" "$GLM_RUNTIME_DIR/logs"
  cp "$BIN_PATH/CodexQuotaSnapshotTool" "$CODEX_TOOL_RUNTIME"
  cp "$BIN_PATH/ClaudeQuotaSnapshotTool" "$CLAUDE_TOOL_RUNTIME"
  cp "$BIN_PATH/GLMQuotaSnapshotTool" "$GLM_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$CODEX_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$CLAUDE_TOOL_RUNTIME"
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$GENERATED_DIR/RuntimeTool.entitlements" "$GLM_TOOL_RUNTIME"
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
    echo "Update $CONFIG_FILE so TEAM_ID matches the signing certificate, then rerun script/install.command." >&2
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
  reload_launch_agent "$CODEX_PLIST"
  reload_launch_agent "$CLAUDE_PLIST"
  reload_launch_agent "$GLM_PLIST"
}

prime_snapshots() {
  echo "==> Priming fresh snapshots"
  "$CODEX_TOOL_RUNTIME"
  "$CLAUDE_TOOL_RUNTIME"
  "$GLM_TOOL_RUNTIME"
}

refresh_app_registration() {
  echo "==> Refreshing app registration"
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null
  rm -rf "$HOME/Library/Caches/com.apple.chrono" >/dev/null 2>&1 || true
  killall WidgetKitExtensionHost >/dev/null 2>&1 || true
  killall chronod >/dev/null 2>&1 || true
  killall iconservicesagent >/dev/null 2>&1 || true
  killall Dock >/dev/null 2>&1 || true
  open "$INSTALL_APP"
}

print_summary() {
  echo
  echo "Done."
  echo "Config: $CONFIG_FILE"
  echo "App:    $INSTALL_APP"
  echo "Build:  $BUILD_VERSION"
  echo "Codex:  $CODEX_TOOL_RUNTIME"
  echo "Claude: $CLAUDE_TOOL_RUNTIME"
  echo "GLM:    $GLM_TOOL_RUNTIME"
}

main() {
  ensure_config
  source "$CONFIG_FILE"
  : "${CLAUDE_APP_GROUP:="${TEAM_ID}.group.local.claude-quota-monitor"}"
  require_config

  INSTALL_APP="$INSTALL_BASE/$APP_NAME.app"

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
