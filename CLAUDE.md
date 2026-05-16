# unpins

Native single-binary builds of common CLI tools — `htop`, `jq`, `curl`, `tmux`, `tree`, `vim`, `gvim`, `coreutils`, `tar`, `file` — plus a Rust installer (`unpin`) that downloads them from GitHub releases. Each shipped artifact is one executable per OS, no third-party DLLs, no `/nix/store` closure at runtime.

Website: <https://unpins.org>. GitHub org: <https://github.com/unpins>.

## Workspace

Each top-level directory is an **independent git repo**:

- `unpin/` — Rust CLI installer.
- `nix-lib/` — shared `mkStandaloneFlake` + cosmocc toolchain (`lib.cosmoStdenv`, `lib.mkPkgsCosmo`) + per-target fix directories (`native/`, `mingw/`, `mingw-overlay/`, `cosmo/`).
- One directory per package flake (e.g. `htop/`, `tree/`) — the [packages page](https://unpins.org/packages.html) has the current catalog.
- `action-build/` — reusable GitHub Actions workflows.
- `website/` — site source.
- `playground/<pkg>/` — work-in-progress packages (not consumed by `unpin` or the website). Each one is its own repo when ready for release; `playground/` itself is not.

Each pkg dir is its own repo — commit and push there, **not** from the workspace root.

## Non-negotiables

- **Single binary, no companion DLL/dylib/so.** Per-OS allow-list and CI enforcement: [dynamic-link-policy.md](dynamic-link-policy.md).
- **Per-package quirks live in `nix-lib/{native,mingw,mingw-overlay,cosmo}/<pkg>.nix`** (auto-discovered via `readDir`), not as branching inside the consumer flake. One file per fix per target.
- **GitHub repo description = `flake.nix` `description` verbatim** at repo creation:
  ```
  gh repo create unpins/<pkg> --public \
    --description "$(grep -oP '(?<=^  description = ")[^"]+' flake.nix)"
  ```

## Documentation

This file lives inside the `docs/` repo (`github:unpins/docs`); the rest of the documentation sits next to it. Read here before re-investigating any platform issue.

- [contributing.md](contributing.md) — where contributions go (multi-repo), conventions, commit trailer.
- [adding-a-package.md](adding-a-package.md) — checklist when scaffolding a new package.
- [releasing.md](releasing.md) — release flow, tag format, common failure modes.
- [architecture.md](architecture.md) — `mkStandaloneFlake`, per-target fix directories, `nix-lib` scope rule, refactor verification.
- [dynamic-link-policy.md](dynamic-link-policy.md) — what each OS may load dynamically.
- [runtime-data.md](runtime-data.md) — packages with data files (vim, gvim, file pattern).
- [patches.md](patches.md) — patch-writing gotchas (regenerate via `diff -u`; where to apply; fake-static libs; symbol-collision recipe).
- [platforms/mingw.md](platforms/mingw.md) — POSIX shim gaps, static-link pitfalls, fake-static libs, blocked packages.
- [platforms/darwin.md](platforms/darwin.md) — `pkgsStatic` semantics, cross within darwin, overlay cascade, dead ends.
- [platforms/cosmocc.md](platforms/cosmocc.md) — Cosmopolitan + `superconfigure` for mingw-blocked packages + `lib.mkPkgsCosmo` cross overlay.
- [big-packages.md](big-packages.md) — ffmpeg-class playbook; static GTK2 recipe.
- [templates/](templates/) — minimal `flake.nix`, build/release workflow files.

## Commits

AI-assisted commits carry the trailer:

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Source of authority

When two places disagree, the order is:

1. The code in the workspace itself (`nix-lib/flake.nix`, consumer flakes).
2. The documents in this directory.
3. This file.
4. Auto-memory (point-in-time, may be stale — verify before relying on it).
