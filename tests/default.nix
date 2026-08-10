{
  ampModule,
  lib,
  pkgs,
  ampinstmgr,
}: let
  packageTests = import ./package.nix {inherit pkgs ampinstmgr;};
  moduleTests = import ./module.nix {inherit ampModule lib pkgs;};
in {
  package = ampinstmgr;
  package-contract = packageTests.contract;
  package-vm = packageTests.vm;
  module-contract = moduleTests.contract;
  module-vm = moduleTests.vm;
  container-runtimes = import ./containers.nix {inherit pkgs;};
  updater-fixture = import ./updater.nix {inherit pkgs ampinstmgr;};
}
