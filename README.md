# intel_max_boost

Apply max-boost MSR tuning on Intel Xeon Gold (Skylake-SP).

> **WARNING: writing MSRs can crash, overheat, or permanently damage hardware.**
> Requires an unlocked-MSR BIOS (pre-Plundervolt-mitigation). Use at your own risk.
> Tested on Dell 7820, Xeon gold 6138

## What it does

`intel_max_boost.sh`:

1. Sets the CPU governor to `performance` (required so `0x199` / `PERF_CTL` sticks).
2. Writes 13 MSRs to all CPUs via `wrmsr -a`.
3. Verifies every MSR with `rdmsr -p <cpu>`. All are strict except `0x64F`,
   whose upper 16 bits are HW-dynamic — only the lower `c000` is checked.

Notes:

- `0x610` is package-scope; writing it once per CPU is harmless.
- Pairs well with the Intel Undervolt utility for core/cache/uncore undervolting.

## Requirements

- Root (`sudo`)
- `msr-tools` (`wrmsr`, `rdmsr`)
- `modprobe`, `lscpu` (usually preinstalled), optional `cpupower`
- Unlocked MSR BIOS

Install on Debian/Ubuntu:

```sh
sudo apt install msr-tools linux-cpupower
```

## Usage

```sh
sudo ./intel_max_boost.sh --help
sudo ./intel_max_boost.sh --dry-run        # print what would be done
sudo ./intel_max_boost.sh                  # real run, logs to /var/log/msr-apply.log
sudo ./intel_max_boost.sh --log-file ""    # log to stdout only
```

To re-apply at boot, add a systemd unit or cron `@reboot` entry calling the script
with an absolute path (not shipped in this minimal release).

## MSR values

| MSR   | Value            | Verify |
| ----- | ---------------- | ------ |
| 0x48  | 0x0              | strict |
| 0x4E  | 0x2              | strict |
| 0x199 | 0x2500           | strict |
| 0x1A0 | 0x850089         | strict |
| 0x1A4 | 0x2              | strict |
| 0x1B0 | 0x0              | strict |
| 0x1B2 | 0x0              | strict |
| 0x38D | 0x330            | strict |
| 0x38F | 0x70000000f      | strict |
| 0x3F1 | 0x0              | strict |
| 0x610 | 0x28b1800fe8b18  | strict |
| 0x64F | 0xc000c000       | lower16 `c000` only |
| 0x770 | 0x0              | strict |

## License

MIT — see [LICENSE](LICENSE).
