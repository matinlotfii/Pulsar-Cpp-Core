#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

export DISPLAY="${DISPLAY:-:0}"

provider_names() {
  timeout 3 xrandr --listproviders 2>/dev/null |
    sed -n 's/.*name:\([^[:space:]]\+\).*/\1/p'
}

provider_exists() {
  local wanted="$1"
  provider_names | grep -Fxq "$wanted"
}

# Reverse PRIME exposes the RTX scanout connectors inside the Intel X screen.
# Re-applying the provider link is idempotent and wakes newly hot-plugged DP
# connectors without restarting Xorg or the camera service.
if provider_exists modesetting && provider_exists NVIDIA-G0; then
  timeout 4 xrandr \
    --setprovideroutputsource modesetting NVIDIA-G0 \
    >/dev/null 2>&1 || true
fi

# Querying NVIDIA display devices helps the proprietary driver finish a DP
# link-training/EDID refresh after cable insertion. This is best-effort only.
if command -v nvidia-settings >/dev/null 2>&1; then
  timeout 4 nvidia-settings \
    --ctrl-display="$DISPLAY" \
    --query=dpys \
    >/dev/null 2>&1 || true
fi

# Force XRandR to refresh its output cache after the provider operation.
timeout 4 xrandr --query >/dev/null 2>&1 || true
