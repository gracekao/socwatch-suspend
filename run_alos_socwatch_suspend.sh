#!/usr/bin/env bash

set -uo pipefail

RUNNER_VERSION="2026.08.14-socwatch-before-alarm-v5"
SUSPEND_SEC="${1:-60}"
ADB_TARGET="${2:-${ADB_TARGET:-}}"
CYCLES=1
WAIT_SEC=10
ADB_POLL_TIMEOUT_SEC="${ADB_POLL_TIMEOUT_SEC:-5}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_DUT_SCRIPT="$SCRIPT_DIR/alos-socwatch-suspend_v2.sh"
REMOTE_DUT_SCRIPT="/data/alos-socwatch-suspend.sh"
REMOTE_STAGE_DIR="/data/local/tmp"
REMOTE_LOG="/data/asst.log"
REMOTE_POWER_SETUP_MARKER="/data/socwatch_power_setup_ready"
REMOTE_SOCWATCH_START_MARKER="/data/socwatch_start_allowed"
REMOTE_WAKEUP_SETUP_READY_MARKER="/data/socwatch_wakeup_setup_ready"
REMOTE_WAKEUP_ARMED_MARKER="/data/socwatch_wakeup_armed"
REMOTE_SUSPEND_MARKER="/data/socwatch_suspend_started"
REMOTE_REPORT_DIR="/data/local/tmp/socwatch_reports"
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${REPORT_DIR:-$SCRIPT_DIR/socwatch_reports_$RUN_TIMESTAMP}"
EXECUTION_LOG="$REPORT_DIR/execution_$RUN_TIMESTAMP.log"
FULL_KERNEL_LOG="$REPORT_DIR/kernel_full_$RUN_TIMESTAMP.log"
FULL_LOGCAT_LOG="$REPORT_DIR/logcat_full_$RUN_TIMESTAMP.log"
DIAGNOSTICS_COLLECTED=0
ADB_BIN="$(command -v adb || true)"

[ -n "$ADB_BIN" ] || {
    echo "[ERROR] adb is not installed or not in PATH." >&2
    exit 1
}

if [ -z "$ADB_TARGET" ]; then
    ADB_TARGET="$($ADB_BIN devices | awk '$1 ~ /:/ && $2 == "device" { print $1; exit }')"
fi

adb() {
    if [ -n "$ADB_TARGET" ]; then
        "$ADB_BIN" -s "$ADB_TARGET" "$@"
    else
        "$ADB_BIN" "$@"
    fi
}

adb_connect() {
    [ -n "$ADB_TARGET" ] || return 0
    timeout "$ADB_POLL_TIMEOUT_SEC" "$ADB_BIN" connect "$ADB_TARGET"
}

mkdir -p "$REPORT_DIR" || {
    echo "[ERROR] Failed to create $REPORT_DIR" >&2
    exit 1
}
exec > >(tee -a "$EXECUTION_LOG") 2>&1

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

adb_poll() {
    if [ -n "$ADB_TARGET" ]; then
        timeout "$ADB_POLL_TIMEOUT_SEC" "$ADB_BIN" -s "$ADB_TARGET" "$@"
    else
        timeout "$ADB_POLL_TIMEOUT_SEC" "$ADB_BIN" "$@"
    fi
}

collect_diagnostics() {
    [ "$DIAGNOSTICS_COLLECTED" -eq 0 ] || return
    DIAGNOSTICS_COLLECTED=1

    echo "[INFO] Saving full kernel log: $FULL_KERNEL_LOG"
    adb exec-out su root dmesg > "$FULL_KERNEL_LOG" 2>/dev/null \
        || echo "[WARN] Failed to save the full kernel log."
    echo "[INFO] Saving full logcat: $FULL_LOGCAT_LOG"
    adb exec-out logcat -d > "$FULL_LOGCAT_LOG" 2>/dev/null \
        || echo "[WARN] Failed to save the full logcat."
}

if [ "$#" -gt 2 ]; then
    die "Usage: $0 [SUSPEND_TIME_SEC] [ADB_HOST:PORT]"
fi

case "$SUSPEND_SEC" in
    ''|*[!0-9]*) die "SUSPEND_TIME_SEC must be a non-negative integer." ;;
esac

MANUAL_WAKE=0
if [ "$SUSPEND_SEC" -eq 0 ]; then
    MANUAL_WAKE=1
    [ -t 0 ] || die "Manual wake mode requires an interactive terminal."
fi
echo "[INFO] Host runner: $RUNNER_VERSION"
if [ "$MANUAL_WAKE" -eq 1 ]; then
    echo "[INFO] Mode: manual wake (no suspend duration or automatic wake alarm)"
fi
SUSPEND_MSEC=$((SUSPEND_SEC * 1000))
TIMEOUT_SEC="${TIMEOUT_SEC:-$((CYCLES * (SUSPEND_SEC + WAIT_SEC + 300)))}"
command -v timeout >/dev/null 2>&1 || die "timeout is not installed or not in PATH."
[ -f "$LOCAL_DUT_SCRIPT" ] || die "Missing $LOCAL_DUT_SCRIPT"

echo "[INFO] Waiting for DUT..."
if [ -n "$ADB_TARGET" ]; then
    echo "[INFO] Using TCP ADB target: $ADB_TARGET"
    ADB_STATE=""
    for ADB_CONNECT_ATTEMPT in 1 2; do
        echo "[INFO] Trying ($ADB_CONNECT_ATTEMPT/2): adb connect $ADB_TARGET"
        ADB_CONNECT_OUTPUT="$(adb_connect 2>&1)"
        ADB_STATE="$(adb_poll get-state 2>/dev/null | tr -d '\r' || true)"
        if [ "$ADB_STATE" = "device" ]; then
            echo "[INFO] TCP ADB connection established: $ADB_TARGET"
            break
        fi
        [ "$ADB_CONNECT_ATTEMPT" -eq 2 ] || sleep 2
    done
    [ "$ADB_STATE" = "device" ] \
        || die "${ADB_CONNECT_OUTPUT:-Failed to connect to $ADB_TARGET}"
else
    adb wait-for-device || die "DUT is not available."
fi
trap collect_diagnostics EXIT

if adb shell "su root test -x /data/socwatch/socwatch" >/dev/null 2>&1; then
    echo "[INFO] Socwatch is already installed on DUT."
else
    if [ -n "${SOCWATCH_PACKAGE:-}" ]; then
        LOCAL_PACKAGE="$SOCWATCH_PACKAGE"
        [ -f "$LOCAL_PACKAGE" ] || die "SOCWATCH_PACKAGE does not exist: $LOCAL_PACKAGE"
    else
        mapfile -t PACKAGES < <(compgen -G "$SCRIPT_DIR/socwatch_android_NDA_*.tar.gz")
        [ "${#PACKAGES[@]}" -gt 0 ] || die "No socwatch_android_NDA_*.tar.gz package found in $SCRIPT_DIR"
        [ "${#PACKAGES[@]}" -eq 1 ] || die "Multiple Socwatch packages found. Set SOCWATCH_PACKAGE to select one."
        LOCAL_PACKAGE="${PACKAGES[0]}"
    fi

    PACKAGE_NAME="$(basename "$LOCAL_PACKAGE")"
    STAGED_PACKAGE="$REMOTE_STAGE_DIR/$PACKAGE_NAME"
    echo "[INFO] Uploading $PACKAGE_NAME..."
    adb push "$LOCAL_PACKAGE" "$STAGED_PACKAGE" || die "Failed to upload Socwatch package."
    adb shell "su root mv '$STAGED_PACKAGE' '/data/$PACKAGE_NAME'" \
        || die "Failed to move Socwatch package into /data as root."
fi

echo "[INFO] Uploading DUT test script..."
STAGED_DUT_SCRIPT="$REMOTE_STAGE_DIR/$(basename "$REMOTE_DUT_SCRIPT")"
adb push "$LOCAL_DUT_SCRIPT" "$STAGED_DUT_SCRIPT" || die "Failed to upload DUT test script."
adb shell "su root cp '$STAGED_DUT_SCRIPT' '$REMOTE_DUT_SCRIPT' && su root chmod +x '$REMOTE_DUT_SCRIPT'" \
    || die "Failed to install DUT test script as root."
adb shell "su root rm -f $REMOTE_LOG $REMOTE_POWER_SETUP_MARKER $REMOTE_SOCWATCH_START_MARKER $REMOTE_WAKEUP_SETUP_READY_MARKER $REMOTE_WAKEUP_ARMED_MARKER $REMOTE_SUSPEND_MARKER" \
    || die "Failed to remove previous DUT state."

if [ "$MANUAL_WAKE" -eq 1 ]; then
    echo "[INFO] Starting one suspend cycle in manual wake mode..."
else
    echo "[INFO] Starting one suspend cycle, duration $SUSPEND_SEC second(s)..."
fi
adb shell "su root sh -c 'nohup $REMOTE_DUT_SCRIPT $SUSPEND_SEC > $REMOTE_LOG 2>&1 &'" \
    || die "Failed to start DUT test script."
echo "[INFO] DUT log: adb shell cat $REMOTE_LOG"

echo "[INFO] Waiting for DUT battery and power setup..."
POWER_SETUP_DEADLINE=$((SECONDS + 120))
while [ "$SECONDS" -lt "$POWER_SETUP_DEADLINE" ]; do
    if adb shell "su root grep -q '\[ERROR\]\|^Error:' '$REMOTE_LOG'" >/dev/null 2>&1; then
        adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
        die "DUT setup failed before battery and power setup completed."
    fi
    if adb shell "su root test -f '$REMOTE_POWER_SETUP_MARKER'" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! adb shell "su root test -f '$REMOTE_POWER_SETUP_MARKER'" >/dev/null 2>&1; then
    adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
    die "DUT did not complete battery and power setup within 120 seconds."
fi
echo "[INFO] DUT power setup is ready. Entering deep device idle before SocWatch starts..."
DOZE_OUTPUT="$(adb shell cmd deviceidle force-idle deep 2>&1)"
DOZE_RC=$?
echo "[INFO] force-idle result ($DOZE_RC): $DOZE_OUTPUT"
[ "$DOZE_RC" -eq 0 ] || die "Failed to enter deep device idle."
adb shell "su root touch '$REMOTE_SOCWATCH_START_MARKER'" \
    || die "Failed to allow DUT SocWatch startup."

echo "[INFO] Waiting for DUT to start SocWatch before RTC wakeup setup..."
SUSPEND_READY_DEADLINE=$((SECONDS + 120))
while [ "$SECONDS" -lt "$SUSPEND_READY_DEADLINE" ]; do
    if adb shell "su root grep -q '\[ERROR\]\|^Error:' '$REMOTE_LOG'" >/dev/null 2>&1; then
        adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
        die "DUT failed before SocWatch startup completed."
    fi
    if adb shell "su root test -f '$REMOTE_WAKEUP_SETUP_READY_MARKER'" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! adb shell "su root test -f '$REMOTE_WAKEUP_SETUP_READY_MARKER'" >/dev/null 2>&1; then
    adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
    die "DUT did not start SocWatch within 120 seconds."
fi
echo "[INFO] SocWatch is running; DUT is ready for RTC wakeup setup."

if [ "$MANUAL_WAKE" -eq 0 ]; then
    echo "[INFO] Scheduling wakeup in $SUSPEND_SEC second(s)..."
    WAKEUP_OUTPUT="$(adb shell cmd power wakeup "$SUSPEND_MSEC" --restore-wakelocks 2>&1)"
    WAKEUP_RC=$?
    echo "[INFO] wakeup result ($WAKEUP_RC): $WAKEUP_OUTPUT"
    [ "$WAKEUP_RC" -eq 0 ] || die "Failed to schedule DUT wakeup."
    echo "[INFO] RTC wakeup alarm confirmed for $SUSPEND_SEC second(s)."
else
    echo "[INFO] Automatic wakeup is disabled."
fi

adb shell "su root touch '$REMOTE_WAKEUP_ARMED_MARKER'" \
    || die "Failed to notify DUT that the wakeup alarm is armed."
echo "[INFO] Waiting for DUT to acknowledge the wakeup alarm and suspend readiness..."
SUSPEND_READY_DEADLINE=$((SECONDS + 120))
while [ "$SECONDS" -lt "$SUSPEND_READY_DEADLINE" ]; do
    if adb shell "su root grep -q '\[ERROR\]\|^Error:' '$REMOTE_LOG'" >/dev/null 2>&1; then
        adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
        die "DUT failed before suspend readiness acknowledgement."
    fi
    if adb shell "su root test -f '$REMOTE_SUSPEND_MARKER'" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! adb shell "su root test -f '$REMOTE_SUSPEND_MARKER'" >/dev/null 2>&1; then
    adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
    die "DUT did not acknowledge suspend readiness within 120 seconds."
fi
echo "[INFO] DUT acknowledged the wakeup alarm and is ready to suspend."

echo "[INFO] Issuing DUT suspend command..."
SLEEP_OUTPUT="$(adb shell cmd power sleep --disable-wakelocks 2>&1)"
SLEEP_RC=$?
echo "[INFO] power sleep result ($SLEEP_RC): $SLEEP_OUTPUT"
echo "[INFO] Suspend command dispatched; stopping ADB traffic now."

SUSPEND_START_SECONDS=$SECONDS
if [ "$MANUAL_WAKE" -eq 1 ]; then
    echo "[INFO] Press Enter to attempt an ADB wakeup and finish recording."
    echo "[INFO] With TCP ADB, wake the DUT physically first if its network is suspended."
    read -r
    echo "[INFO] Manual finish requested; attempting KEYCODE_WAKEUP..."
    if ! adb_poll shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; then
        echo "[WARN] DUT is not reachable through ADB. Wake it physically; waiting for reconnect..."
    fi
else
    ADB_QUIET_SEC="${ADB_QUIET_SEC:-$((SUSPEND_SEC + 10))}"
    echo "[INFO] Leaving ADB idle for $ADB_QUIET_SEC seconds so it does not block suspend..."
    sleep "$ADB_QUIET_SEC"
fi
DEADLINE=$((SECONDS + TIMEOUT_SEC))

LAST_DUT_STATUS=""
DUT_CONNECTION_STATUS="online"
DUT_ERROR_FOUND=0
NEXT_OFFLINE_REPORT=10
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    ADB_STATE="$(adb_poll get-state 2>&1 | tr -d '\r' || true)"
    if [ "$ADB_STATE" != "device" ] && [ -n "$ADB_TARGET" ]; then
        adb_connect >/dev/null 2>&1 || true
        ADB_STATE="$(adb_poll get-state 2>&1 | tr -d '\r' || true)"
    fi
    if [ "$ADB_STATE" = "device" ]; then
        if [ "$DUT_CONNECTION_STATUS" != "online" ]; then
            SUSPEND_ELAPSED=$((SECONDS - SUSPEND_START_SECONDS))
            echo "[INFO] DUT ADB connection restored approximately $SUSPEND_ELAPSED seconds after suspend was dispatched."
            DUT_CONNECTION_STATUS="online"
        fi

        if [ "$DUT_ERROR_FOUND" -eq 1 ]; then
                if adb shell "su root grep -q '\[ERROR\]\|^Error:' '$REMOTE_LOG'" >/dev/null 2>&1 && \
                    adb shell "su root cat '$REMOTE_LOG'"; then
                die "Test setup failed on DUT."
            fi
            DUT_ERROR_FOUND=0
        fi

        DUT_STATUS="$(adb_poll shell "su root tail -n 1 '$REMOTE_LOG'" 2>/dev/null | tr -d '\r' || true)"
        if [ -n "$DUT_STATUS" ] && [ "$DUT_STATUS" != "$LAST_DUT_STATUS" ]; then
            echo "[DUT] $DUT_STATUS"
            LAST_DUT_STATUS="$DUT_STATUS"
        fi

        if adb_poll shell "su root grep -q '^Cycles Passed' '$REMOTE_LOG'" >/dev/null 2>&1; then
            break
        fi
        if adb_poll shell "su root grep -q '\[ERROR\]\|^Error:' '$REMOTE_LOG'" >/dev/null 2>&1; then
            DUT_ERROR_FOUND=1
        fi
    else
        if [ "$DUT_CONNECTION_STATUS" != "offline" ]; then
            SUSPEND_ELAPSED=$((SECONDS - SUSPEND_START_SECONDS))
            NEXT_OFFLINE_REPORT=$((SUSPEND_ELAPSED + 10))
            if [ "$MANUAL_WAKE" -eq 1 ]; then
                echo "[INFO] DUT ADB is unavailable; wake the DUT physically and the test will continue."
            else
                echo "[INFO] DUT ADB is temporarily unavailable; suspend started, waiting about $SUSPEND_SEC seconds for resume..."
            fi
            echo "[INFO] Approximately $SUSPEND_ELAPSED seconds have elapsed since suspend was dispatched."
            echo "[INFO] adb get-state: ${ADB_STATE:-timed out with no output}"
            DUT_CONNECTION_STATUS="offline"
        else
            SUSPEND_ELAPSED=$((SECONDS - SUSPEND_START_SECONDS))
            if [ "$SUSPEND_ELAPSED" -ge "$NEXT_OFFLINE_REPORT" ]; then
                echo "[INFO] DUT is still suspended/offline: approximately $SUSPEND_ELAPSED seconds since suspend was dispatched."
                echo "[INFO] adb get-state: ${ADB_STATE:-timed out with no output}"
                NEXT_OFFLINE_REPORT=$((NEXT_OFFLINE_REPORT + 10))
            fi
        fi
    fi
    sleep 3
done

if ! adb shell "su root grep -q '^Cycles Passed' '$REMOTE_LOG'" >/dev/null 2>&1; then
    adb shell "su root cat '$REMOTE_LOG'" 2>/dev/null || true
    DUT_LOG_FILE="$REPORT_DIR/dut_$RUN_TIMESTAMP.log"
    adb exec-out su root cat "$REMOTE_LOG" > "$DUT_LOG_FILE" 2>/dev/null || true
    adb pull "$REMOTE_REPORT_DIR/." "$REPORT_DIR/" >/dev/null 2>&1 || true
    collect_diagnostics
    die "Timed out after $TIMEOUT_SEC seconds. DUT log: $DUT_LOG_FILE"
fi

adb shell "su root cat '$REMOTE_LOG'"
PASSED="$(adb shell "su root awk -F: '/^Cycles Passed/{gsub(/ /, \"\", \$2); print \$2}' '$REMOTE_LOG'" | tr -d '\r')"
REPORT_EXISTS=1
adb shell "ls $REMOTE_REPORT_DIR/socwatch_*.csv >/dev/null 2>&1" || REPORT_EXISTS=0

REPORT_PULL_OK=1
adb pull "$REMOTE_REPORT_DIR/." "$REPORT_DIR/" || REPORT_PULL_OK=0
collect_diagnostics

[ "$PASSED" = "$CYCLES" ] || die "Expected $CYCLES passed cycle(s), got ${PASSED:-0}. Reports: $REPORT_DIR"
[ "$REPORT_EXISTS" -eq 1 ] || die "Test passed, but no socwatch_YYYYMMDD_HHMMSS.csv report was generated."
[ "$REPORT_PULL_OK" -eq 1 ] || die "Test passed, but report download failed."

echo "[PASS] All $CYCLES cycle(s) passed."
echo "[INFO] Reports: $REPORT_DIR"
echo "[INFO] Execution log: $EXECUTION_LOG"
echo "[INFO] Full kernel log: $FULL_KERNEL_LOG"
echo "[INFO] Full logcat: $FULL_LOGCAT_LOG"
