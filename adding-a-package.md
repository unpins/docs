# Adding a package

Order of operations when adding `<pkg>` to unpins, based on the file/htop/tree paths that have already worked.

## Principles

Two rules govern every package. Read them before reaching for a shortcut.

**Ship every upstream feature.** Build the program with all of its features
enabled — the catalog's value is the *complete* program as one binary, not a
stripped-down one. Turn a feature off only when it is genuinely impossible on a
target: it can't link statically / against musl, it can't cross-compile, or it
needs an OS API the target lacks. "It was easier to disable" is never a reason.
Note every dropped feature in the README's Build notes with the target and a
one-line why (same rule [releasing.md](releasing.md) applies to `--disable-*`).
Before disabling something to "save space", measure — static link + DCE makes
"heavy" libs nearly free (see
[static-linking.md](static-linking.md#dce-is-much-more-aggressive-than-you-expect)).

**Reuse nix-lib's fixes — don't re-derive them.** When a library won't build
static or cross, the fix very often already lives in `nix-lib`. Check before you
debug:

```bash
ls ../nix-lib/native-overlay ../nix-lib/mingw-overlay ../nix-lib/cosmo  # is <lib>.nix here?
nix eval ../nix-lib#lib.nativeFixes --apply builtins.attrNames          # the native fix fns
```

The two sides are wired differently — know which you're in:

- **Native (Linux/macOS, `native-overlay/`)** — each fix is a function
  `unpins-lib.lib.nativeFixes.<lib>` (`pkgs -> drv`). It is **not** applied to
  your transitive deps automatically; thread it in with `.override`:

  ```nix
  build = pkgs:
    let p = pkgs.pkgsStatic; in
    p.<pkg>.override { <lib> = unpins-lib.lib.nativeFixes.<lib> p; };  # cf. tmux's libevent
  ```

  (If a `native-overlay/<pkg>.nix` exists for the *package itself*,
  `mkStandaloneFlake` already uses it as the default native build — no `build`
  closure needed.)

- **Windows (mingw/cosmo, `mingw-overlay/` + `cosmo/`)** — these *are* applied
  automatically, but only when you build **through the cross set**:
  `mingwStaticCross pkgs`, or the cosmo cross set via the `./cosmo.nix` sidecar.
  Build through it and `libidn2` / `libpsl` / `ncurses` / … are already fixed
  transitively — don't re-fix them. Reaching for raw `pkgsCross.mingwW64.<lib>`
  instead **bypasses the overlay and loses the fix.**

Add a *new* fix to `nix-lib` only when none exists **and** ≥ 2 packages need it
(see [architecture.md](architecture.md#where-per-target-quirks-live)); a
one-package quirk stays inline in your flake.

## 1. Decide the scope up front

Before scaffolding, settle:

- **Does upstream already ship portable single-binary releases?** If `<owner>/<repo>` publishes statically-linked binaries for the platforms users care about (`ripgrep` is the canonical example — BurntSushi ships musl-static Linux, native macOS, and `.exe` for Windows on every release), **don't package it.** Users get the upstream binary directly via `unpin install <owner>/<repo>`, and that's the whole point. The catalog exists for programs whose upstream **doesn't** do this.
- Does `pkgs.pkgsStatic.<pkg>` already exist in nixpkgs? Check `nix eval nixpkgs#pkgsStatic.<pkg>.version`.
- Is Windows feasible? Try `nix eval --impure --expr '(import <nixpkgs> { config.allowUnsupportedSystem = true; }).pkgsCross.mingwW64.<pkg>.version'`. If the package fundamentally assumes POSIX (`fork`, signals, `/etc/<file>`, etc.) the mingw path is usually a dead end — see [platforms/mingw.md](platforms/mingw.md) and consider [platforms/cosmocc.md](platforms/cosmocc.md) instead.
- Does the package need runtime data files (config dir, magic database, syntax files)? If yes, plan to follow [runtime-data.md](runtime-data.md) — embed them in the binary (a compiled-in blob, or an embedded ZIP + VFS). `package_data` (a companion `.tar.zst`) is off by default and only for data that can't be embedded.
- **Reserved name?** A catalog *program* may not take the bare name of a helper verb. `man` and `readme` are **builtin subcommands** (`search`/`changelog`/`license`/… reserved for later, builtin or as `unpins/unpin-<verb>` packages — see [helper-verbs.md](helper-verbs.md)), so `unpin man`/`unpin readme` always dispatch to the verb; a catalog program of the same bare name would be reachable only as `unpin run <name>`, never `unpin <name>`. A real general-purpose man, for instance, ships under its upstream name (`mandoc` / `man-db`), never `man`.
- License: the website reads it automatically from the artifact's `meta.license` (`website/gen-packages.py`, via nix-lib's meta propagation) — nothing to add by hand. Only set the `license` arg in your `mkStandaloneFlake` call when the build has no upstream `meta.license` (a custom `mkDerivation`) or inherits a noisy multi-license list you want pinned to the effective license — see how `ffmpeg` / `python` do it.

## 2. Scaffold

```bash
cd /path/to/unpins
mkdir <pkg>
cd <pkg>
git init -b main
cp ../tree/.gitignore .                              # 3 lines: result, result-*, .direnv/
cp ../docs/templates/flake.nix flake.nix             # then edit name + adapt
mkdir -p .github/workflows
cp ../docs/templates/build.yml .github/workflows/<pkg>.yml
cp ../docs/templates/release.yml .github/workflows/release.yml
cp ../docs/templates/CHANGELOG.md CHANGELOG.md          # then fill the initial release under [Unreleased]
```

Edit `flake.nix`: set `description`, `name`, and any `build` / `windowsBuild` / `package_data` overrides. For a cosmocc Windows build, write `windowsBuild = import ./cosmo.nix { inherit unpins-lib; };` and put the recipe in a sibling `./cosmo.nix` (see [platforms/cosmocc.md](platforms/cosmocc.md)). The minimum case (no quirks, three platforms) is ~16 lines — see `tree/flake.nix`.

## 3. Generate the lock file

```bash
cp ../tree/flake.lock .                              # seed
nix flake update                                     # bump to current nix-lib / nixpkgs
```

## 4. Write the README

Start from [`templates/README.md`](templates/README.md) — fill the `<…>` slots and delete the guidance comments. Filled references: `tree/README.md` (single command), `flac/README.md` (multicall). What the template encodes:

- **Opening** — the package-README sentence from [messaging.md](messaging.md), adapted to keep the upstream link (and, if useful, a one-line description): `[<pkg>](<homepage>) as a single self-contained binary, built natively for <OSes>.` Name **only** the OSes we ship — the platform list must match the badges. Then CI badge (`![CI](https://github.com/unpins/<pkg>/actions/workflows/<pkg>.yml/badge.svg)`) + platform badges (Linux/macOS, optionally Windows), then the catalog/install line: `Part of the [unpins](https://unpins.org) catalog; install it with [\`unpin\`](https://github.com/unpins/unpin): \`unpin install <pkg>\`.`
- **`## Usage`** leads with the run form, then install — both always take the **package** name `<pkg>`, never a command name (`unpin <X>` resolves the repo `unpins/<X>`):
  - `unpin <pkg> <args>` (run is the default verb, so it's omitted) runs it without installing;
  - `unpin install <pkg>` puts it on PATH.
- **Package name ≠ command name (multicall).** When the package name isn't itself a command users type (pciutils → lspci/setpci, coreutils → ls/cp), `unpin <command>` looks up a repo that doesn't exist and fails. Keep `<pkg>` in the invocations, and state the *outcome* — "creates the `lspci` and `setpci` commands" — never the `argv[0]` dispatch mechanism (that's Build notes). For long alias lists, show a few representative ones and point to `unpin info <pkg>` (it reads the binary's embedded `unpin/aliases`, so it always matches what shipped) or the tool's own `--help`; never paste the whole list.
- **`## Man pages`**: `unpin man` takes the package name first, then an optional page (defaults to `<pkg>`) — `unpin man <pkg> [<page>]`. For a multicall, name the page: `unpin man <pkg> <applet>` (e.g. `unpin man pciutils lspci`). Omit the section if no man ships.
- **`## Build locally`** (`nix build github:unpins/<pkg>` + `nix run`) and **`## Manual download`**.
- **We package, we don't plan upstream development.** The README describes what we ship; it must not contain roadmaps, porting plans, effort estimates, or "how someone could add platform X" write-ups. If a platform isn't shipped, say so in one line in `Build notes` and why (the upstream gap), and stop there — no speculative design. Porting belongs upstream or in an issue, never in the catalog README.

## 5. Build native

```bash
nix build --override-input unpins-lib path:../nix-lib .#packages.x86_64-linux.default
file -L result/bin/<pkg>                             # expect: ELF 64-bit ... statically linked
./result/bin/<pkg> --version                          # smoke test
```

If `pkgsStatic` fails on darwin (autoconf link probes), add a `build = pkgs: ...` closure to the consumer's `mkStandaloneFlake` call with the needed overrides — don't branch on system inside it; `mkStandaloneFlake` already handles per-target dispatch. See [platforms/darwin.md](platforms/darwin.md) for the canonical failure modes.

If a **transitive library** is what fails (not your package itself), check `nix-lib/native-overlay/` first and thread in `unpins-lib.lib.nativeFixes.<lib>` rather than re-deriving the override — see [Principles](#principles).

## 6. Build Windows

```bash
nix build --override-input unpins-lib path:../nix-lib .#packages.x86_64-linux.windows-x86_64
file -L result/bin/<pkg>.exe                          # expect: PE32+ ... for MS Windows
$(find /nix/store -name 'x86_64-w64-mingw32-objdump' | head -1) \
  -p result/bin/<pkg>.exe | grep 'DLL Name'           # expect only KERNEL32 / msvcrt / SHLWAPI etc.
```

Build **through `mingwStaticCross pkgs`** (in your `windowsBuild` closure), not raw `pkgsCross.mingwW64` — that's what applies the `mingw-overlay/` fixes (`libidn2`, `libpsl`, `ncurses`, …) transitively, so you don't re-fix a lib that's already handled. Same for cosmo via the cosmo cross set. See [Principles](#principles).

If a `lib*.dll` shows up, see [platforms/mingw.md](platforms/mingw.md) — the static-lib static-link toolbox covers most cases. If the build itself fails, the package may be one of the mingw dead-ends (bash, git — both blocked on POSIX assumptions in upstream + nixpkgs). Try the cosmo route via a `./cosmo.nix` sidecar — that's how `coreutils` ships its Windows build. See [platforms/cosmocc.md](platforms/cosmocc.md).

## 7. Handle runtime data if the package needs it

If the program needs files at runtime (a magic database, a syntax/runtime tree, completions), **embed them in the binary** — that's the norm and it keeps the single-binary contract. [runtime-data.md](runtime-data.md) has the two patterns (a compiled-in blob; an embedded ZIP + in-tool VFS) and how to verify nothing is read from `/nix/store`.

`package_data` (a companion `<pkg>-<tag>-data.tar.zst`) is **off by default** (`package_data ? false`) and is the fallback only for data that genuinely can't be embedded. Set `package_data = true` just for those: action-build then publishes `result/share/` and `unpin install` extracts it beside the binary — but the program must find that data relative to the executable, not via the baked-in `/nix/store` path, so patch the lookup ([runtime-data.md](runtime-data.md) has the `/proc/self/exe` / `_NSGetExecutablePath` / `GetModuleFileNameA` recipes). Most packages need none of this.

## 8. Update the website

Nothing per-package to hand-edit — `gen-packages.py` extracts version, SPDX
license, description, and the per-OS columns from one `nix eval` per package
(license via nix-lib's `meta.license` propagation; Windows from the
`"windows-x86_64"` attr). Just regenerate the table:

```bash
cd ../website && python3 gen-packages.py
```

License only needs attention when the artifact carries no `meta.license` (a
custom `mkDerivation`) or a noisy multi-license list — set the `license` arg in
your `mkStandaloneFlake` call (see `ffmpeg` / `python`), not in `gen-packages.py`.

## 9. First commit

```bash
git add -A
git commit -m "$(cat <<'EOF'
Initial <pkg> package: <short summary>

<details — what patches were needed, what's the bin size, etc.>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Use the standard co-author trailer for AI-assisted commits. The body should explain *why* a patch exists (the upstream behavior it works around), not what the code does.

## 10. Create the GitHub repo and push

```bash
gh repo create unpins/<pkg> --public \
  --description "$(grep -oP '(?<=^  description = ")[^"]+' flake.nix)"
git remote add origin https://github.com/unpins/<pkg>.git
git push -u origin main
```

The repo description must mirror the flake's `description` field verbatim (no trailing punctuation, no editorialization). The Build workflow fires automatically on push to `main`. The Release workflow is `workflow_dispatch` only — run `gh workflow run release.yml -R unpins/<pkg>` when ready to publish.

## 11. (Optional) Bump `website/`

Commit and push `website/packages.html` + `gen-packages.py` in the `website/` repo. The website is its own repo; bump it in a separate commit there.

## Checklist

- [ ] `flake.nix` calls `mkStandaloneFlake`
- [ ] `flake.lock` present (generated by `nix flake update`)
- [ ] `.gitignore` (3 lines)
- [ ] All upstream features enabled; any feature dropped because it's impossible on a target is noted in the README's Build notes with a one-line reason
- [ ] `README.md` follows the canonical template
- [ ] `CHANGELOG.md` from the template, with the initial release described under `## [Unreleased]` (see [releasing.md](releasing.md#changelog-and-release-notes))
- [ ] `.github/workflows/<pkg>.yml` and `release.yml`
- [ ] Native build: produces `statically linked` ELF on Linux, libSystem-only on macOS
- [ ] Windows build: produces PE32+ with only system DLLs imported
- [ ] Runtime data (if any) embedded and verified not to read from `/nix/store` (see [runtime-data.md](runtime-data.md))
- [ ] `packages.html` regenerated (license auto-derived from `meta.license`; set the `license` arg only if it's missing or noisy)
- [ ] Git repo initialized with `git init -b main`, first commit lands
- [ ] GitHub repo created, description matches `flake.nix`, `git push -u origin main`
