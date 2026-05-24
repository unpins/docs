# Running upstream test-suites

The unpins release gate is **upstream tests executing against the artifact on each target OS**, not smoke (`<bin> --version`). This document is the per-package × per-OS matrix that the test-runner infrastructure consumes.

## How test execution maps to platforms

Test execution differs by OS because the build context differs:

| OS | Build context | Test execution |
| --- | --- | --- |
| Linux (x86_64, aarch64) | `pkgsStatic` (musl) — native on GHA Linux runner | Inline with `nix build`, via `doCheck = true` (or `doInstallCheck` when configure phase precludes pre-install). |
| macOS (aarch64, x86_64) | Native `pkgsStatic` on the Mac remote builder (mac on the local network, ssh as `malbarbo`). | Inline with `nix build` — same as Linux. Mac is registered as `nix.buildMachines`; the Linux runner dispatches the darwin attrs to it. |
| Windows (x86_64) | Cross from Linux runner via `cosmocc` (or `pkgsCross.mingwW64` for a few). Test execution **cannot** run inside nix sandbox — host is Linux, binary is PE32+. | Separate `windows_tests` job in `action-build/build.yml`: scp the `.exe` plus the upstream source tarball to the Windows VM, ssh in, run `make check` inside an msys2 shell. msys2 ships PE32+ bash/make/diff/perl/python — running natively in kernel NT, not WSL. |

The matrix below documents the canonical invocation and the runtime deps each upstream's test harness expects. **Skip recommendations are not policy** — when a suite fails, the response is to investigate (regression in our patch chain, libc-specific bug, environment dep missing), not to flip `doCheck = false`.

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

Per-package additions are listed in each section.

## Matrix

### htop (3.x)

- **Targets:** linux x86_64+aarch64, darwin x86_64+aarch64. **No Windows** (curses TUI; not portable to PE32+ in our matrix yet).
- **Build:** autotools.
- **Test cmd:** `make check` (limited unit suite — htop's tests are thin; covers vector ops + meter parsing).
- **Extra deps:** none beyond baseline.
- **Linux quirks:** none known on musl static.
- **macOS quirks:** none known.
- **Confidence:** high — tiny suite, easy to wire first.

### jq (1.7.x)

- **Targets:** all 5 (incl. Windows via `pkgsCross.mingwW64`).
- **Build:** autotools.
- **Test cmd:** `make check` — runs `tests/jq.test`, `tests/onig.test`, `tests/optional.test`. Pure JSON/shell driven, no network.
- **Extra deps:** none beyond baseline.
- **Linux quirks:** none known.
- **macOS quirks:** none known.
- **Windows quirks:** locale-dependent tests may need `LC_ALL=C` (TODO verify with first run).
- **Confidence:** high (linux/mac), medium (windows — unexplored).

### tree (2.x)

- **Targets:** all 5.
- **Build:** hand-rolled Makefile (no autotools).
- **Test cmd:** **none upstream.** Mike Baker's tree (the 2.x reboot) ships no test harness — no `make test`, no `tests/` dir. There's nothing to invoke as a release gate beyond build + smoke.
- **Extra deps:** n/a.
- **Linux quirks:** n/a.
- **macOS quirks:** n/a.
- **Windows quirks:** uses cosmocc, not mingw, because `msvcrt readdir` silently drops filenames outside the active code page; cosmocc's libc exposes UTF-8 from the Win32 wide-char APIs. Any future test harness must include CJK/emoji/Latin-1-accent fixture filenames to catch a regression here.
- **Confidence:** n/a — no suite to run.

### file (5.x)

- **Targets:** all 5.
- **Build:** autotools.
- **Test cmd:** `make check` — exercises detection of a handful of fixture files under `tests/`.
- **Extra deps:** baseline only. Recursive call to `file` itself.
- **Linux quirks:** the binary loads its magic database from an embedded buffer when no `-m` / `$MAGIC` is given (see `file-embed-magic.patch`). `make check` invokes the build-tree `file` with the freshly compiled `magic/magic.mgc` via the `-m` path inside `check_PROGRAMS`, so it exercises the disk path, not the embed. To also cover the embed path explicitly, run the binary on a fixture with no `-m` and `$MAGIC` unset and confirm `--version` reports `magic file from (embedded)`.
- **macOS quirks:** same. The single-binary path on darwin also depends on `--disable-shared` reaching configure (nix-lib's `filterEnableStaticOnDarwin` strips it; we push it back via `preConfigure`'s `configureFlagsArray`). A regression there would leak `libmagic.1.dylib` next to the binary — check `otool -L` in the test wrapper.
- **Windows quirks:** libgnurx static — the recompile-regex.o-as-real-`.a` recipe in `flake.nix`. Uncharted under `make check`; validate during #4.
- **Confidence:** medium — embed branch isn't exercised by upstream's harness, has to be added.

### tar (libarchive `bsdtar`, 3.x)

- **Targets:** all 5.
- **Build:** autotools.
- **Test cmd:** `LC_ALL=C make check` (libarchive's harness is locale-sensitive).
- **Extra deps:** gzip, bzip2, xz, zstd CLIs (libarchive uses them in shell tests). On Linux they're already in build closure; on Mac and Windows msys2, install explicitly.
- **Linux quirks:** known upstream-fragile cases on huge-UID test fixtures (libarchive issue tracker). If hit, patch the fixture, don't skip the test.
- **macOS quirks:** same.
- **Windows quirks:** `acl_*`/`chown` tests are no-ops on NTFS — libarchive guards them with `#ifdef`. Validate guards trip correctly under msys2.
- **Confidence:** medium — first run will surface what's actually broken.

### vim (9.x)

- **Targets:** all 5.
- **Build:** hand-rolled Makefile (`src/Makefile`, `src/Make_ming.mak` for Windows).
- **Test cmd:** `cd src && make test` — runs `src/testdir/test_*.vim` via vim itself in batch mode.
- **Extra deps:** vim binary (recursive — `$VIMTEST` env). Baseline: bash, diff, terminal (`TERM=dumb` works for most).
- **Linux quirks:** terminal tests assume a tty; in CI use `script -qc "..."` or `expect`-style wrapper. Some tests need locale data; pass `LC_ALL=C.UTF-8`.
- **macOS quirks:** terminfo lookup uses our embedded fallback set. Validate that `terminfo` test passes against the baked-in list.
- **Windows quirks:** vim test suite has explicit Win32 conditional code (`Test_*_works_on_windows`); has not been exercised in our cross-build. Validate during #4.
- **Confidence:** medium — vim's suite is large but well-curated upstream.

### gvim (9.x)

- **Targets:** **x86_64-linux only** + windows-x86_64. No other Linux arch, no macOS.
- **Build:** vim sources with GUI (GTK2 on Linux — static, see `docs/big-packages.md`; Win32 GUI on Windows).
- **Test cmd:** `cd src && make test_gui` (subset of vim tests that exercise GUI init).
- **Extra deps:** Xvfb on Linux (headless display); `--enable-gui-tests` config. Baseline tools.
- **Linux quirks:** static GTK2 is unusual — GUI init test will be the canary for the patch chain.
- **Windows quirks:** GUI init under Win32 subsystem from msys2 PE32+ harness — uncharted.
- **Confidence:** low — gvim is the most experimental of the 11. Acceptable for v1 to have just gvim's vim-mode tests run, with `make test_gui` deferred if GUI init is fragile, with a documented justification (NOT a silent skip).

### tmux (3.x)

- **Targets:** linux x86_64+aarch64, darwin x86_64+aarch64. **No Windows** (pty-only).
- **Build:** autotools.
- **Test cmd:** `make check` — exercises argument parsing, basic command loop. tmux upstream test suite is minimal; the bulk of tmux is interactively tested via maintainer-run scripts.
- **Extra deps:** baseline. No pty required for `make check` (the interactive scripts are not part of `check`).
- **Linux quirks:** none.
- **macOS quirks:** none.
- **Confidence:** high — small suite.

### curl (8.x)

- **Targets:** all 5.
- **Build:** autotools (nixpkgs uses autotools path; CMake exists but we don't use it).
- **Test cmd:** `make test-ci` (smaller, deterministic subset of `make test`). Full `make test` includes network-dependent + protocol tests that aren't all relevant for our build config.
- **Extra deps:** perl (heavy), python3, ssh server stub (some tests), `nghttp2-server` for HTTP/2 tests (skip if not built). Curl's `tests/runtests.pl` orchestrates everything.
- **Build config interactions:** our curl flake disables features (http3? schannel on Windows?). Verify which test categories the disabled features remove — call `runtests.pl --list-features` first.
- **Linux quirks:** musl + curl test 12xx-1300 range historically flaky on DNS resolution timeouts. Investigate per-failure, don't skip.
- **macOS quirks:** sendfile-related test variants assume Linux syscall, gated upstream.
- **Windows quirks:** curl's mingw test path is uncharted in our stack. Validate during #4. Schannel/Schannel tests differ from OpenSSL.
- **Confidence:** medium overall — the test infrastructure is well-documented but matching it against our build flags requires legwork.

### coreutils (9.x)

- **Targets:** all 5. **Windows via cosmocc** (see `cosmo.nix` sidecar; gnulib gates this).
- **Build:** autotools.
- **Test cmd:** `make check` — exercises ~600 perl-driven tests in `tests/`.
- **Extra deps:** perl (heavy), python3, gdb (some tests use it for memory checks — optional), strace (Linux only, optional). `tests/init.cfg` documents skip conditions.
- **Linux quirks:** musl: a handful of locale and stat tests differ from glibc; nixpkgs upstream `coreutils-static` documents which skips it applies (`coreutils-skip-tests-musl.patch`-class). Adopt their list verbatim where it matches; investigate divergence.
- **macOS quirks:** darwin behaves enough like BSD that some `chmod`/`stat` tests skip on `bsdSymlink`-style differences (documented in `tests/init.cfg`). Honor upstream conditionals.
- **Windows quirks (cosmocc):** **uncharted**. Cosmo's gnulib porting (`postPatch = ""` per memory) drops a chunk of gnulib's POSIX layer. Many `tests/cp/*`, `tests/mv/*`, `tests/rm/*` tests likely fail on permission/symlink semantics. Investigate during #4 wiring; classify each failure as (a) NTFS semantics → upstream-conditional skip, (b) cosmo layer bug → file with ahgamut, (c) our patch regression.
- **Confidence:** high (linux/mac), low (windows/cosmo — needs hands-on validation).

### ffmpeg (6.x or 7.x)

- **Targets:** all 5.
- **Build:** custom `./configure` (not standard autotools); Makefile-driven.
- **Test cmd:** `make fate` (FFmpeg Automated Testing Environment).
- **Extra deps:** perl, python3, **samples tarball** (~10 GB full set; subset configurable via `SAMPLES=` path). Without samples, `make fate-rsync` downloads them — expensive.
- **Strategy:** for CI, use a **trimmed FATE config**: only fate-suites that exercise decoders/encoders we actually enable. Set `SAMPLES=` to a pre-staged subset; cache it. Don't run full FATE on every push.
- **Linux quirks:** pthreads enabled; --enable-pthreads tests exercise multi-threaded paths.
- **macOS quirks:** our darwin build omits `--enable-pthreads` (libSystem constraint per memory); the threaded tests are conditionally compiled out.
- **Windows quirks:** `--disable-w32threads --enable-pthreads` per memory; cosmo path not wired (ffmpeg uses mingw). Validate during #4.
- **Confidence:** medium — FATE infrastructure is well-documented but expensive; need to pick a subset that's both representative and cheap.

## Rollout order

Wire test-runs in this order (easiest first, so the harness is debugged before we tackle hard pkgs):

1. **tree, file** — tiny suites, validates the wiring itself.
2. **htop, tmux, jq** — small autotools suites, no nasty deps.
3. **tar** — first test with multi-format deps (gzip/bzip2/xz/zstd).
4. **vim** — first test with binary-driving-itself-recursively pattern; first terminal-aware test.
5. **gvim** — adds GUI/Xvfb interaction.
6. **curl** — first test with substantial config-flag dependency mapping.
7. **coreutils** — large suite, first stress test for the Mac remote builder, first cosmocc test path.
8. **ffmpeg** — last, because of FATE sample-data orchestration.

## Open items to resolve while wiring

- **Mac remote builder mechanics:** decide between (a) nix-darwin `nix.buildMachines` registration so `nix build .#packages.aarch64-darwin.default` from the Linux runner is offloaded, or (b) explicit `nix copy` + `ssh mac 'nix-store --realise'` orchestration. Cleaner option (a) requires the Mac to have `nix-store --serve` running.
- **Windows test runner:** the helper `lib.runWindowsTests` (per task #4) must accept (pkgName, srcTarballAttr, exeAttr, testCmd, depsList) and emit a `windows-tests-<pkg>` derivation that lives outside the `pkgsStatic`/cosmo chain. Its build is a fixed-output derivation that nominates ssh as a builder-hostname — under the hood it `nix-build` on Linux, then runs `scp .exe + src + script | ssh win 'msys2 bash script'`. Exit code = test result.
- **What counts as "doCheck passing":** for v1, **all** upstream tests must pass on Linux + Mac native; for Windows, accept a documented per-pkg subset (e.g. ffmpeg without `fate-paletteuse`, coreutils without `tests/cp/sparse`) where the explanation is "Windows NTFS / cosmo gnulib does not implement <X>" — these go in `docs/platforms/<os>.md` as a known-skip with line-level citation.

## Why this document exists

Task #2 in the v1 release plan ([[project_unpins_v1_release_plan]]). Output of this document feeds:

- Task #1 (CI green) — for each currently red pkg, the matrix tells whether the failure is build (fix in `nix-lib` or patches) or a test that's expected to fail on this libc/OS.
- Task #3 (Mac native build with tests) — Mac deps list per pkg.
- Task #4 (Windows test infra) — msys2 deps list to pre-install on the VM image.
