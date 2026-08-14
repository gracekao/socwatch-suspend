#!/bin/sh

if [ ! -x /system/bin/getprop ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    HOST_RUNNER="$SCRIPT_DIR/run_alos_socwatch_suspend.sh"

    if ! command -v bash > /dev/null 2>&1; then
        echo "[ERROR] bash is required on the Linux host." >&2
        exit 1
    fi

    if [ ! -f "$HOST_RUNNER" ]; then
        echo "[ERROR] Linux host detected, but the runner was not found:" >&2
        echo "[ERROR] $HOST_RUNNER" >&2
        exit 1
    fi

    echo "[INFO] Linux host detected. Starting the ADB test runner..."
    exec bash "$HOST_RUNNER" "$@"
fi

ENABLE_SOCWATCH=1
SOCWATCH_DIR="/data/socwatch"
SOCWATCH_BIN="$SOCWATCH_DIR/socwatch"
PACKAGE_PATTERN="/data/socwatch_android_NDA_*.tar.gz"
SUBSTATE_RESIDENCIES_PATH="/sys/kernel/debug/pmc_core/substate_residencies"
SLP_S0_PATH="/sys/kernel/debug/pmc_core/slp_s0_residency_usec"
PACKAGE_CSTATE_PATH="/sys/kernel/debug/pmc_core/package_cstate_show"
SUSPEND_SUCCESS_PATH="/sys/power/suspend_stats/success"
SUSPEND_FAIL_PATH="/sys/power/suspend_stats/fail"
RTC_EPOCH_PATH="/sys/class/rtc/rtc0/since_epoch"
POWER_SETUP_MARKER_PATH="/data/socwatch_power_setup_ready"
SOCWATCH_START_MARKER_PATH="/data/socwatch_start_allowed"
WAKEUP_SETUP_READY_MARKER_PATH="/data/socwatch_wakeup_setup_ready"
WAKEUP_ARMED_MARKER_PATH="/data/socwatch_wakeup_armed"
SUSPEND_MARKER_PATH="/data/socwatch_suspend_started"
SOCWATCH_START_TIMEOUT=60

LOOPS=1
WAIT_SEC=10

if [ "$#" -gt "1" ]; then
    echo "Usage: $0 [SUSPEND_TIME_SEC]" >&2
    exit 1
fi

if [ -z "$1" ]; then
    SUSPEND_SEC=60
else
    SUSPEND_SEC=$1
fi

case "$SUSPEND_SEC" in
    ''|*[!0-9]*)
    echo "[ERROR] SUSPEND_TIME_SEC must be a non-negative integer." >&2
        exit 1
        ;;
esac

echo ""
echo "ALOS socwatch suspend stress test"
echo "Total Test Iterations = $LOOPS"

SUSPEND_MSEC=`expr $SUSPEND_SEC \\* 1000`

CYCLES_EXECUTED=0
CYCLES_PASSED=0
CYCLES_FAILED=0
CYCLES_FAILED_IGNORED_WL=0
CYCLES_FAILED_IGNORED_PM=0
CYCLES_FAILED_IGNORED_PW=0
CYCLES_FAILED_PC10=0

PW_SEC=5

print_summary() {
    echo ""
    echo "****** Execution Summary ******"
    echo "Cycles Requested                                       : $LOOPS"
    echo "Cycles Executed                                        : $CYCLES_EXECUTED"
    echo "Cycles Passed                                          : $CYCLES_PASSED"
    echo "Cycles Failed                                          : $CYCLES_FAILED"
    echo "Cycles Failed with PC10 delta 0                        : $CYCLES_FAILED_PC10"
    echo "Cycles Failed but ignored due to WL                    : $CYCLES_FAILED_IGNORED_WL"
    echo "Cycles Failed but ignored due to pm sleep fail         : $CYCLES_FAILED_IGNORED_PM"
    echo "Cycles Failed but ignored due to premature wake < 5sec : $CYCLES_FAILED_IGNORED_PW"
    echo ""
}

cleanup() {
    EXIT_CODE=${1:-0}

    if [ "${SOCWATCH_PID:-0}" -ne "0" ]; then
        socwatch_stop
    fi

    su shell cmd deviceidle unforce > /dev/null 2>&1
    su shell dumpsys battery reset > /dev/null 2>&1
    rm -f "$POWER_SETUP_MARKER_PATH" "$SOCWATCH_START_MARKER_PATH" \
        "$WAKEUP_SETUP_READY_MARKER_PATH" "$WAKEUP_ARMED_MARKER_PATH" "$SUSPEND_MARKER_PATH"

    print_summary

    exit "$EXIT_CODE"
}

debugfs_setup() {
    su root mount -t debugfs debugfs /sys/kernel/debug > /dev/null 2>&1
}

check_required_interfaces() {
    for REQUIRED_PATH in \
        "$SLP_S0_PATH" \
        "$PACKAGE_CSTATE_PATH" \
        "$SUSPEND_SUCCESS_PATH" \
        "$SUSPEND_FAIL_PATH" \
        "$RTC_EPOCH_PATH"
    do
        if ! su root cat "$REQUIRED_PATH" > /dev/null 2>&1; then
            echo "[ERROR] Required DUT interface is not readable: $REQUIRED_PATH"
            exit 1
        fi
    done
}

print_substate_residencies() {
    echo "$1"
    echo "$SUBSTATE_RESIDENCIES_PATH"
    if su root ls "$SUBSTATE_RESIDENCIES_PATH" > /dev/null 2>&1; then
        su root cat "$SUBSTATE_RESIDENCIES_PATH"
    else
        echo "Warning: substate_residencies is not available."
    fi
}

print_suspend_kernel_log() {
    echo ""
    echo "========== Suspend kernel log =========="
    su root dmesg | sed -n "/$1/,/$2/p"
    echo "========== End suspend kernel log =========="
    echo ""
}

write_kernel_marker() {
    su root sh -c "echo '<6>$1' > /dev/kmsg"
}

check_devmem() {
    if [ ! -r /proc/config.gz ]; then
        echo "[ERROR] Cannot verify CONFIG_DEVMEM because /proc/config.gz is not readable."
        echo "[ERROR] SoCWatch requires CONFIG_DEVMEM=y for complete SLP/S0i2 data."
        exit 1
    fi

    DEVMEM_CONFIG=$(zcat /proc/config.gz 2>/dev/null | grep '^CONFIG_DEVMEM=\|^# CONFIG_DEVMEM is not set$')
    if [ "$DEVMEM_CONFIG" != "CONFIG_DEVMEM=y" ]; then
        echo "[ERROR] CONFIG_DEVMEM is not enabled: ${DEVMEM_CONFIG:-unknown}"
        echo "[ERROR] Install a kernel built with CONFIG_DEVMEM=y; otherwise SoCWatch SLP/S0i2 data is incomplete."
        exit 1
    fi

    echo "[INFO] Kernel configuration verified: CONFIG_DEVMEM=y"
}

socwatch_install() {
    echo "[INFO] Socwatch binary not found. Looking for package..."
    LOCAL_PKG=$(ls $PACKAGE_PATTERN 2>/dev/null | head -n 1)

    [ -z "$LOCAL_PKG" ] && {
        echo "[ERROR] No installation package found: $PACKAGE_PATTERN"
        echo "[ERROR] Copy the Socwatch tar.gz package to /data and run this script again."
        exit 1
    }

    su root mkdir -p "$SOCWATCH_DIR" || {
        echo "[ERROR] Failed to create $SOCWATCH_DIR"
        exit 1
    }
    su root rm -rf "$SOCWATCH_DIR"/* || {
        echo "[ERROR] Failed to clean $SOCWATCH_DIR"
        exit 1
    }

    echo "[INFO] Extracting $LOCAL_PKG into $SOCWATCH_DIR"
    su root tar -zxf "$LOCAL_PKG" -C "$SOCWATCH_DIR" || {
        echo "[ERROR] Failed to extract $LOCAL_PKG"
        exit 1
    }

    ENTRY_COUNT=$(ls -1 "$SOCWATCH_DIR" | wc -l)
    if [ "$ENTRY_COUNT" -eq "1" ]; then
        TOPDIR=$(ls "$SOCWATCH_DIR")
        if [ -d "$SOCWATCH_DIR/$TOPDIR" ]; then
            echo "[INFO] Flatten top directory: $TOPDIR"
            su root mv "$SOCWATCH_DIR/$TOPDIR"/* "$SOCWATCH_DIR"/ || {
                echo "[ERROR] Failed to flatten $SOCWATCH_DIR/$TOPDIR"
                exit 1
            }
            su root rmdir "$SOCWATCH_DIR/$TOPDIR" || {
                echo "[ERROR] Failed to remove $SOCWATCH_DIR/$TOPDIR"
                exit 1
            }
        fi
    fi

    su root chmod -R 755 "$SOCWATCH_DIR" || {
        echo "[ERROR] Failed to set permissions on $SOCWATCH_DIR"
        exit 1
    }

    # sanity check
    if [ ! -x "$SOCWATCH_BIN" ]; then
        echo "[ERROR] socwatch binary not found after install"
        ls -l "$SOCWATCH_DIR"
        exit 1
    fi

    echo "[INFO] Socwatch installed correctly."
}

socwatch_setup() {
    if [ ! -x "$SOCWATCH_BIN" ]; then
        echo "[INFO] Socwatch is not installed at $SOCWATCH_BIN."
        socwatch_install
    else
        echo "[INFO] Socwatch already installed. Starting test directly."
    fi

    su shell mkdir -p /data/local/tmp/socwatch_reports/ || {
        echo "[ERROR] Failed to create the Socwatch report directory."
        exit 1
    }
    su root rm -rf /data/local/tmp/socwatch_reports/* || {
        echo "[ERROR] Failed to clean the Socwatch report directory."
        exit 1
    }

    su root insmod /vendor_dlkm/lib/modules/cpuid.ko > /dev/null 2>&1
    su root insmod /vendor_dlkm/lib/modules/msr.ko > /dev/null 2>&1
    su root modprobe -d /vendor_dlkm/lib/modules intel_telemetry_pltdrv.ko > /dev/null 2>&1
    # su root insmod /vendor_dlkm/lib/modules/socwatch2_16.ko > /dev/null 2>&1

    SOCWATCH_PID=0
}

socwatch_start() {
    if [ -x "$SOCWATCH_BIN" ]
    then
	echo "Staring Socwatch..."
    SOCWATCH_SEC=`expr $SUSPEND_SEC + 1`
	ORIG_DIR=$(pwd)
	cd "$SOCWATCH_DIR"
	source setup_socwatch_env.sh &> /dev/null
	SOCWATCH_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        SOCWATCH_OUTPUT="/data/local/tmp/socwatch_reports/socwatch_$SOCWATCH_TIMESTAMP"
        echo "Socwatch report: $SOCWATCH_OUTPUT.csv"
	./socwatch -m -f xhci -f chipset-all -f cpu -f cpu-cstate -f cpu-hw \
		-f cpu-pstate -f device -f display -f pcie -f power -f sstate -f sys -f cpu-cstate \
        -f cpu-hw -f npu -f gfx -f device -f ipu -f memss -f npu-dstate -f partial-slp-state \
        -f xhci \
		-o "$SOCWATCH_OUTPUT" > /data/local/tmp/socwatch_output 2>&1 &
	SOCWATCH_PID=$!
	until grep -q "Started infinite seconds data collection" /data/local/tmp/socwatch_output; do
           sleep 0.1
        done
	echo "Started Socwatch..."
	rm -f /data/local/tmp/socwatch_output
	cd "$ORIG_DIR"
    fi
}

socwatch_stop() {
    if [ "$SOCWATCH_PID" -ne "0" ]
    then
	echo "Stoping Socwatch..."
    SOCWATCH_STOP_PID=$SOCWATCH_PID
        kill -SIGINT "$SOCWATCH_STOP_PID"
    SOCWATCH_STOP_WAIT=30
    while kill -0 "$SOCWATCH_STOP_PID" 2>/dev/null
    do
        sleep 1
        SOCWATCH_STOP_WAIT=`expr $SOCWATCH_STOP_WAIT - 1`
        if [ "$SOCWATCH_STOP_WAIT" -eq "0" ]; then
            echo "[ERROR] SocWatch did not stop and flush its report within 30 seconds."
            kill -KILL "$SOCWATCH_STOP_PID" 2>/dev/null
            SOCWATCH_PID=0
            return 1
        fi
    done
    echo "Socwatch stopped and report flush completed."
	SOCWATCH_PID=0
    fi
}

trap cleanup SIGTERM SIGINT

debugfs_setup
check_devmem

if [ "$ENABLE_SOCWATCH" -eq "1" ]; then
    socwatch_setup
fi

for i in `seq 1 $LOOPS`
do
    echo "-------------------------------"
    echo "Current iteration # $i"
    SLP_S0_B=$(su root cat "$SLP_S0_PATH")
    echo "S0ix Counter before suspend = $SLP_S0_B"
    print_substate_residencies "Substate residencies before suspend:"

    SLP_PC10_B=$(su root cat "$PACKAGE_CSTATE_PATH" | grep C10 | awk -F': ' '{print $2}')
    echo "PC10 Counter before suspend = $SLP_PC10_B"

    SUSPEND_CNTR=$(su shell cat "$SUSPEND_SUCCESS_PATH")
    echo "stat suspend counter before suspend = $SUSPEND_CNTR"

    CMD_BATT_UNPLUG=$(su shell dumpsys battery unplug)
    echo "battery unplug result: $CMD_BATT_UNPLUG"
    CMD_POWER_STAYON=$(su shell cmd power stayon false)
    echo "power stayon false result: $CMD_POWER_STAYON"

    echo "ready" > "$POWER_SETUP_MARKER_PATH"
    echo "Waiting for host force-idle setup..."
    SOCWATCH_START_WAIT=$SOCWATCH_START_TIMEOUT
    while [ ! -f "$SOCWATCH_START_MARKER_PATH" ]
    do
        sleep 1
        SOCWATCH_START_WAIT=`expr $SOCWATCH_START_WAIT - 1`
        if [ "$SOCWATCH_START_WAIT" -eq "0" ]; then
            echo "[ERROR] Host did not complete force-idle setup within $SOCWATCH_START_TIMEOUT seconds."
            cleanup 1
        fi
    done
    echo "Host force-idle setup completed."

    SUS_SUCC_CNT_PREV=$(su shell cat "$SUSPEND_SUCCESS_PATH")
    SUS_FAIL_CNT_PREV=$(su shell cat "$SUSPEND_FAIL_PATH")

    if [ "$ENABLE_SOCWATCH" -eq "1" ]; then
        socwatch_start
    fi

    EPOCH_TIME_B=$(su root cat "$RTC_EPOCH_PATH")
    echo "ready" > "$WAKEUP_SETUP_READY_MARKER_PATH"
    echo "Waiting for host to confirm the RTC wakeup alarm..."
    SOCWATCH_START_WAIT=$SOCWATCH_START_TIMEOUT
    while [ ! -f "$WAKEUP_ARMED_MARKER_PATH" ]
    do
        sleep 1
        SOCWATCH_START_WAIT=`expr $SOCWATCH_START_WAIT - 1`
        if [ "$SOCWATCH_START_WAIT" -eq "0" ]; then
            echo "[ERROR] Host did not confirm the RTC wakeup alarm within $SOCWATCH_START_TIMEOUT seconds."
            cleanup 1
        fi
    done
    echo "Host confirmed the RTC wakeup alarm."

    KERNEL_MARKER_ID="socwatch-$$-$i"
    KERNEL_START_MARKER="==== start to enter suspend ($KERNEL_MARKER_ID) ===="
    KERNEL_FINISH_MARKER="====== finish suspend ($KERNEL_MARKER_ID) ======"
    write_kernel_marker "$KERNEL_START_MARKER"
    echo "ready" > "$SUSPEND_MARKER_PATH"

    if [ "$SUSPEND_SEC" -eq "0" ]; then
        SLEEP_WAIT_CNTR=-1
    else
        SLEEP_WAIT_CNTR=`expr $SUSPEND_SEC + 30`
    fi
    LAST_REPORTED_FAIL_DELTA=0
    echo -n "Waiting for SocWatch collection duration."
    while :
    do
	sleep 1
    if [ "$SLEEP_WAIT_CNTR" -gt "0" ]; then
        SLEEP_WAIT_CNTR=`expr $SLEEP_WAIT_CNTR - 1`
    fi

        SUS_SUCC_CNT=$(su shell cat "$SUSPEND_SUCCESS_PATH")
        SUS_FAIL_CNT=$(su shell cat "$SUSPEND_FAIL_PATH")
        SLP_S0_CURRENT=$(su root cat "$SLP_S0_PATH")
    EPOCH_TIME_CURRENT=$(su root cat "$RTC_EPOCH_PATH")

	SUS_SUCC_DELTA=`expr $SUS_SUCC_CNT - $SUS_SUCC_CNT_PREV`
	SUS_FAIL_DELTA=`expr $SUS_FAIL_CNT - $SUS_FAIL_CNT_PREV`
    EPOCH_TIME_CURRENT_DELTA=`expr $EPOCH_TIME_CURRENT - $EPOCH_TIME_B`

    if [ "$SUSPEND_SEC" -eq "0" -a "$SLP_S0_CURRENT" -gt "$SLP_S0_B" ]
	then
	    break
	fi

    if [ "$SUSPEND_SEC" -gt "0" -a "$EPOCH_TIME_CURRENT_DELTA" -ge "$SUSPEND_SEC" ]
    then
        break
    fi

    if [ "$SUS_FAIL_DELTA" -gt "$LAST_REPORTED_FAIL_DELTA" ]
    then
        echo ""
        echo "Warning: suspend failed $SUS_FAIL_DELTA time(s); waiting for an S0ix retry."
        LAST_REPORTED_FAIL_DELTA=$SUS_FAIL_DELTA
        echo -n "Waiting for SocWatch collection duration."
    fi

	if [ "$SLEEP_WAIT_CNTR" -eq "0" ]
	then
	    break
	fi

	echo -n "."
    done
    echo ""

    if [ "$ENABLE_SOCWATCH" -eq "1" ]; then
        echo "RTC wakeup reached after $EPOCH_TIME_CURRENT_DELTA second(s); stopping SocWatch immediately."
        socwatch_stop || cleanup 1
    fi

    write_kernel_marker "$KERNEL_FINISH_MARKER"
    print_suspend_kernel_log "$KERNEL_START_MARKER" "$KERNEL_FINISH_MARKER"

    CYCLES_EXECUTED=`expr $CYCLES_EXECUTED + 1`

    SLP_PC10_A=$(su root cat "$PACKAGE_CSTATE_PATH" | grep C10 | awk -F': ' '{print $2}')

    SUSPEND_CNTR=$(su shell cat "$SUSPEND_SUCCESS_PATH")
    echo "stat suspend counter after suspend = $SUSPEND_CNTR"

    EPOCH_TIME_A=$(su root cat "$RTC_EPOCH_PATH")

    sleep 1
    SLP_S0_A=$(su root cat "$SLP_S0_PATH")
    echo "S0ix Counter after suspend = $SLP_S0_A"
    print_substate_residencies "Substate residencies after suspend:"

    echo "PC10 Counter after suspend = $SLP_PC10_A"

    EPOCH_TIME_DELTA=`expr $EPOCH_TIME_A - $EPOCH_TIME_B`
    echo "EPOCH Time Delta: $EPOCH_TIME_DELTA"

    SLP_S0_DELTA=`expr $SLP_S0_A - $SLP_S0_B`
    echo "S0ix Delta: $SLP_S0_DELTA"

    SLP_PC10_DELTA=`expr $SLP_PC10_A - $SLP_PC10_B`
    echo "PC10 Delta: $SLP_PC10_DELTA"

    if [ "$SLP_S0_DELTA" -eq "0" ]
    then
        echo "s0ix Failed"
	CYCLES_FAILED=`expr $CYCLES_FAILED + 1`

	if [ "$SLEEP_WAIT_CNTR" -eq "0" -o "$SUS_SUCC_DELTA" -eq "0" ]
	then
	    CYCLES_FAILED_IGNORED_PM=`expr $CYCLES_FAILED_IGNORED_PM + 1`
	    echo "Continue the suspend stress cycles as \"cmd power sleep\" ignored"
	elif [ "$EPOCH_TIME_DELTA" -lt "$PW_SEC" ]
	then
	    CYCLES_FAILED_IGNORED_PW=`expr $CYCLES_FAILED_IGNORED_PW + 1`
	    echo "Continue the suspend stress cycles as \"Premature Wake < 5sec\" ignored"
	else
	    WAKE_LOCK_SIZE=$(dumpsys power | grep "Wake Locks" | awk -F'=' '{print $2}')
	    echo "wake lock size = $WAKE_LOCK_SIZE"
	    WAKE_LOCK_DETAIL=$(dumpsys power | grep WAKE_LOCK)
	    echo $WAKE_LOCK_DETAIL

	    if [ "$SLP_PC10_DELTA" -eq "0" ]
	    then
	        CYCLES_FAILED_PC10=`expr $CYCLES_FAILED_PC10 + 1`
	    fi
            break;
	fi
    else
        echo "s0ix Passed"
	CYCLES_PASSED=`expr $CYCLES_PASSED + 1`
    fi

    echo "Cool down time $WAIT_SEC Seconds"
    sleep $WAIT_SEC
done

cleanup 0
