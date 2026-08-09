{
  pkgs,
  ampinstmgr,
}: {
  package = ampinstmgr;
  package-contract = import ./package.nix {inherit pkgs ampinstmgr;};
}
