{
  # Mirror this string in the GitHub repo description:
  #   gh repo create unpins/<pkg> --public --description "..."
  description = "<pkg> as a single self-contained binary";

  # Pulls pre-built artifacts from the unpins binary cache. Same on every
  # consumer flake — don't customize.
  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "<pkg>";

      # CI smoke: argv to run + pattern the output must match.
      smoke = [ "--version" ];
      smokePattern = "^<pkg> [0-9]+\\.[0-9]+";

      # Build via the unpin-llvm engine (the catalog default for C/C++) and
      # declare the shipped programs — one entry for a single-program package,
      # several for a multicall. See docs/architecture.md#the-unpin-llvm-engine
      # and docs/multicall.md.
      engine = "unpin-llvm";
      multicall = {
        programs = [ { name = "<pkg>"; } ];
        # windows = true;        # self-fold the mingw .exe's dispatcher too
      };

      # When pkgsStatic.<pkg> isn't enough, supply explicit builders here. Enable
      # ALL upstream features; reuse nix-lib's library fixes rather than
      # re-deriving them (native: unpins-lib.lib.nativeFixes.<lib>; mingw/cosmo:
      # build through the cross set). See docs/adding-a-package.md#principles and
      # e.g. file/flake.nix, tree/flake.nix, vim/flake.nix.
      # build        = pkgs: ...;
      # windowsBuild = pkgs: ...;                              # mingw quirks
      # windowsBuild = import ./cosmo.nix { inherit unpins-lib; };  # cosmo sidecar

      # Run the upstream test suite on the native CI jobs where it passes
      # (see docs/testing.md); leave it off with a one-line reason otherwise.
      # doCheck via build closure:
      #   doCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;

      # For Windows-only packages (no native build):
      # nativeBuild = false;
      # windows     = true;

      # Rare fallback for runtime data that genuinely can't be embedded
      # (docs/runtime-data.md — embedding is the norm; only nmap uses this):
      # package_data = true;

      # Override when the binary's name differs from the package name:
      # binName = "<pkg>";
    };
}
