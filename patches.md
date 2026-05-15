# Writing source patches

Things that have cost time and are easy to avoid.

## Always regenerate via `diff -u`

Never hand-edit patch headers (`@@ -line,count +line,count @@`). Apply the edits to a copy of the file, then `diff -u original.c modified.c > thing.patch`.

Why: `patch` is lenient with **context** (it'll fuzz a match by a few lines) but strict about line counts in the hunk header. A hand-counted hunk that's off by one will produce a "Hunk #N succeeded with fuzz 2" warning for *some* hunks while **silently dropping** the rest — the build then "succeeds" but the binary is missing your changes.

If the build succeeds but the binary doesn't have the strings/symbols your patch added:

```bash
strings result/bin/<pkg> | grep '<sentinel from your patch>'   # check first
nix log <drvpath> | grep -E 'Hunk|succeeded|FAILED|hunk'        # then check the log
```

`Hunk #1 succeeded ... ` with no mention of `Hunk #2` means hunk #2 silently failed — regenerate the patch.

## Use the existing path style

In nixpkgs-applied patches, paths are `--- a/src/file.c` / `+++ b/src/file.c`. `diff -u` defaults to absolute or relative paths that won't match — rewrite the two header lines after generating:

```bash
diff -u /tmp/file.c.orig /tmp/file.c.new \
  | sed -e '1c\--- a/src/file.c' -e '2c\+++ b/src/file.c' \
  > patches/file-thing.patch
```

## Patches must be byte-stable

Don't run a one-shot script in the consumer flake's `postPatch` to mutate the source — emit a patch file and add it to `patches`. The patch file is committed and stays the same across builds; an inline `substituteInPlace` is harder to audit and easier to break in a refactor.

Exception: very short, deterministic substitutions like dropping a single configure-time `-lresolv` probe (`fixes.tmux.native` does this). When the change is one `substituteInPlace --replace-fail`, inline is fine.

## Comment patches with *why*, not *what*

The diff already shows *what*. A leading comment block in the patch should explain the **upstream behavior** that makes the patch necessary, the **target platform** (mingw / darwin / both), and the **failure mode** without it. Example shape:

```diff
--- a/src/foo.h
+++ b/src/foo.h
@@ ... @@
+/* Upstream aliases X to Y on Windows as a legacy pre-mingw-w64 shim.
+ * Modern mingw-w64 ships X natively with 64-bit semantics, while Y
+ * stays 32-bit — keeping the alias causes a silent pointer mismatch
+ * in func(). Drop the alias on mingw. */
+#ifdef __DJGPP__   /* keep the DJGPP path */
 ...
```

Future-you will read the comment when bumping the upstream version; the diff alone won't tell you whether the patch is still relevant.

## Apply patches at the right layer

- **Native and Windows builds need the same change** → put the patch in the consumer flake's `mkStandaloneFlake { build = ...; windowsBuild = ...; }` (apply in both branches), or in the `fixes.<name>.{native,mingw}` registry entries.
- **Only Windows needs the change** → only in the mingw branch.
- **It's a fix to a transitive dep (e.g. libgnurx, libpsl)** → if the dep is reused (libpsl is shared by curl, wget, gnupg), add a `fixes.<dep>.mingwOverlay` entry in `nix-lib` so every consumer sees the fixed version. If only one consumer needs it (libgnurx for `file`), keep the override local to that consumer's flake.

## When `LDFLAGS=-all-static` isn't enough (mingw)

Some libraries shipped through `pkgsCross.mingwW64` only build a DLL plus an import library and symlink `libfoo.a` to `libfoo.dll.a`. libtool / `ld` picks it up and the binary ends up importing the DLL anyway, even with `LDFLAGS=-all-static`.

Diagnostic: `objdump -p result/bin/<pkg>.exe | grep 'DLL Name'` shows a `lib*.dll` entry that shouldn't be there.

Fix: rebuild the dep into a real static archive. If it's a single-source-file library (`libgnurx` is just `regex.o`):

```nix
libfooStatic = cross.windows.libfoo.overrideAttrs (old: {
  postBuild = (old.postBuild or "") + ''
    $AR rcs libfoo-real.a foo.o
  '';
  postInstall = ''
    install -m 644 libfoo-real.a $out/lib/libfoo.a
    rm -f $out/lib/libfoo.dll.a $out/lib/libfoo-impl.a
    rm -f $out/bin/libfoo-*.dll
    rmdir $out/bin 2>/dev/null || true
  '';
});

# Re-thread into the consumer:
my-pkg.override { libfoo = libfooStatic; };
```

See `file/flake.nix` for the canonical instance, and [platforms/mingw.md](platforms/mingw.md) for the broader mingw static-link toolbox.

## Symbol collisions when linking a whole program as a library

When statically linking a whole C program (e.g. `dash`) into another binary (e.g. `git`) as a "subsystem", **localize every symbol except the entry point** with `objcopy --keep-global-symbol=<entry>`:

```bash
$LD -r src/*.o src/bltin/*.o -o foo_combined.o
$OBJCOPY --keep-global-symbol=foo_main foo_combined.o
$AR rcs libfoo.a foo_combined.o
```

Without this, common names like `xwrite`, `error`, `init`, `signal`, `fork`, `exit`, `trap` collide silently with the host program's symbols (multiple-definition is a warning, not an error, especially under `--allow-multiple-definition`). The first definition wins and you get baffling runtime behavior — e.g. `git init` failing with "No space left on device" because dash's `xwrite` (returns 0 on success) ate git's `xwrite` (returns bytes-written).

Reference: `playground/git/bundle.nix` (embedded dash).
