# Running upstream test-suites

The unpins release gate is **upstream tests executing against the artifact on each target OS**, not smoke (`<bin> --version`). This document is the OS-level policy: how test execution maps to each target, what's pre-installed on each environment, and the open items in the cross-OS harness.

## How test execution maps to platforms

Test execution differs by OS because the build context differs:

| OS | Build context | Test execution |
| --- | --- | --- |
| Linux (x86_64, aarch64) | `pkgsStatic` (musl) — native on GHA Linux runner | Inline with `nix build`, via `doCheck = true` (or `doInstallCheck` when configure phase precludes pre-install). |
| macOS (aarch64, x86_64) | Native `pkgsStatic` on the Mac remote builder (mac on the local network, ssh as `malbarbo`). | Inline with `nix build` — same as Linux. Mac is registered as `nix.buildMachines`; the Linux runner dispatches the darwin attrs to it. |
| Windows (x86_64) | Cross from Linux runner via `cosmocc` (or `pkgsCross.mingwW64` for a few). Test execution **cannot** run inside nix sandbox — host is Linux, binary is PE32+. | Separate `windows_tests` job in `action-build/build.yml`: scp the `.exe` plus the upstream source tarball to the Windows VM, ssh in, run `make check` inside an msys2 shell. msys2 ships PE32+ bash/make/diff/perl/python — running natively in kernel NT, not WSL. |

**Skip recommendations are not policy** — when a suite fails, the response is to investigate (regression in our patch chain, libc-specific bug, environment dep missing), not to flip `doCheck = false`.

## Per-OS dep installation

These tools provide the universal harness that most autotools/meson test-suites assume. Pre-install on every test environment.

| Tool | Linux (nixpkgs / pkgsStatic) | macOS (Mac remote) | Windows (msys2 pkg) |
| --- | --- | --- | --- |
| bash | `bash` | `bash` (system) | `msys2-runtime`, `bash` |
| coreutils userland (diff, cat, sort, etc.) | `coreutils` | `coreutils` (brew or our own) | `coreutils`, `diffutils` |
| sed, grep, awk | `gnused`, `gnugrep`, `gawk` | same | `sed`, `grep`, `gawk` |
| make | `gnumake` | `gnumake` | `make` |
| perl | `perl` | `perl` (system 5.30+) | `perl` |
| python3 | `python3` | `python3` | `python` |
| timeout | (coreutils) | (coreutils) | (coreutils) |

Per-package test command, extra deps, and quirks live in that package's `flake.nix` (`checkPhase` / `installCheckPhase` overrides and inline comments) and `README.md` ("Build notes" section). This document deliberately doesn't enumerate them — the package repo is the source of truth and is what stays in sync with the actual build.

## Open items to resolve while wiring

- **Mac remote builder mechanics:** decide between (a) nix-darwin `nix.buildMachines` registration so `nix build .#packages.aarch64-darwin.default` from the Linux runner is offloaded, or (b) explicit `nix copy` + `ssh mac 'nix-store --realise'` orchestration. Cleaner option (a) requires the Mac to have `nix-store --serve` running.
- **Windows test runner:** the helper `lib.runWindowsTests` (per task #4) must accept (pkgName, srcTarballAttr, exeAttr, testCmd, depsList) and emit a `windows-tests-<pkg>` derivation that lives outside the `pkgsStatic`/cosmo chain. Its build is a fixed-output derivation that nominates ssh as a builder-hostname — under the hood it `nix-build` on Linux, then runs `scp .exe + src + script | ssh win 'msys2 bash script'`. Exit code = test result.
- **What counts as "doCheck passing":** for v1, **all** upstream tests must pass on Linux + Mac native; for Windows, accept a documented per-pkg subset (e.g. ffmpeg without `fate-paletteuse`, coreutils without `tests/cp/sparse`) where the explanation is "Windows NTFS / cosmo gnulib does not implement <X>" — these go in `docs/platforms/<os>.md` as a known-skip with line-level citation.

## Why this document exists

To pin down the **harness** — where tests run for each OS, what the universal deps are, and the cross-OS plumbing that's still TBD. Per-package specifics belong in each package's repo (its `flake.nix` and `README`), not here.
