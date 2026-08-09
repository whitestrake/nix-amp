{
  lib,
  pkgs,
  ...
}: {
  projectRootFile = "flake.nix";

  programs = {
    alejandra.enable = true;
    actionlint.enable = true;
    shellcheck.enable = true;
    yamlfmt = {
      enable = true;
      settings.formatter = {
        type = "basic";
        retain_line_breaks = true;
        scan_folded_as_literal = true;
        eof_newline = true;
      };
    };
    mdformat = {
      enable = true;
      settings.wrap = "keep";
    };
  };

  settings = {
    formatter.nil = {
      command = lib.getExe pkgs.nil;
      options = ["diagnostics" "--deny-warnings"];
      includes = ["*.nix"];
      type = "check";
    };

    formatter.shellcheck.options = ["-x"];
  };
}
