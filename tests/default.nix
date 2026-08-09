{
  pkgs,
  ampinstmgr,
}: let
  packageTests = import ./package.nix {inherit pkgs ampinstmgr;};
in {
  package = ampinstmgr;
  package-contract = packageTests.contract;
  package-vm = packageTests.vm;
}
