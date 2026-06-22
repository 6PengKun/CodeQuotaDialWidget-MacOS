#!/bin/zsh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="CodeQuotaDialXcode"
# No config file: install is zero-config. INSTALL_BASE can still be overridden
# via the environment (e.g. INSTALL_BASE=~/Applications ./script/install.command).
: "${INSTALL_BASE:=/Applications}"

INSTALL_APP="$INSTALL_BASE/$APP_NAME.app"

if [[ -d "$INSTALL_APP" ]]; then
  echo "==> Existing install found: $INSTALL_APP"
  echo "==> Rebuilding and overwriting app, tools, and launch agents"
else
  echo "==> No existing install found at $INSTALL_APP"
  echo "==> Building and installing fresh app, tools, and launch agents"
fi

exec /bin/zsh "$SCRIPT_DIR/rebuild-local.command"
