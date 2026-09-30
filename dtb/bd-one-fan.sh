#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="bd-one-fan.service"
INSTALL_SCRIPT="/usr/local/bin/bd-one-fan-daemon.sh"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"

log() {
    echo "[bd-one-fan-install] $*"
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run as root:"
        echo "  bash /www/bd-one-fan.sh"
        exit 1
    fi
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1" >&2
        exit 1
    }
}

write_daemon() {
cat > "${INSTALL_SCRIPT}" <<'EOF_DAEMON'
#!/usr/bin/env bash
set -euo pipefail

GPIO=135
INTERVAL=3
DT_BASE="/sys/firmware/devicetree/base/thermal-zones"
GPIO_DIR="/sys/class/gpio/gpio${GPIO}"

log() {
    echo "[bd-one-fan] $*"
}

cleanup() {
    if [ -d "$GPIO_DIR" ]; then
        echo 0 > "$GPIO_DIR/value" 2>/dev/null || true
        echo "$GPIO" > /sys/class/gpio/unexport 2>/dev/null || true
    fi
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

be32() {
    od -An -t u4 --endian=big -N 4 "$1" 2>/dev/null | tr -d '[:space:]'
}

get_active_trip() {
    local zone="$1" trip_root trip type temp hyst
    trip_root="${DT_BASE}/${zone}/trips"

    [ -d "$trip_root" ] || return 1

    for trip in "${trip_root}"/*; do
        [ -d "$trip" ] || continue
        type="$(tr -d '\0' < "${trip}/type" 2>/dev/null || true)"
        [ "$type" = "active" ] || continue

        temp="$(be32 "${trip}/temperature" || true)"
        hyst="$(be32 "${trip}/hysteresis" || true)"

        [ -n "$temp" ] || continue
        [ -n "$hyst" ] || hyst=0

        printf '%s %s\n' "$temp" "$hyst"
        return 0
    done

    return 1
}

get_zone_temp() {
    local want="$1" z type
    for z in /sys/class/thermal/thermal_zone*; do
        [ -r "${z}/type" ] || continue
        type="$(cat "${z}/type" 2>/dev/null || true)"
        [ "$type" = "$want" ] || continue
        cat "${z}/temp"
        return 0
    done
    return 1
}

export_gpio() {
    if [ ! -d "$GPIO_DIR" ]; then
        echo "$GPIO" > /sys/class/gpio/export 2>/dev/null || true
        sleep 0.2
    fi

    [ -d "$GPIO_DIR" ] || {
        log "ERROR: gpio${GPIO} not available"
        exit 1
    }

    echo out > "${GPIO_DIR}/direction" 2>/dev/null || true
    echo 0 > "${GPIO_DIR}/value" 2>/dev/null || true
}

read -r CPU_ON CPU_HYST <<EOF_CPU
$(get_active_trip cpu-thermal)
EOF_CPU

read -r GPU_ON GPU_HYST <<EOF_GPU
$(get_active_trip gpu-thermal)
EOF_GPU

[ -n "${CPU_ON:-}" ] || { log "ERROR: failed to read cpu-thermal active trip"; exit 1; }
[ -n "${GPU_ON:-}" ] || { log "ERROR: failed to read gpu-thermal active trip"; exit 1; }

CPU_OFF=$((CPU_ON - CPU_HYST))
GPU_OFF=$((GPU_ON - GPU_HYST))

export_gpio

FAN=0

log "CPU: ON ${CPU_ON}mC / OFF ${CPU_OFF}mC"
log "GPU: ON ${GPU_ON}mC / OFF ${GPU_OFF}mC"
log "GPIO: ${GPIO}, interval: ${INTERVAL}s"

while true; do
    CPU_TEMP="$(get_zone_temp cpu-thermal || echo 0)"
    GPU_TEMP="$(get_zone_temp gpu-thermal || echo 0)"

    if [ "$FAN" -eq 0 ] && { [ "$CPU_TEMP" -ge "$CPU_ON" ] || [ "$GPU_TEMP" -ge "$GPU_ON" ]; }; then
        echo 1 > "${GPIO_DIR}/value"
        FAN=1
        log "ON: CPU=${CPU_TEMP}mC GPU=${GPU_TEMP}mC"
    elif [ "$FAN" -eq 1 ] && [ "$CPU_TEMP" -le "$CPU_OFF" ] && [ "$GPU_TEMP" -le "$GPU_OFF" ]; then
        echo 0 > "${GPIO_DIR}/value"
        FAN=0
        log "OFF: CPU=${CPU_TEMP}mC GPU=${GPU_TEMP}mC"
    fi

    sleep "$INTERVAL"
done
EOF_DAEMON

    chmod 755 "${INSTALL_SCRIPT}"
}

write_unit() {
cat > "${UNIT_FILE}" <<EOF_UNIT
[Unit]
Description=BenDian One GPIO fan control
After=multi-user.target
ConditionPathExists=/sys/class/thermal

[Service]
Type=simple
ExecStart=${INSTALL_SCRIPT}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT

    chmod 644 "${UNIT_FILE}"
}

main() {
    need_root
    check_cmd systemctl
    check_cmd od
    [ -d /sys/class/thermal ] || { echo "/sys/class/thermal not found"; exit 1; }

    log "Installing daemon..."
    write_daemon

    log "Writing systemd unit..."
    write_unit

    log "Reloading systemd..."
    systemctl daemon-reload

    log "Enabling and starting service..."
    systemctl enable --now "${SERVICE_NAME}"

    log "Install complete."
    echo
    systemctl --no-pager --full status "${SERVICE_NAME}" || true
    echo
    journalctl -u "${SERVICE_NAME}" -n 20 --no-pager || true
}

main "$@"
