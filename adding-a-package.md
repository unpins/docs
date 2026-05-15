# Adding a package

Order of operations when adding `<pkg>` to unpins, based on the file/htop/tree paths that have already worked.

## 1. Decide the scope up front

Before scaffolding, settle:

- **Does upstream already ship portable single-binary releases?** If `<owner>/<repo>` publishes statically-linked binaries for the platforms users care about (`ripgrep` is the canonical example — BurntSushi ships musl-static Linux, native macOS, and `.exe` for Windows on every release), **don't package it.** Users get the upstream binary directly via `unpin install <owner>/<repo>`, and that's the whole point. The catalog exists for tools whose upstream **doesn't** do this.
- Does `pkgs.pkgsStatic.<pkg>` already exist in nixpkgs? Check `nix eval nixpkgs#pkgsStatic.<pkg>.version`.
- Is Windows feasible? Try `nix eval --impure --expr '(import <nixpkgs> { config.allowUnsupportedSystem = true; }).pkgsCross.mingwW64.<pkg>.version'`. If the package fundamentally assumes POSIX (`fork`, signals, `/etc/<file>`, etc.) the mingw path is usually a dead end — see [platforms/mingw.md](platforms/mingw.md) and consider [platforms/cosmocc.md](platforms/cosmocc.md) instead.
- Does the package need runtime data files (config dir, magic database, syntax files)? If yes, plan to follow [runtime-data.md](runtime-data.md) (`package_data` is already on by default; the question is whether the binary's lookup path needs patching).
- License: SPDX id of the upstream license, to be added to `website/gen-packages.py`.

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

Edit `flake.nix`: set `description`, `name`, and any `build` / `windowsBuild` / `package_data` overrides. The minimum case (no quirks, three platforms) is ~16 lines — see `tree/flake.nix`.

## 3. Generate the lock file

```bash
cp ../tree/flake.lock .                              # seed
nix flake update                                     # bump to current nix-lib / nixpkgs
```

## 4. Write the README

Mirror `tree/README.md`:

- Title + one-line description.
- CI badge (`![CI](https://github.com/unpins/<pkg>/actions/workflows/<pkg>.yml/badge.svg)`).
- Platform badges (Linux/macOS, optionally Windows).
- One-line unpins blurb.
- Sections: `Installation` (with `unpin <pkg>` and `unpin run <pkg>`), `Build locally` (with `nix build github:unpins/<pkg>`), `Manual download`.
- Add a `Usage` section only when the binary's CLI is non-obvious (multicall dispatch like `coreutils --coreutils-prog=ls`, data-file conventions like `file`'s `magic.mgc` lookup).

## 5. Build native

```bash
nix build --override-input unpins-lib path:../nix-lib .#packages.x86_64-linux.default
file -L result/bin/<pkg>                             # expect: ELF 64-bit ... statically linked
./result/bin/<pkg> --version                          # smoke test
```

If `pkgsStatic` fails on darwin (autoconf link probes), add a `fixes.<pkg>.native` entry in `nix-lib/flake.nix` rather than branching inside the consumer flake. See [platforms/darwin.md](platforms/darwin.md) for the canonical failure modes.

## 6. Build Windows

```bash
nix build --override-input unpins-lib path:../nix-lib .#packages.x86_64-linux.windows-x86_64
file -L result/bin/<pkg>.exe                          # expect: PE32+ ... for MS Windows
$(find /nix/store -name 'x86_64-w64-mingw32-objdump' | head -1) \
  -p result/bin/<pkg>.exe | grep 'DLL Name'           # expect only KERNEL32 / msvcrt / SHLWAPI etc.
```

If a `lib*.dll` shows up, see [platforms/mingw.md](platforms/mingw.md) — the static-lib static-link toolbox covers most cases. If the build itself fails, the package may be one of the mingw dead-ends (bash, git, coreutils — all blocked on POSIX assumptions in upstream + nixpkgs).

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

The script also picks up `windows = true` / `windowsBuild = ...` / `"windows-x86_64"` from the flake to fill the Windows column.

## 9. First commit

```bash
git add -A
git commit -m "$(cat <<'EOF'
Initial <pkg> package: <short summary>

<details — what patches were needed, what's the bin size, etc.>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
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
