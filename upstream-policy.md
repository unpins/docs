# Upstream policy

unpins keeps no security posture of its own. **Ours is the nixpkgs channel
`nix-lib` pins.** When we are behind, the fix goes into nixpkgs, not here.

## What we pin

`nix-lib/flake.nix` declares one input:

```nix
inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
```

**The channel branch, never the release branch.** `nixos-YY.MM` advances only
after the tested channel commit; `release-YY.MM` is the raw tip and the gap
between them is the testing. One sample, 2026-09-24: channel `c508844`
(02:58Z), branch `6764080` (19:41Z). The head is
`gh api repos/NixOS/nixpkgs/commits/nixos-26.05 --jq .sha`
(`https://channels.nixos.org/nixos-26.05/git-revision` returns empty).

**Only `nix-lib` may declare a `nixpkgs` URL.** A package flake reaches nixpkgs
through `inputs.nixpkgs.follows = "unpins-lib/nixpkgs"` — that alias is correct
and four packages use it. What is forbidden is a second `url =`: it is a second
pin and it drifts. `links` carried a private `nixos-25.11` until 2026-09-24 and
shipped openssl 3.6.2 while the other 107 had 3.6.4. Any surviving `url =` is a
registered divergence, not an oversight to leave unnamed.

## Cadence

Re-pin to the channel head **monthly**, and out of band when an advisory lands
on something we ship. The interval is set by cost: a re-pin is a full eval
re-baseline (2–3 h) plus a catalog CI round of 108 pushes (~9h45).

Order, because getting it wrong invalidates the measurement:

1. Update `nix-lib`'s **lock** — for a moving `nixos-YY.MM` ref, `flake.nix`
   does not change at all. **Commit it.**
2. Re-lock every package against the new `nix-lib`. The packages' `nixpkgs`
   node moves only *transitively*, as `unpins-lib`'s own input.
3. Re-baseline the eval fingerprint.
4. Commit and push the 108 locks; CI round.

**The trap:** the re-lock helper compares against `nix-lib`'s committed HEAD.
Bump `nix-lib`'s lock and forget to commit, and it reports every package as
already current and skips all 108 silently — after which the baseline measures
the old pin, which is the one failure this ordering exists to prevent.

**Check that the bump landed** by reading the lock, not by evaluating:

```bash
jq -r '.nodes.nixpkgs.locked.rev' <pkg>/flake.lock
```

Reading a version out of a `.drv` name does not work: most packages' versions do
not move on a pin bump.

**What the re-baseline is for.** The eval fingerprint is a *refactor* guard.
After a pin bump everything legitimately moves, so it verifies nothing — you are
recording a new reference so the next refactor has a valid one. A large diff
there is the expected result, not a finding.

A pin bump makes a local build want to rebuild the LLVM toolchain, which we
never do here. **Local verification of a pin bump is eval-only**; CI and cachix
build it.

The workspace notes (not in this repo) carry the script names and the memory
limits for those steps.

## How nixpkgs handles a stable release

From `CONTRIBUTING.md` and `pkgs/README.md` in the revision we pin.

**Stable is version-pinned and patch-backported, not version-bumped.** The
version string can stay put while the CVE closes underneath it. In the tree we
pin, perl is `5.42.0` and carries `CVE-2026-8376.patch`; musl is `1.2.5` and
carries four CVE patches.

**A stable branch is not frozen, but it is conservative.** Release branches
"should generally only receive backwards-compatible changes". Within that,
`CONTRIBUTING.md` accepts security fixes, new packages/modules/functions, and
**version updates** — patch versions with fixes, minor versions without
breaking changes. Breaking major bumps only for security-critical applications
and for clients that fail without updating.

**Mass rebuilds do not go to the release branch.** ≥500 rebuilds: consider
`staging-YY.MM`; ≥1000: it is a mass rebuild and must target staging. A bump to
a widely-depended library is in that class, which changes both the route and the
timeline.

**The exception that matters most to us:** `pkgs/README.md` — *"Critical
security fixes may bypass the staging branches and be delivered directly to
release branches."*

**The mechanism is the backport.** The fix lands on `master`; a
`backport release-YY.MM` label opens the PR automatically (maintainers), or it
is cherry-picked by hand. Where the branches have diverged too far to share a
change, two separate PRs.

**CVEs are tracked as "Vulnerability roundup" issues**, triaged by hand, with an
explicit false-positive path.

**Which releases accept backports:**
`nix-instantiate --eval -A lib.trivial.oldestSupportedRelease` — **run it
against master/unstable, not against our pinned tree.** The value is marked
"Update on master only. Do not backport", so a release branch reports its
branch-off value forever and will never warn you. It says which releases take
backports; it does not say when ours expires.

## Build from the derivation, not from the source

Take the nixpkgs derivation and `overrideAttrs` it. A fresh
`stdenv.mkDerivation` (or `buildRustPackage`) over `pkgs.<attr>.src` takes the
source and drops **the whole recipe** — `patches`, `postPatch`, `postUnpack`,
`prePatch`, `configureFlags`, `env` — with no error and no change in the version
string. That is the single mechanism by which a nixpkgs security backport misses
us in silence.

`patches` is not the only carrier, and our own headline case proves it: of
perl's CVE fixes **one** rides in `patches` and **nine** ride in
`vendoredPerlDistributions`, which replaces five bundled CPAN dists via
`postPatch`/`postUnpack`. An audit that diffs only `patches` sees none of them.

**Verified example of the failure.** Until 2026-09-24 the engine toolchain
untarred `musl.src` and copied it verbatim into the on-demand sysroot, so the
libc behind 107 of 109 catalog packages was upstream musl 1.2.5 without
nixpkgs' four CVE backports — including CVE-2025-26519, an out-of-bounds write
in `iconv`. Nothing in any version string showed it. Fixed by feeding
`applyPatches { inherit (musl) src patches; }` to the payload, and the same
`inherit … src` omission in the tcc sysroots by inheriting `patches` too.

**When `overrideAttrs` is the wrong tool.** Some packages expose a supported
override for the version and say so. ffmpeg's `generic.nix` carries
*"NOTICE: Always use this argument to override the version. Do not use
overrideAttrs"* — so a version change there is
`pkgs.ffmpeg-headless.override { version = "…"; hash = "…"; }`, which keeps the
full patch/postPatch/configure apparatus. Read the package before overriding it.

**Auditing a package:** diff our derivation's `patches`, `postPatch`,
`postUnpack`, `configureFlags` and `env` against the nixpkgs attr's. On a
multicall package the outer drv is the wrapper and its `patches` is legitimately
empty — follow `inputDrvs` to the drv that compiles.

## How to measure exposure

**Do not compare our version strings against `nixpkgs-unstable`.** It is the
wrong instrument for a stable channel and it manufactures work: stable closes
CVEs without moving the version. The 2026-09-24 sweep
(`security-remeasure-2026-09-24.md`, workspace-local) called perl "6 CVEs
behind" when its principal core CVE was already patched in what we ship.

In order:

1. **Are we at the channel head?** Usually the whole question.
2. **Does the fix reach our binary?** The recipe diff above. This is the one
   that found musl.
3. **nixpkgs' Vulnerability-roundup issues** for the attrs we consume — as a
   triage feed, never a count: one issue can hold several CVEs, one CVE can span
   several issues, and one package can have several issues.
4. **`meta.knownVulnerabilities`** on the attrs we consume — nixpkgs' in-band
   signal, free at eval.
5. **For a specific package, the project's own advisory source** — curl's
   `vuln.json`, openssl/libxml2/xz NEWS, GitHub advisories. Never inferred.

**A generic distro-tracker sweep is a triage list, never a count.** Measured on
curl, 2026-09-24: the Debian Security Tracker flagged 26 where curl's own
`vuln.json` said 9, because the "fixed version" it compares against is Debian's.
That is one package on one day — do not promote the ratio to a rule.

## Diverging from nixpkgs

The default answer to "we are behind and the channel does not have it" is **ask
nixpkgs to backport it**. A local override is the last resort: we then carry the
version, the hash and the breakage until the channel catches up.

In order:

1. **Is it already patched in place?** Read `.patches` — and the rest of the
   recipe.
2. **Does the package expose a supported version override?** (ffmpeg does.)
3. **Would the release branch accept it?** Usually yes. Check the mass-rebuild
   threshold, and whether it qualifies as a critical security fix that may
   bypass staging.
4. **Open the backport request upstream.**
5. **Only if that fails and the exposure is real**, diverge locally — with the
   technical reason recorded at the site and an entry in the register.

### Divergence register

**Who maintains it:** whoever runs the monthly re-pin, as part of it. An entry
closes when the channel catches up or the site is converted. Regenerate rather
than trust the list — sites at depth 3 (`<pkg>/cosmo/*.nix`) are invisible to a
`-maxdepth 2` sweep:

```bash
# fresh derivation over a nixpkgs source
grep -rn --include='*.nix' -E 'inherit \([^)]*\)[^;]*\bsrc\b|\bsrc = [A-Za-z][A-Za-z0-9_.]*\.src\b' .
# a patch list that REPLACES rather than extends
grep -rn --include='*.nix' -E '^\s*patches = \[' . | grep -v 'old\.patches\|base\.patches'
```

**Own pin, outside the nixpkgs stream** — each needs its own update decision,
because the monthly re-pin does not move any of them:

| Site | What | Note |
|---|---|---|
| `fastfetch/flake.nix` `nixpkgs-recent` | `nixos-unstable`, locked 2026-05-21 | ships a glibc-dynamic helper; documented reason, stale pin |
| `fastfetch` `graphicsgd-src`, `polyfill-glibc-src` | 2026-01-27, 2024-10-30 | |
| `unpin`, `cfonts` `rust-overlay` | Rust toolchain | outside nixpkgs by nature |
| `quickjs`, `quickjs-ng` | `fetchTarball` of upstream | |
| `procps-ng/portable.nix` | own `fetchurl`, 4.0.6 | |
| `biber/windows.nix` `Win32-Unicode-0.38` | | |
| `nix-lib/toolchain/uapi-uc/` | 8 netfilter UAPI headers, vendored from `linuxHeaders` 6.18.7 | `linuxHeaders` does not evaluate from a darwin package set and this payload builds on darwin; re-sync recipe in its README |
| `binaryen` | **not a divergence** — `overrideAttrs` to v132, keeps `old.patches` | |

**Fresh derivation over a nixpkgs source** — dropping the recipe:

| Site | Dropped today |
|---|---|
| `nix-lib/toolchain/default.nix` LLVM `monorepoSrc` | nixpkgs' LLVM patches — widest reach |
| `nix-lib/flake.nix` `mkRustCrate` `muslCrossPure` | shared helper, so the hole is in the framework |
| `fish/flake.nix` | 3 patches + a large `postPatch`, all targets |
| `php/windows.nix` | `fix-paths-php84.patch` |
| `ffmpeg/flake.nix` | 2 patches, neither security — use `.override` |
| `vim/flake.nix` (cross), `gvim/flake.nix` | empty today |
| `biber/flake.nix` 19 perl XS modules | empty today |
| `xvfb/`, `xvnc/` xkbcomp ×6 | empty today |
| `nix-lib/toolchain/default.nix` musl, `tcc/multi.nix` ×5 | **fixed 2026-09-24** |

**Patch list replaced rather than extended:** `usbutils/flake.nix` drops
nixpkgs' `fix-paths.patch` deliberately (it only rewrites `lsusb.py`, which we
do not ship) but will silently eat any patch nixpkgs adds later. Filter the
list instead of replacing it.

**Open, awaiting a decision:**

- **ffmpeg 8.1.3** — 26.05 has 8.1.2. `ffmpeg_8` is alive on master, so
  `ffmpeg_8: 8.1.2 -> 8.1.3` plus a backport label is a routine change; locally
  it is reachable today through the supported `.override { version; hash; }`.
- **libjxl 0.12.0** — has a Security section. Upstream's "for evaluation
  purposes" note is boilerplate on every libjxl release, including the 0.11.2 we
  ship, and ends "Always prefer to use the latest release" — so it is not a
  reason to stay.

Being behind `nixpkgs-unstable` is not, by itself, a finding.
