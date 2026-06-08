# Adding a package

Order of operations when adding `<pkg>` to unpins, based on the file/htop/tree paths that have already worked.

## 1. Decide the scope up front

Before scaffolding, settle:

- **Does upstream already ship portable single-binary releases?** If `<owner>/<repo>` publishes statically-linked binaries for the platforms users care about (`ripgrep` is the canonical example — BurntSushi ships musl-static Linux, native macOS, and `.exe` for Windows on every release), **don't package it.** Users get the upstream binary directly via `unpin install <owner>/<repo>`, and that's the whole point. The catalog exists for programs whose upstream **doesn't** do this.
- Does `pkgs.pkgsStatic.<pkg>` already exist in nixpkgs? Check `nix eval nixpkgs#pkgsStatic.<pkg>.version`.
- Is Windows feasible? Try `nix eval --impure --expr '(import <nixpkgs> { config.allowUnsupportedSystem = true; }).pkgsCross.mingwW64.<pkg>.version'`. If the package fundamentally assumes POSIX (`fork`, signals, `/etc/<file>`, etc.) the mingw path is usually a dead end — see [platforms/mingw.md](platforms/mingw.md) and consider [platforms/cosmocc.md](platforms/cosmocc.md) instead.
- Does the package need runtime data files (config dir, magic database, syntax files)? If yes, plan to follow [runtime-data.md](runtime-data.md) — embed them in the binary (a compiled-in blob, or an embedded ZIP + VFS). `package_data` (a companion `.tar.zst`) is off by default and only for data that can't be embedded.
- **Reserved name?** A catalog *program* may not take the bare name of a helper verb (`man` today; `readme`/`search`/`changelog`/… later). Those names route to the `unpins/unpin-<verb>` helper packages through the verb dispatch (see [helper-verbs.md](helper-verbs.md)), so a program of the same bare name would be reachable only as `unpin run <name>`, never `unpin <name>`. A real general-purpose man, for instance, ships under its upstream name (`mandoc` / `man-db`), never `man`.
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
```

Edit `flake.nix`: set `description`, `name`, and any `build` / `windowsBuild` / `package_data` overrides. For a cosmocc Windows build, write `windowsBuild = import ./cosmo.nix { inherit unpins-lib; };` and put the recipe in a sibling `./cosmo.nix` (see [platforms/cosmocc.md](platforms/cosmocc.md)). The minimum case (no quirks, three platforms) is ~16 lines — see `tree/flake.nix`.

## 3. Generate the lock file

```bash
cp ../tree/flake.lock .                              # seed
nix flake update                                     # bump to current nix-lib / nixpkgs
```

## 4. Write the README

Start from [`templates/README.md`](templates/README.md) — fill the `<…>` slots and delete the guidance comments. Filled references: `tree/README.md` (single command), `flac/README.md` (multicall). What the template encodes:

- Title + one-line description, CI badge (`![CI](https://github.com/unpins/<pkg>/actions/workflows/<pkg>.yml/badge.svg)`), platform badges (Linux/macOS, optionally Windows), one-line unpins blurb.
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

## 6. Build Windows

```bash
nix build --override-input unpins-lib path:../nix-lib .#packages.x86_64-linux.windows-x86_64
file -L result/bin/<pkg>.exe                          # expect: PE32+ ... for MS Windows
$(find /nix/store -name 'x86_64-w64-mingw32-objdump' | head -1) \
  -p result/bin/<pkg>.exe | grep 'DLL Name'           # expect only KERNEL32 / msvcrt / SHLWAPI etc.
```

If a `lib*.dll` shows up, see [platforms/mingw.md](platforms/mingw.md) — the static-lib static-link toolbox covers most cases. If the build itself fails, the package may be one of the mingw dead-ends (bash, git — both blocked on POSIX assumptions in upstream + nixpkgs). Try the cosmo route via a `./cosmo.nix` sidecar — that's how `coreutils` ships its Windows build. See [platforms/cosmocc.md](platforms/cosmocc.md).

## 7. Handle runtime data if the package needs it

`package_data` is already `true` by default in `mkStandaloneFlake`. action-build conditions the `.tar.zst` step on `result/share/` existing, so packages that don't produce a `share/` subtree (jq, htop, ...) silently skip it. You don't need to do anything for them.

For packages that **do** have a `share/` subtree, two things matter:

1. The `<pkg>-<tag>-data.tar.zst` companion will be published automatically. `unpin install` downloads and extracts it next to the binary.
2. If the binary looks up runtime files via absolute paths baked at compile time (the common case — autotools' `--datadir=<prefix>/share`), the compiled path points into `/nix/store/...` and won't exist on the user's machine. Patch the binary to look relative to the executable instead. See [runtime-data.md](runtime-data.md) for `/proc/self/exe` (Linux) and `_NSGetExecutablePath` (macOS) recipes.

To suppress the companion entirely (rare — only if `share/` exists but you don't want it shipped), set `package_data = false` explicitly.

## 8. Update the website

In `website/gen-packages.py`:

```python
LICENSE = {
    ...
    "<pkg>": "<SPDX-id>",
    ...
}
```

Regenerate the table:

```bash
cd ../website && python3 gen-packages.py
```

The script also picks up `windows = true` / `windowsCosmo = true` / `windowsBuild = ...` / `"windows-x86_64"` from the flake to fill the Windows column.

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
- [ ] `README.md` follows the canonical template
- [ ] `.github/workflows/<pkg>.yml` and `release.yml`
- [ ] Native build: produces `statically linked` ELF on Linux, libSystem-only on macOS
- [ ] Windows build: produces PE32+ with only system DLLs imported
- [ ] Runtime-data lookup verified if the package has a `share/` subtree (see [runtime-data.md](runtime-data.md))
- [ ] `gen-packages.py` LICENSE entry added; `packages.html` regenerated
- [ ] Git repo initialized with `git init -b main`, first commit lands
- [ ] GitHub repo created, description matches `flake.nix`, `git push -u origin main`
