# ALOS SoCWatch Suspend Test

Host-side automation for running one ALOS suspend/S0ix cycle while collecting an Intel SoCWatch report.

## What is included

- `alos-socwatch-suspend_v2.sh`: DUT test logic and the host entry point.
- `run_alos_socwatch_suspend.sh`: Linux host runner that coordinates ADB, suspend, wakeup, logging, and report download.

Intel SoCWatch binaries and packages are not included. Obtain SoCWatch through an authorized Intel distribution channel and comply with its license terms.

## Requirements

### Linux host

- Bash
- Android Debug Bridge (`adb`) in `PATH`
- GNU `timeout`
- One ALOS DUT connected over USB or TCP ADB

### DUT

- Root access through `su root`
- A readable `/proc/config.gz` containing `CONFIG_DEVMEM=y`
- Readable PMC and suspend interfaces under `/sys/kernel/debug/pmc_core` and `/sys/power/suspend_stats`
- An authorized `socwatch_android_NDA_*.tar.gz` package when SoCWatch is not already installed at `/data/socwatch/socwatch`

The test stops before SoCWatch starts if `CONFIG_DEVMEM=y` cannot be verified. Running without DEVMEM can produce incomplete reports that omit SLP/S0i2 residency, blocking reasons, and related low-level telemetry.

## Setup

Clone the repository and make the entry point executable:

```bash
git clone https://github.com/gracekao/socwatch-suspend.git
cd socwatch-suspend
chmod +x alos-socwatch-suspend_v2.sh run_alos_socwatch_suspend.sh
```

If SoCWatch is not installed on the DUT, place exactly one authorized package beside the scripts:

```text
socwatch-suspend/
|-- alos-socwatch-suspend_v2.sh
|-- run_alos_socwatch_suspend.sh
`-- socwatch_android_NDA_<version>.tar.gz
```

Do not commit or redistribute the package through this repository.

## Usage

Run one 60-second suspend cycle:

```bash
./alos-socwatch-suspend_v2.sh 60
```

The default duration is 60 seconds when the argument is omitted:

```bash
./alos-socwatch-suspend_v2.sh
```

Use manual wake mode by passing `0`. Press Enter on the host after physically waking the DUT when necessary:

```bash
./alos-socwatch-suspend_v2.sh 0
```

For TCP ADB, pass the target as the second argument:

```bash
./alos-socwatch-suspend_v2.sh 60 DUT_IP:ADB_PORT
```

You can also set `ADB_TARGET`:

```bash
ADB_TARGET=DUT_IP:ADB_PORT ./alos-socwatch-suspend_v2.sh 60
```

When several local packages exist, select one explicitly:

```bash
SOCWATCH_PACKAGE=./socwatch_android_NDA_<version>.tar.gz \
  ./alos-socwatch-suspend_v2.sh 60
```

## Execution flow

For a fixed-duration run, the host and DUT use marker handshakes to enforce this order:

1. Verify `CONFIG_DEVMEM=y`, prepare SoCWatch, and configure the DUT for battery operation.
2. Enter deep device idle with `cmd deviceidle force-idle deep`.
3. Start SoCWatch and wait until it reports that infinite collection has started.
4. Schedule the RTC wakeup with `cmd power wakeup <milliseconds> --restore-wakelocks` and require a successful return code.
5. Notify the DUT that the wakeup alarm is armed.
6. Acknowledge suspend readiness and run `cmd power sleep --disable-wakelocks`.
7. Stop ADB traffic while the DUT is suspended.
8. Stop SoCWatch immediately after the RTC wakeup and wait for the report to flush.
9. Collect the focused suspend kernel log, full kernel log, full logcat, and SoCWatch reports.

The duration argument controls the RTC wakeup delay. Because SoCWatch starts before the alarm is armed, the complete suspend window is recorded and the CSV collection duration can be slightly longer than the requested delay due to alarm setup and suspend-entry overhead.

The cycle passes only when `/sys/kernel/debug/pmc_core/slp_s0_residency_usec` increases. Suspend failures are logged while the DUT continues waiting for a later S0ix attempt within the collection window.

## Results

The runner creates a timestamped directory such as:

```text
socwatch_reports_20260811_120000/
```

It contains the SoCWatch CSV report, host execution log, full kernel log, and full logcat captured after the test.

Typical artifacts include:

```text
socwatch_YYYYMMDD_HHMMSS.csv
socwatch_YYYYMMDD_HHMMSS.sw2
execution_YYYYMMDD_HHMMSS.log
kernel_full_YYYYMMDD_HHMMSS.log
logcat_full_YYYYMMDD_HHMMSS.log
```

A successful run ends with:

```text
[PASS] All 1 cycle(s) passed.
```

## Troubleshooting

Verify ADB and DUT root access before running the test:

```bash
adb devices
adb shell "su root id"
```

Verify the required kernel option:

```bash
adb shell "su root zcat /proc/config.gz | grep '^CONFIG_DEVMEM=y$'"
```

If the output is `# CONFIG_DEVMEM is not set`, install a kernel built with `CONFIG_DEVMEM=y`. The script intentionally refuses to continue because the generated SoCWatch report would be incomplete.

The DUT-side execution log is available at `/data/asst.log`. Generated reports and logs may contain platform-specific information; review them before sharing.

## License

The scripts and documentation in this repository are licensed under the MIT License. Intel SoCWatch and other third-party components retain their own licenses and are not covered by this repository's license.
