{
  description = "Unofficial Nix package and NixOS module for CubeCoders AMP";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    mkPkgs = system:
      import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = package:
          builtins.elem (nixpkgs.lib.getName package) ["ampinstmgr"];
      };
    pkgs = mkPkgs system;
    mkFormatter = pkgs:
      pkgs.writeShellApplication {
        name = "treefmt";
        runtimeInputs = with pkgs; [
          actionlint
          alejandra
          mdformat
          nil
          shellcheck
          treefmt
          yamlfmt
        ];
        text = ''
          exec ${nixpkgs.lib.getExe pkgs.treefmt} \
            --config-file ${./treefmt.toml} \
            --tree-root-file flake.nix \
            "$@"
        '';
      };
    formatter = mkFormatter pkgs;
    formatting =
      pkgs.runCommand "formatting" {
        nativeBuildInputs = [formatter pkgs.gitMinimal];
      } ''
        cp -r ${self} source
        chmod -R u+w source
        cd source
        git init --quiet
        git add .
        treefmt --ci
        touch "$out"
      '';
    darwinFormatter = mkFormatter (mkPkgs "aarch64-darwin");
    ampinstmgr = pkgs.callPackage ./package.nix {};
  in {
    packages.${system} = {
      inherit ampinstmgr;
      default = ampinstmgr;
    };

    overlays.default = final: _prev: {
      ampinstmgr = final.callPackage ./package.nix {};
    };

    nixosModules = rec {
      amp = {lib, ...}: {
        imports = [./module.nix];
        services.amp.package =
          lib.mkDefault self.packages.${system}.ampinstmgr;
      };
      default = amp;
    };

    checks.${system} =
      import ./tests {
        inherit pkgs ampinstmgr;
        ampModule = ./module.nix;
        lib = nixpkgs.lib;
      }
      // {
        inherit formatting;
      };

    formatter = {
      ${system} = formatter;
      aarch64-darwin = darwinFormatter;
    };
  };
}
