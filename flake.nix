{
  description = "Markdown to HTML static site generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        site = pkgs.callPackage ./package.nix { };
      in
      {
        packages.default = site;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            ninja
            pandoc
            zsh
          ];
          shellHook = ''
            mkdir -p "$out"
            ${site.mkBuildNinja {
              inherit (site) buildNinja;
              src = "$PWD";
              out = "$out";
            }}
            export PROMPTPREFIX=saltydragons
          '';
        };
      }
    );
}
