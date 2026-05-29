#!/system/bin/sh
# shellcheck disable=SC3043  # Android sh supports local

# Standalone Scene connect-probe hiding script.
# Keep this separate from the eBPF loader; it is packaged into service.d.

SCRIPT_DIR=${0%/*}
case "$SCRIPT_DIR" in
    */service.d) MODDIR=${SCRIPT_DIR%/service.d} ;;
    *) MODDIR="$SCRIPT_DIR" ;;
esac

CONF="$MODDIR/hideport.conf"
LOG_FILE="$MODDIR/hide_scene.log"
PIDFILE="/dev/hide_scene_port.pid"

# ── Defaults (overridden by hideport.conf if present) ──
PKG_NAME="com.omarea.vtools"
PORTS="8765 8788"

# ── Source config ──
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    # hideport.conf uses PKG for the variable name
    [ -n "${PKG:-}" ] && PKG_NAME="$PKG"
fi

# ── Logging ──
MAX_LOG_BYTES=65536

log_msg() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown-time')"
    echo "[$ts] [SceneHidePort] $1" >> "$LOG_FILE"
    [ -w /dev/kmsg ] && echo "[SceneHidePort] $1" > /dev/kmsg 2>/dev/null
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
        if [ "$size" -gt "$MAX_LOG_BYTES" ] 2>/dev/null; then
            mv -f "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null
        fi
    fi
}

rotate_log
: >> "$LOG_FILE"
chmod 666 "$LOG_FILE" 2>/dev/null

# ── PID file & signal handling ──
cleanup() {
    log_msg "Received shutdown signal, cleaning up."
    rm -f "$PIDFILE" 2>/dev/null
    exit 0
}
trap cleanup EXIT INT TERM

echo "$$" > "$PIDFILE" 2>/dev/null

# ── Validate MODDIR ──
if [ ! -d "$MODDIR" ]; then
    log_msg "ERROR: MODDIR does not exist: $MODDIR"
    exit 1
fi

# ── Validate PORTS ──
for _p in $PORTS; do
    case "$_p" in
        ''|*[!0-9]*)
            log_msg "ERROR: Invalid port value '$_p' in PORTS. Must be numeric."
            exit 1
            ;;
    esac
done

# ── Check iptables availability ──
HAVE_IPTABLES=0
HAVE_IP6TABLES=0

if command -v iptables >/dev/null 2>&1; then
    HAVE_IPTABLES=1
else
    log_msg "WARNING: iptables not found in PATH."
fi

if command -v ip6tables >/dev/null 2>&1; then
    HAVE_IP6TABLES=1
else
    log_msg "WARNING: ip6tables not found in PATH."
fi

if [ "$HAVE_IPTABLES" = "0" ] && [ "$HAVE_IP6TABLES" = "0" ]; then
    log_msg "ERROR: Neither iptables nor ip6tables is available. Cannot apply rules."
    exit 1
fi

# ── Wait for boot ──
BOOT_TIMEOUT=300
log_msg "Waiting for system boot completion (timeout ${BOOT_TIMEOUT}s)..."
_boot_waited=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    if [ "$_boot_waited" -ge "$BOOT_TIMEOUT" ]; then
        log_msg "ERROR: Timed out waiting for sys.boot_completed after ${BOOT_TIMEOUT}s."
        exit 1
    fi
    _boot_waited=$((_boot_waited + 2))
    sleep 2
done
log_msg "System booted after ~${_boot_waited}s."

# ── Resolve UID ──
log_msg "Extracting UID for $PKG_NAME..."

SCENE_UID=""

# Method 1: stat /data/data/<pkg>
SCENE_UID=$(stat -c %u "/data/data/$PKG_NAME" 2>/dev/null)
if [ -n "$SCENE_UID" ] && echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
    log_msg "UID resolved via stat: $SCENE_UID"
else
    log_msg "UID method 'stat' failed or returned non-numeric: '${SCENE_UID:-}'"
    SCENE_UID=""

    # Method 2: cmd package list packages -U
    SCENE_UID=$(cmd package list packages -U 2>/dev/null | grep "package:$PKG_NAME" | grep -oE 'uid:[0-9]+' | head -n 1 | cut -d':' -f2)
    if [ -n "$SCENE_UID" ] && echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
        log_msg "UID resolved via 'cmd package': $SCENE_UID"
    else
        log_msg "UID method 'cmd package' failed or returned non-numeric: '${SCENE_UID:-}'"
        SCENE_UID=""

        # Method 3: dumpsys package
        SCENE_UID=$(dumpsys package "$PKG_NAME" 2>/dev/null | grep -E '^ *userId=[0-9]+' | head -n 1 | awk -F'=' '{print $2}' | awk '{print $1}')
        if [ -n "$SCENE_UID" ] && echo "$SCENE_UID" | grep -qE '^[0-9]+$'; then
            log_msg "UID resolved via dumpsys: $SCENE_UID"
        else
            log_msg "UID method 'dumpsys' failed or returned non-numeric: '${SCENE_UID:-}'"
            SCENE_UID=""
        fi
    fi
fi

if [ -z "$SCENE_UID" ]; then
    log_msg "ERROR: All UID resolution methods failed for $PKG_NAME. Is the app installed?"
    exit 1
fi

log_msg "Using UID $SCENE_UID for $PKG_NAME. Starting iptables daemon loop..."

# ── Helper: run an iptables/ip6tables command and log on failure ──
run_ipt() {
    local cmd="$1"
    shift
    if ! "$cmd" "$@" 2>/dev/null; then
        log_msg "WARNING: '$cmd $*' failed."
        return 1
    fi
    return 0
}

# ── Daemon loop ──
BOOT_START_TIME=$(date +%s 2>/dev/null || echo 0)
FAST_LOOP_DURATION=120
_loop_errors=0
MAX_CONSECUTIVE_ERRORS=10

while true; do
    NEED_REAPPLY=false

    # Only probe with iptables (skip check if iptables unavailable)
    if [ "$HAVE_IPTABLES" = "1" ]; then
        for PORT in $PORTS; do
            if ! iptables -C OUTPUT -p tcp --dport "$PORT" -m owner --uid-owner 0 -j ACCEPT >/dev/null 2>&1 || \
               ! iptables -C OUTPUT -p tcp --dport "$PORT" -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
                NEED_REAPPLY=true
                break
            fi
        done
    else
        NEED_REAPPLY=true
    fi

    if [ "$NEED_REAPPLY" = "true" ]; then
        log_msg "Iptables rules missing or incomplete. Re-applying for ports: $PORTS"
        _apply_failed=0

        for PORT in $PORTS; do
            for cmd in iptables ip6tables; do
                # Skip unavailable commands
                case "$cmd" in
                    iptables)  [ "$HAVE_IPTABLES" = "0" ] && continue ;;
                    ip6tables) [ "$HAVE_IP6TABLES" = "0" ] && continue ;;
                esac

                # Cleanup old rules
                for iface in "-o lo " ""; do
                    # shellcheck disable=SC2086  # intentional word-splitting on iface
                    while $cmd -D OUTPUT ${iface}-p tcp --dport "$PORT" -m owner --uid-owner 0 -j ACCEPT 2>/dev/null; do :; done
                    # shellcheck disable=SC2086
                    while $cmd -D OUTPUT ${iface}-p tcp --dport "$PORT" -m owner --uid-owner 2000 -j ACCEPT 2>/dev/null; do :; done
                    # shellcheck disable=SC2086
                    while $cmd -D OUTPUT ${iface}-p tcp --dport "$PORT" -m owner --uid-owner "$SCENE_UID" -j ACCEPT 2>/dev/null; do :; done
                    # shellcheck disable=SC2086
                    while $cmd -D OUTPUT ${iface}-p tcp --dport "$PORT" -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
                done

                # Insert rules (in reverse order so they appear correctly at the top)
                run_ipt "$cmd" -I OUTPUT 1 -p tcp --dport "$PORT" -j REJECT --reject-with tcp-reset       || _apply_failed=$((_apply_failed + 1))
                run_ipt "$cmd" -I OUTPUT 1 -p tcp --dport "$PORT" -m owner --uid-owner "$SCENE_UID" -j ACCEPT || _apply_failed=$((_apply_failed + 1))
                run_ipt "$cmd" -I OUTPUT 1 -p tcp --dport "$PORT" -m owner --uid-owner 2000 -j ACCEPT     || _apply_failed=$((_apply_failed + 1))
                run_ipt "$cmd" -I OUTPUT 1 -p tcp --dport "$PORT" -m owner --uid-owner 0 -j ACCEPT        || _apply_failed=$((_apply_failed + 1))
            done
        done

        if [ "$_apply_failed" -gt 0 ]; then
            _loop_errors=$((_loop_errors + 1))
            log_msg "WARNING: $_apply_failed iptables rule insertion(s) failed (consecutive error batch: $_loop_errors/$MAX_CONSECUTIVE_ERRORS)."
            if [ "$_loop_errors" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
                log_msg "ERROR: Reached $MAX_CONSECUTIVE_ERRORS consecutive error batches. Exiting to avoid busy loop."
                exit 1
            fi
        else
            _loop_errors=0
            log_msg "Rules re-applied successfully."
        fi
    else
        _loop_errors=0
    fi

    # Determine sleep interval
    CURRENT_TIME=$(date +%s 2>/dev/null || echo 0)
    ELAPSED=$((CURRENT_TIME - BOOT_START_TIME))

    if [ "$ELAPSED" -lt "$FAST_LOOP_DURATION" ] 2>/dev/null; then
        sleep 2
    else
        sleep 15
    fi
done
