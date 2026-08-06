#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"
load_config

export DISPLAY="${DISPLAY:-:0}"

attempts="${PULSAR_DISPLAY_VERIFY_ATTEMPTS:-30}"
delay="${PULSAR_DISPLAY_VERIFY_DELAY:-0.5}"
require_touch="${PULSAR_REQUIRE_TOUCH:-0}"

state_file="$PULSAR_DATA_DIR/displays.env"

unset \
    PULSAR_SETTINGS_OUTPUT \
    PULSAR_ROLE_UI_OUTPUT \
    PULSAR_ROLE_DISPLAY_OUTPUT \
    PULSAR_ROLE_AR1_OUTPUT \
    PULSAR_ROLE_AR2_OUTPUT

load_display_state() {
    local key value

    [[ -s "$state_file" ]] || return 1

    while IFS='=' read -r key value; do
        value="${value%$'\r'}"

        case "$key" in
            PULSAR_SETTINGS_OUTPUT|\
            PULSAR_ROLE_UI_OUTPUT|\
            PULSAR_ROLE_DISPLAY_OUTPUT|\
            PULSAR_ROLE_AR1_OUTPUT|\
            PULSAR_ROLE_AR2_OUTPUT)
                if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                    value="${value:1:${#value}-2}"
                elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                    value="${value:1:${#value}-2}"
                fi

                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$state_file"
}

output_active() {
    local wanted="$1"

    [[ -n "$wanted" ]] || return 0

    xrandr --query 2>/dev/null |
    awk -v wanted="$wanted" '
        $1 == wanted && $2 == "connected" {
            for (i = 3; i <= NF && i <= 7; i++) {
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
                    found = 1
                }
            }
        }

        END {
            exit found ? 0 : 1
        }
    '
}

bootloader_present() {
    local dev vendor product

    for dev in /sys/bus/usb/devices/*; do
        [[ -r "$dev/idVendor" ]] || continue
        [[ -r "$dev/idProduct" ]] || continue

        vendor="$(cat "$dev/idVendor")"
        product="$(cat "$dev/idProduct")"

        if [[ "${vendor,,}:${product,,}" == "4348:55e0" ]]; then
            return 0
        fi
    done

    return 1
}

touch_device_present() {
    xinput --list --name-only 2>/dev/null |
    grep -Eiv \
        'virtual core|xwayland|keyboard|mouse|trackpad|touchpad' |
    grep -Eiq \
        'touch|touchscreen|USB2IIC_CTP_CONTROL|wch\.cn|ctp|goodix|elan|eeti|ilitek|wave|hid.*touch'
}

configured_displays_ready() {
    local ui output

    load_display_state || return 1

    ui="${PULSAR_SETTINGS_OUTPUT:-${PULSAR_ROLE_UI_OUTPUT:-}}"

    output_active "$ui" || return 1

    for output in \
        "${PULSAR_ROLE_DISPLAY_OUTPUT:-}" \
        "${PULSAR_ROLE_AR1_OUTPUT:-}" \
        "${PULSAR_ROLE_AR2_OUTPUT:-}"; do

        [[ -n "$output" ]] || continue
        output_active "$output" || return 1
    done
}

for attempt in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 1 \
        "http://${PULSAR_HOST:-127.0.0.1}:${PULSAR_PORT:-4173}/health" \
        >/dev/null 2>&1; then

        timeout 8 \
            "$PULSAR_ROOT/core/scripts/configure-displays.sh" \
            >>"$PULSAR_LOG_FILE" 2>&1 || true

        # فقط اجرای یک‌باره؛ هرگز --watch در verifier اجرا نشود.
        if ! bootloader_present; then
            timeout 4 \
                "$PULSAR_ROOT/core/scripts/configure-touch.sh" \
                >>"$PULSAR_DATA_DIR/touch.log" 2>&1 || true
        fi

        if configured_displays_ready; then
            if [[ "$require_touch" != "1" ]] ||
               touch_device_present; then

                echo "Pulsar bounded verification: OK"

                grep -E \
                    '^(PULSAR_SETTINGS_OUTPUT|PULSAR_ROLE_(UI|DISPLAY|AR1|AR2)_(OUTPUT|CONNECTED|POSITION|PHYSICAL_MODE)|PULSAR_VIEWER_ACTIVE_(OUTPUTS|COUNT)|PULSAR_VIEWER_CANVAS_GEOMETRY)=' \
                    "$state_file" 2>/dev/null || true

                xrandr --query 2>/dev/null |
                grep -E \
                    '^(HDMI-2|DP-1-1|HDMI-1-0) connected' || true

                if bootloader_present; then
                    echo "Touch: unavailable — WCH controller is in 4348:55e0 bootloader mode."
                elif touch_device_present; then
                    echo "Touch: detected."
                else
                    echo "Touch: no XInput touchscreen detected."
                fi

                exit 0
            fi
        fi
    fi

    sleep "$delay"
done

echo "ERROR: Pulsar bounded verification failed." >&2

echo "--- health ---" >&2
curl -fsS --max-time 2 \
    "http://${PULSAR_HOST:-127.0.0.1}:${PULSAR_PORT:-4173}/health" \
    >&2 || true

echo >&2
echo "--- displays.env ---" >&2
cat "$state_file" >&2 2>/dev/null || true

echo "--- xrandr ---" >&2
xrandr --query >&2 2>/dev/null || true

echo "--- recent Pulsar log ---" >&2
tail -n 150 "$PULSAR_LOG_FILE" >&2 2>/dev/null || true

exit 1
