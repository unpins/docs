{
  # Mirror this string in the GitHub repo description:
  #   gh repo create unpins/<pkg> --public --description "..."
  description = "Standalone build of <pkg>";

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

      # Set when the package's binary needs a `share/` data archive at runtime
      # (man pages, completions, syntax files, magic database, ...). action-build
      # publishes `result/share` as `<pkg>-<tag>-data.tar.zst`. See
      # docs/runtime-data.md when the binary's lookup path needs patching.
      # package_data = true;

      # When pkgsStatic.<pkg> + the fixes registry isn't enough, supply explicit
      # builders here. See e.g. file/flake.nix, tree/flake.nix, vim/flake.nix.
      # build       = pkgs: ...;
      # windowsBuild = pkgs: ...;

      # For Windows-only packages (no native build):
      # nativeBuild = false;
      # windows     = true;

      # Override when the binary's name differs from the package name (e.g.
      # multicall dispatch via a single binary):
      # binName = "<pkg>";
    };
}
