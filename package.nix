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
  iputils,
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
  # Accept only exact versioned x86_64 archives from CubeCoders' listing.
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

  # Update only the canonical version and fixed hash. Exact match counts make a
  # formatting or package-layout change fail closed for human review.
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
    version = "2.8.0.8";

    src = fetchurl {
      urls = [
        "https://github.com/whitestrake/nix-amp/releases/download/upstream-ampinstmgr-${finalAttrs.version}/ampinstmgr-${finalAttrs.version}.x86_64.tgz"
        "https://repo.cubecoders.com/ampinstmgr-${finalAttrs.version}.x86_64.tgz"
      ];
      hash = "sha256-ClZFvTGRSl42FYJcDiWDZ0BCgXCqq0AcyyriEq0ikbk=";
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
      # getamp is the mutable host installer; the Nix package owns installation.
      rm "$out/opt/cubecoders/amp/getamp"

      cp etc/ampinstmgr.conf "$out/share/ampinstmgr/"
      # module.nix imports these upstream units, then applies NixOS drop-ins.
      cp etc/systemd/system/* "$out/lib/systemd/system/"

      ln -s ../opt/cubecoders/amp/ampinstmgr "$out/bin/ampinstmgr"

      runHook postInstall
    '';

    # The wrapper supports both the manager and mutable payloads AMP downloads
    # after the Nix build has completed.
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
        # AMP uses ping for network reachability checks.
        iputils
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
