{
  lib,
  stdenv,
  fetchurl,
  writeShellScript,
  autoPatchelfHook,
  makeWrapper,
  bzip2,
  cacert,
  coreutils,
  curl,
  git,
  gnugrep,
  gnused,
  gnutar,
  icu,
  numactl,
  nix,
  openssl,
  socat,
  tmux,
  unzip,
  wget,
  xz,
  zlib,
}: let
  versionParser = writeShellScript "ampinstmgr-version-parser" ''
    set -euo pipefail

    versions=$(
      ${lib.getExe gnugrep} -oE \
        'ampinstmgr-[0-9]+(\.[0-9]+)*\.x86_64\.tgz' |
        ${lib.getExe gnused} -E \
          's/^ampinstmgr-([0-9.]+)\.x86_64\.tgz$/\1/' |
        ${coreutils}/bin/sort -Vu
    )

    test -n "$versions"
    printf '%s\n' "$versions"
  '';

  versionLister = writeShellScript "ampinstmgr-version-lister" ''
    set -euo pipefail
    ${lib.getExe curl} -fsSL https://repo.cubecoders.com/ | ${versionParser}
  '';

  updateScript = writeShellScript "ampinstmgr-update" ''
    set -euo pipefail

    latest=$(${versionLister} | ${coreutils}/bin/tail -n 1)
    if [[ "$latest" == "''${UPDATE_NIX_OLD_VERSION:?}" ]]; then
      printf '[]\n'
      exit 0
    fi
    test "$(
      printf '%s\n%s\n' "$UPDATE_NIX_OLD_VERSION" "$latest" |
        ${coreutils}/bin/sort -V |
        ${coreutils}/bin/tail -n 1
    )" = "$latest"

    url="https://repo.cubecoders.com/ampinstmgr-$latest.x86_64.tgz"
    archive=$(mktemp)
    trap 'rm -f "$archive"' EXIT
    ${lib.getExe curl} -fsSL "$url" -o "$archive"
    hash=$(${lib.getExe nix} hash file "$archive")
    [[ "$hash" =~ ^sha256-[A-Za-z0-9+/=]+$ ]]

    test "$(${lib.getExe gnugrep} -Fxc "    version = \"''${UPDATE_NIX_OLD_VERSION}\";" package.nix)" = 1
    test "$(${lib.getExe gnugrep} -Ec '^      hash = "sha256-[A-Za-z0-9+/=]+";$' package.nix)" = 1

    ${lib.getExe gnused} -i \
      "s|^    version = \"''${UPDATE_NIX_OLD_VERSION}\";$|    version = \"$latest\";|" \
      package.nix
    ${lib.getExe gnused} -i \
      "s|^      hash = \"sha256-[A-Za-z0-9+/=]*\";$|      hash = \"$hash\";|" \
      package.nix

    printf \
      '[{"attrPath":"ampinstmgr","oldVersion":"%s","newVersion":"%s","files":["package.nix"]}]\n' \
      "$UPDATE_NIX_OLD_VERSION" \
      "$latest"
  '';
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ampinstmgr";
    version = "2.8.0.4";

    src = fetchurl {
      url = "https://repo.cubecoders.com/ampinstmgr-${finalAttrs.version}.x86_64.tgz";
      hash = "sha256-JFqSOyig3q/o5Y+0K7WsS0MEWnVD3SP1auA92qNYwpo=";
    };

    sourceRoot = ".";

    nativeBuildInputs = [
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = [
      icu
      stdenv.cc.cc.lib
      zlib
    ];

    runtimeDependencies = [
      icu
      (lib.getLib openssl)
    ];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p \
        "$out/bin" \
        "$out/lib/systemd/system" \
        "$out/opt/cubecoders" \
        "$out/share/ampinstmgr"

      cp -a opt/cubecoders/amp "$out/opt/cubecoders/"
      rm "$out/opt/cubecoders/amp/getamp"

      cp etc/ampinstmgr.conf "$out/share/ampinstmgr/"
      cp etc/systemd/system/* "$out/lib/systemd/system/"

      ln -s ../opt/cubecoders/amp/ampinstmgr "$out/bin/ampinstmgr"

      runHook postInstall
    '';

    postFixup = ''
      wrapProgram "$out/opt/cubecoders/amp/ampinstmgr" \
        --chdir "$out/opt/cubecoders/amp" \
        --set NIX_LD ${stdenv.cc.bintools.dynamicLinker} \
        --set NIX_LD_LIBRARY_PATH ${lib.makeLibraryPath [
        icu
        (lib.getLib openssl)
        stdenv.cc.cc.lib
        zlib
      ]} \
        --prefix PATH : ${lib.makeBinPath [
        bzip2
        coreutils
        git
        gnutar
        numactl
        socat
        tmux
        unzip
        wget
        xz
      ]} \
        --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt
    '';

    passthru = {
      inherit versionLister versionParser;
      updateScript = {
        command = [updateScript];
        supportedFeatures = ["commit"];
      };
    };

    meta = {
      description = "Instance manager for CubeCoders AMP";
      homepage = "https://cubecoders.com/AMP";
      license = lib.licenses.unfree;
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      mainProgram = "ampinstmgr";
    };
  })
