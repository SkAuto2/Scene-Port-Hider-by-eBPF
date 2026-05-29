#!/system/bin/sh

for PIDFILE in /dev/hideport_loader.pid /dev/hide_scene_port.pid; do
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null
        fi
        rm -f "$PIDFILE"
    fi
done

rm -rf /dev/hideport_loader.lock
