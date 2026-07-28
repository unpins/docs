# unpins

Native single-binary builds of common programs — `htop`, `jq`, `curl`, `tmux`, `tree`, `vim`, `gvim`, `coreutils`, `tar`, `file` — plus a Rust installer (`unpin`) that downloads them from GitHub releases. Each shipped artifact is one executable per OS, no third-party DLLs, no `/nix/store` closure at runtime.

Website: <https://unpins.org>. GitHub org: <https://github.com/unpins>.

## Workspace

Each top-level directory is an **independent git repo**:

- `unpin/` — Rust CLI installer.
- `nix-lib/` — shared `mkStandaloneFlake` + cosmocc toolchain (`lib.cosmoStdenv`; wires `pkgs.pkgsCross.cosmo` as a first-class cross target inside `windowsPkgs`) + cross overlay fragments (`native-overlay/`, `mingw-overlay/`, `cosmo/`). Per-binary quirks live inline in each consumer flake.
- One directory per package flake (e.g. `htop/`, `tree/`) — the [packages page](https://unpins.org/packages.html) has the current catalog.
- `action-build/` — reusable GitHub Actions workflows.
- `website/` — site source.
- `playground/<pkg>/` — work-in-progress packages (not consumed by `unpin` or the website). Each one is its own repo when ready for release; `playground/` itself is not.

Each pkg dir is its own repo — commit and push there, **not** from the workspace root.

## Non-negotiables

- **Single binary, no companion DLL/dylib/so.** Per-OS allow-list and CI enforcement: [dynamic-link-policy.md](dynamic-link-policy.md).
- **We never ship an APE.** Cosmopolitan, when used, is a **build-time POSIX-compatibility layer** for programs the mingw cross can't build (fork/waitpid/signals) — the shipped Windows artifact is always a single per-OS PE `.exe` (the cross stdenv's hook runs `apelink -V 4` to extract a Windows-only PE), **never** an APE fat/polyglot binary. The "one binary for all OSes" property of APE is a build intermediate, never the product. See [platforms/cosmocc.md](platforms/cosmocc.md).
- **Ship every upstream feature.** Build with all features ON; disable one only when it's genuinely impossible on a target (won't link static/musl, won't cross-compile, needs an OS API the target lacks) — never because it's easier. Note each dropped feature in the README's Build notes with a one-line reason. See [adding-a-package.md](adding-a-package.md#principles).
- **Reuse `nix-lib`'s fixes — don't re-derive them.** A transitive library that won't build static/cross usually already has a fix; `ls ../nix-lib/{native-overlay,mingw-overlay,cosmo}` *before* debugging. Native (`native-overlay/<lib>.nix`) is a function — call `unpins-lib.lib.nativeFixes.<lib> pkgs` and `.override` it in (not auto-applied to your deps). mingw/cosmo (`mingw-overlay/`, `cosmo/`) are real overlays — automatic when you build through `mingwStaticCross pkgs` / the cosmo cross set; raw `pkgsCross.mingwW64.<lib>` bypasses them and loses the fix. See [adding-a-package.md](adding-a-package.md#principles) + [architecture.md](architecture.md#where-per-target-quirks-live).
- **Per-binary quirks live inline in the consumer flake** — `build` / `windowsBuild` closures for native/mingw, a `./cosmo.nix` sidecar invoked via `windowsBuild = import ./cosmo.nix { inherit unpins-lib; }` for cosmocc — not in `nix-lib`. Shared library-dep tweaks consumed transitively by ≥ 2 packages live in `nix-lib/{native-overlay,mingw-overlay,cosmo}/<lib>.nix` (auto-discovered via `readDir`).
- **GitHub repo description = `flake.nix` `description` verbatim** at repo creation:
  ```
  gh repo create unpins/<pkg> --public \
    --description "$(grep -oP '(?<=^  description = ")[^"]+' flake.nix)"
  ```
- **The `unpin` Rust crate stays lint-clean.** Before every commit, both
  `cargo fmt --check` and `cargo clippy --all-targets` must pass with **zero
  warnings** — for the host target **and** the Windows cross-target
  (`cargo clippy --target x86_64-pc-windows-gnu --all-targets`), since a chunk
  of the code is `cfg(windows)`-only and never compiled by the host build.
  Reach for a scoped `#[allow(...)]` with a one-line justification only when a
  lint is a genuine false positive — never a crate-wide `allow`.

## Documentation

This file lives inside the `docs/` repo (`github:unpins/docs`); the rest of the documentation sits next to it. Read here before re-investigating any platform issue.

- [contributing.md](contributing.md) — where contributions go (multi-repo), conventions, commit trailer.
- [adding-a-package.md](adding-a-package.md) — checklist when scaffolding a new package.
- [releasing.md](releasing.md) — release flow, tag format, common failure modes.
- [architecture.md](architecture.md) — `mkStandaloneFlake`, where per-binary quirks live (inline) vs. transitive-lib overlay fragments (`nix-lib/{native,mingw}-overlay/`, `nix-lib/cosmo/`), `nix-lib` scope rule, refactor verification.
- [dynamic-link-policy.md](dynamic-link-policy.md) — what each OS may load dynamically.
- [messaging.md](messaging.md) — source of truth for external copy: slogan, the canonical project/package sentences, vocabulary (`programs` not `tools`; `self-contained` not `static`), per-surface hero emphasis.
- [static-linking.md](static-linking.md) — `pkgsStatic` gotchas independent of OS (propagation, `.pc`/`Requires.private`, aggressive DCE, eval blockers, musl probes).
- [runtime-data.md](runtime-data.md) — runtime data is embedded by default (vim/gvim ZIP+VFS, file compiled-in blob); the `package_data` companion archive is the opt-in fallback.
- [embedded-metadata.md](embedded-metadata.md) — the unified `unpin/` ZIP container embedded in every binary (aliases + man), byte-scan locator, `withAliases`/`withMan` glue, alias security model.
- [embedded-man.md](embedded-man.md) — `unpin man` is a **builtin** that renders embedded roff in-process via the `mandoc-sys` crate (vendored render-only mandoc, linked), paged by `unpin/src/render/`.
- [helper-verbs.md](helper-verbs.md) — the model for `unpin man`/`readme`/`search`/… : a verb is **builtin** when its renderer is small/shared (man, readme — folded back in for in-process reflow) or shipped as an `unpins/unpin-<verb>` package (e.g. a future `search`) reached only via `unpin <verb>`, never on `PATH`; dispatch precedence and the catalog naming reservation that keep the verb name from colliding with the OS or the catalog.
- [patches.md](patches.md) — patch-writing gotchas (regenerate via `diff -u`; where to apply; fake-static libs; symbol-collision recipe).
- [multicall.md](multicall.md) — folding many upstream executables into one `argv[0]`-dispatching binary (`ld -r` and reuse-the-link-line recipes).
- [platforms/mingw.md](platforms/mingw.md) — POSIX shim gaps, static-link pitfalls, fake-static libs, mingw blockers (bash/coreutils ship via cosmo; git is a mingw WIP).
- [platforms/darwin.md](platforms/darwin.md) — `pkgsStatic` semantics, cross within darwin, overlay cascade, dead ends.
- [platforms/cosmocc.md](platforms/cosmocc.md) — Cosmopolitan + `superconfigure` for mingw-blocked packages + first-class `pkgs.pkgsCross.cosmo` (wired via `applyPatches` + `replaceCrossStdenv` in `windowsPkgs`).
- [big-packages.md](big-packages.md) — ffmpeg-class playbook; static GTK2 recipe.
- [crypto-backend.md](crypto-backend.md) — prefer mbedtls over OpenSSL for static crypto: why, platform-conditional dep, per-consumer selectors, rtmpdump exception.
- [templates/](templates/) — minimal `flake.nix`, build/release workflow files.

## Source of authority

When two places disagree, the order is:

1. The code in the workspace itself (`nix-lib/flake.nix`, consumer flakes).
2. The documents in this directory.
3. This file.
4. Auto-memory (point-in-time, may be stale — verify before relying on it).
