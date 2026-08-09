{
  description = "Unofficial Nix package and NixOS module for CubeCoders AMP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    treefmt-nix,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfreePredicate = package:
        builtins.elem (nixpkgs.lib.getName package) ["ampinstmgr"];
    };
    ampinstmgr = pkgs.callPackage ./package.nix {};
    treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
    darwinTreefmt =
      treefmt-nix.lib.evalModule (import nixpkgs {
        system = "aarch64-darwin";
      })
      ./treefmt.nix;
  in {
    packages.${system} = {
      inherit ampinstmgr;
      default = ampinstmgr;
    };

    checks.${system} =
      import ./tests {inherit pkgs ampinstmgr;}
      // {
        formatting = treefmt.config.build.check self;
      };

    formatter = {
      ${system} = treefmt.config.build.wrapper;
      aarch64-darwin = darwinTreefmt.config.build.wrapper;
    };
  };
}
