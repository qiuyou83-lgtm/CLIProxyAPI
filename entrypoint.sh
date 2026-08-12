#!/bin/sh
# entrypoint.sh - startup self-repair wrapper
#
# Background: upstream added a `tls` config block. When config.yaml contains
# tls.enable=true but cert/key are empty, the server exits at startup with
# "failed to start HTTPS server: tls.cert or tls.key is empty".
# This wrapper checks config.yaml before launching the app: if tls is enabled
# but the cert/key are missing, it flips enable back to false so the service
# can boot (on Zeabur, HTTPS is terminated by the platform gateway; the app
# itself only needs plain HTTP). Configs with complete cert/key are untouched.

log() { echo "[entrypoint] $*"; }

# Locate config.yaml: prefer explicit -config/--config argument, then common mount paths.
CONFIG_FILE=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-config" ] || [ "$prev" = "--config" ]; then
        CONFIG_FILE="$a"
        break
    fi
    case "$a" in
        -config=*) CONFIG_FILE="${a#-config=}"; break ;;
        --config=*) CONFIG_FILE="${a#--config=}"; break ;;
    esac
    prev="$a"
done
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE=""
    for f in /CLIProxyAPI/config.yaml /data/config.yaml /home/*/config.yaml /app/config.yaml /workspace/config.yaml; do
        if [ -f "$f" ]; then CONFIG_FILE="$f"; break; fi
    done
fi

if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    NEEDS_FIX="$(awk '
        BEGIN { intls = 0; en = 0; cert = "__unset"; key = "__unset" }
        /^tls:[ \t]*(#.*)?$/ { intls = 1; next }
        intls == 1 {
            if ($0 ~ /^[^ \t#]/) { intls = 0 }
            else {
                if ($0 ~ /^[ \t]*enable:[ \t]*true/) { en = 1 }
                if ($0 ~ /^[ \t]*cert:/) { v = $0; sub(/^[ \t]*cert:[ \t]*/, "", v); sub(/[ \t]+(#.*)?$/, "", v); cert = v }
                if ($0 ~ /^[ \t]*key:/) { v = $0; sub(/^[ \t]*key:[ \t]*/, "", v); sub(/[ \t]+(#.*)?$/, "", v); key = v }
            }
        }
        END {
            ce = (cert == "" || cert == "__unset" || cert == "\"\"" || cert == "''")
            ke = (key == "" || key == "__unset" || key == "\"\"" || key == "''")
            if (en == 1 && (ce || ke)) print "1"; else print "0"
        }
    ' "$CONFIG_FILE" 2>/dev/null || echo 0)"

    if [ "$NEEDS_FIX" = "1" ]; then
        log "config $CONFIG_FILE has tls.enable=true with empty cert/key (boot blocker). Flipping to enable: false"
        if awk '
            BEGIN { intls = 0 }
            /^tls:[ \t]*(#.*)?$/ { intls = 1; print; next }
            intls == 1 && /^[^ \t#]/ { intls = 0 }
            intls == 1 && /^[ \t]*enable:[ \t]*true/ {
                indent = $0; sub(/enable:.*$/, "", indent); print indent "enable: false"; next
            }
            { print }
        ' "$CONFIG_FILE" > "$CONFIG_FILE.entrypoint.tmp"; then
            mv "$CONFIG_FILE.entrypoint.tmp" "$CONFIG_FILE" && log "config repaired successfully"
        else
            rm -f "$CONFIG_FILE.entrypoint.tmp"
            log "WARNING: config repair failed, continuing anyway"
        fi
    else
        log "tls config check passed ($CONFIG_FILE), no repair needed"
    fi
else
    log "no config.yaml found, skipping tls check"
fi

exec "$@"