<!--
  Canonical package README. Copy to `<pkg>/README.md`, fill the <…> slots, and
  delete the guidance comments. Filled references: `tree/README.md` (single
  command) and `flac/README.md` (multicall). Keep it tight — the opening + Usage
  are for end users and must be jargon-free; mechanism/quirks go in Build notes.

  OPENING: this is the package-README sentence from docs/messaging.md, adapted to
  keep the upstream link (and, if useful, a one-line description). Name only the
  OSes we actually ship — the platform list must match the badges below. Say
  "single self-contained binary" (never "static" / "standalone build"), and
  "built natively for …" (never "one build" / "runs unchanged" — we are not
  Cosmopolitan). See docs/messaging.md, the source of truth for this wording.
-->
# <pkg>

[<pkg>](<upstream-homepage>) as a single self-contained binary, built natively for <Linux, macOS, and Windows>.
<!-- With a one-line description, split the binary clause into its own sentence so
     neither half gets crowded:
[<pkg>](<upstream-homepage>) — <one-line description of what it does>. A single self-contained binary, built natively for <…>. -->

[![CI](https://github.com/unpins/<pkg>/actions/workflows/<pkg>.yml/badge.svg)](https://github.com/unpins/<pkg>/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install <pkg>`.

## Usage

<!--
  Lead with the RUN form, then install. Both ALWAYS take the PACKAGE name `<pkg>`
  (it resolves the repo `unpins/<pkg>`), NEVER a command name.

  - `unpin <pkg>` is the run form (run is the default verb, so it's omitted):
    it runs the binary without installing it. Show it first, with representative
    args.
  - `unpin install <pkg>` puts it on PATH.

  Multicall whose package name is NOT itself a command users type
  (pciutils → lspci/setpci, coreutils → ls/cp): writing `unpin <command>` looks
  up a repo that doesn't exist and fails. Keep the package name in the commands,
  and state — jargon-free — which commands the install creates ("creates the
  `lspci` and `setpci` commands"). The argv[0] dispatch mechanism is Build notes
  material, never here. For long alias lists, show a few and point to
  `unpin info <pkg>`; never paste the whole list.
-->

Run the `<pkg>` program with [unpin](https://github.com/unpins/unpin):

```bash
unpin <pkg> <representative args>
```

To install it onto your PATH:

```bash
unpin install <pkg>
```

## Man pages

<!--
  `unpin man` takes the PACKAGE name first, then an optional page (the page
  defaults to <pkg>): `unpin man <pkg> [<page>]`. For a multicall, name the
  page — `unpin man <pkg> <applet>` (e.g. `unpin man pciutils lspci`). Omit this
  section entirely if the package ships no man pages.
-->

`<pkg>.1` is embedded in the binary — read it with `unpin man <pkg>`.

## Build locally

<!--
  Every command here must work as written. `./result/bin/<pkg>` exists only when
  `<pkg>` is a program. A multicall whose package name is NOT a program (pciutils,
  coreutils) and has no `defaultProgram` only lists its programs when run bare —
  select one with `--unpin-program=<program>` in both blocks, as coreutils does:
    ./result/bin/coreutils --unpin-program=ls /
    nix run github:unpins/coreutils -- --unpin-program=ls /
  Give args a program accepts without operands (`--version`), not a usage error.
-->

```bash
nix build github:unpins/<pkg>
./result/bin/<pkg> --version
```

Or run directly:

```bash
nix run github:unpins/<pkg> -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/<pkg>/releases) page has standalone binaries for manual download.

## Build notes

<!--
  Technical detail lives HERE, never in the opening or Usage: the multicall /
  argv[0] dispatch mechanism, disabled upstream features, per-platform specifics,
  and — in one line — why a platform is excluded (the upstream gap). No roadmaps,
  porting plans, or effort estimates: we package what we ship, we don't plan
  upstream development. Drop this section if there's nothing to note.

  Only PACKAGE-SPECIFIC facts go here. The project-wide guarantees — single
  self-contained binary, PE32+ on Windows, no companion DLLs, cosmo as a
  build-time POSIX layer apelinked to a PE — are global (the opening sentence +
  docs/platforms/cosmocc.md); never restate them per package. The same goes
  for the Windows runtime requirement (Windows 10+, UCRT — docs/platforms/
  mingw.md) and for translations (no package ships message catalogs —
  docs/adding-a-package.md): both are platform facts, not package facts. For
  the Windows variant, name it (mingw / cosmo) and, if cosmo, give the one-line
  reason — which POSIX API the package needs that mingw lacks — and stop there.

  Not included: one bullet, always this label, listing what the full nixpkgs
  package has and this binary does not — sibling programs nixpkgs installs from
  the same source, and features it turns on — each with its one-line reason.
  Something nixpkgs itself leaves off is noted the same way, with "(off in
  nixpkgs)" as the reason. Omit the bullet when nothing is missing; never write
  "no upstream features are disabled" — the list is the claim.

  Tests: one bullet, always this label, in one of three closed forms (the flake
  must agree — docs/testing.md):
    - **Tests:** <suite> runs on native builds (<N> failures under
      static-musl) and is skipped on cross targets the build host can't execute.
    - **Tests:** <suite> is not run: <one-line reason, the same as the flake's>.
    - **Tests:** <pkg> ships no test suite.
-->

- <e.g. Windows uses cosmo, not mingw, because <pkg> needs <POSIX API, e.g. termios/fork> that mingw lacks.>
- **Not included:** `<program>` (<reason>); <feature> (<reason>).
- **Tests:** <one of the three forms above>.
