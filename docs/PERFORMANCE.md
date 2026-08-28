# Obelisk — Performance

## The rule this file exists to enforce

**CI never publishes a number it did not measure.** GitHub-hosted runners expose no
`/dev/kvm`, so every QEMU boot in CI runs under TCG software emulation, roughly an order
of magnitude slower than hardware. A boot time measured there is not a boot time; it is
an emulator benchmark. Publishing it as a product number would be dishonest and would
also be useless, because it would move with runner load rather than with our work.

The budget is therefore split, and every row below states where its number came from.

| Measured in CI | Measured by the maintainer on real hardware |
|---|---|
| ISO size | Boot to SDDM |
| Idle RAM in a fixed QEMU configuration | Boot to usable desktop |
| Relative regression against the previous build | Suspend and resume |

## Targets

| Metric | Target | Measured on | Source |
|---|---|---|---|
| Idle RAM, Wayland, 60 s after login | ≤ 700 MB | 4 GB VM, 2 vCPU | CI |
| Boot to SDDM | ≤ 12 s | SATA SSD | maintainer, real hardware |
| Boot to usable desktop | ≤ 20 s | SATA SSD | maintainer, real hardware |
| ISO size | ≤ 3.5 GB (3584 MiB) | — | CI |
| Minimum install | 4 GB RAM, x86-64-v2 CPU (2009+), 30 GB | — | — |

A missed target is reported with a proposed cut. It is never lowered to fit.

## Measurements

### ISO size

CI writes `out/iso-size.txt` immediately after `mkarchiso` finishes, before the boot test
runs, and publishes the figure to the run summary. It is included in the `obelisk-iso`
artifact, so the number survives even when a later step fails.

| Date | Commit | Phase | ISO size | Ceiling | Headroom | Notes |
|---|---|---|---|---|---|---|
| 2026-08-28 | `042e6ab` (run #7) | 1 | **1002 MiB** (1050705920 bytes) | 3584 MiB | 2582 MiB | First recorded size. Text-console medium: base, `linux` and `linux-lts`, firmware, both boot loaders, filesystem tools, NetworkManager, Arabic locales. 28% of budget used. |

At 1002 MiB the Phase 1 medium uses 28% of the budget and leaves 2582 MiB of headroom.
That is a comfortable starting position, but it is also the easy case: this medium has no
desktop at all.

The number that matters arrives in Phase 2, when Plasma 6 lands, and again in Phase 4 with
Calamares. As a rough sighting shot, a KDE live medium from a comparable Arch derivative
runs 2.2-2.4 GB, which would put us near 70% of the ceiling with the compatibility layer
and the VM stack still deliberately off the image under decision D1. The headroom is real
but it is not spare.

### Idle RAM

Not yet measured. Requires a desktop session, which arrives in Phase 2. The harness is
`scripts/benchmark.sh`, delivered in Phase 3.

### Boot time

Not yet measured, and deliberately not measured in CI. See the rule above.

CI run #6 timed out after 600 s under TCG without reaching a shell, and that number means
nothing about boot performance. It did expose a real defect in the test rather than in the
image: the kernel had no `console=ttyS0`, so the serial log stayed empty and there was no
way to distinguish a slow boot from a hung one. `build-iso.sh --serial-console` and the
progress tracking in `scripts/test-qemu.sh` exist because of that run.

## Recording procedure

Every release records its measured numbers here, with the hardware named. A row without a
stated measurement source is incomplete and should be treated as missing.

For maintainer measurements:

```sh
systemd-analyze                 # firmware, loader, kernel, userspace
systemd-analyze blame | head -20
systemd-analyze critical-chain
```

State the machine: CPU, RAM, and whether the disk is SATA SSD or NVMe. A boot time
without a named disk is not a measurement.
