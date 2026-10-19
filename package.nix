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
  dpkg,
  git,
  gawk,
  gnupg,
  gnugrep,
  gnused,
  gnutar,
  icu,
  iputils,
  numactl,
  openssl,
  runCommand,
  socat,
  tmux,
  unzip,
  wget,
  xz,
  zlib,
}: let
  # Archive format of the pinned release. The updater switches it to "deb" with
  # the first version bump taken from CubeCoders' signed apt repository.
  srcFormat = "tgz";

  # CubeCoders' apt repository signing key, pinned by fingerprint. A rotated key
  # fails here and needs a reviewed change to cubecoders-archive-key.asc.
  cubecodersKeyring =
    runCommand "cubecoders-archive-keyring" {
      nativeBuildInputs = [gnupg];
    } ''
      export GNUPGHOME="$TMPDIR/gnupg"
      mkdir -m 700 "$GNUPGHOME"
      gpg --batch --quiet --import ${./cubecoders-archive-key.asc}
      keys=$(gpg --batch --with-colons --list-keys)
      test "$(grep -c '^pub:' <<<"$keys")" = 1
      test "$(grep -m 1 '^fpr:' <<<"$keys" | cut -d: -f10)" = \
        50ED69D7E73CBCF4FB97910C33FB60CD1A773489
      gpg --batch --export 50ED69D7E73CBCF4FB97910C33FB60CD1A773489 > "$out"
    '';

  # Resolve the single ampinstmgr release in a signed flat apt repository and
  # print its version, download URL and SHA256 as key=value lines. Each step
  # fails closed: InRelease must verify against the keyring, Packages must
  # match the signed SHA256, and exactly one well-formed stanza is accepted.
  # AMP_REPO_URL overrides the repository for tests; the keyring is fixed.
  mkReleaseResolver = {
    keyring ? cubecodersKeyring,
    baseUrl ? "https://cdn-repo.c7rs.com",
  }:
    writeShellScript "ampinstmgr-release-resolver" ''
      set -euo pipefail

      base=''${AMP_REPO_URL:-${baseUrl}}
      work=$(${coreutils}/bin/mktemp -d)
      trap '${coreutils}/bin/rm -rf "$work"' EXIT

      ${lib.getExe curl} -fsSL "$base/debian/InRelease" -o "$work/InRelease"
      if ! ${gnupg}/bin/gpgv \
        --keyring ${keyring} \
        --output "$work/Release" \
        "$work/InRelease" 2>"$work/gpgv.log"; then
        ${coreutils}/bin/cat "$work/gpgv.log" >&2
        echo "InRelease signature verification failed" >&2
        exit 1
      fi

      packages_sha256=$(
        ${lib.getExe gawk} \
          '/^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $3 == "Packages" { print $1 }' \
          "$work/Release"
      )
      [[ "$packages_sha256" =~ ^[0-9a-f]{64}$ ]]

      ${lib.getExe curl} -fsSL "$base/debian/Packages" -o "$work/Packages"
      printf '%s  %s\n' "$packages_sha256" "$work/Packages" |
        ${coreutils}/bin/sha256sum --check --quiet --strict

      ${lib.getExe gawk} \
        'BEGIN { RS = "" } /(^|\n)Package: ampinstmgr(\n|$)/ { n++; print } END { exit n != 1 }' \
        "$work/Packages" > "$work/stanza" || {
        echo "expected exactly one ampinstmgr package" >&2
        exit 1
      }

      field() {
        ${lib.getExe gnused} -n "s/^$1: //p" "$work/stanza"
      }

      test "$(field Architecture)" = amd64
      version=$(field Version)
      [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]
      test "$(field Filename)" = "./ampinstmgr-$version.x86_64.deb"
      sha256=$(field SHA256)
      [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]

      printf 'version=%s\n' "$version"
      printf 'url=%s/ampinstmgr-%s.x86_64.deb\n' "$base" "$version"
      printf 'sha256=%s\n' "$sha256"
    '';

  releaseResolver = mkReleaseResolver {};

  # Update only the canonical version, fixed hash and archive format. Exact
  # match counts make a formatting or package-layout change fail closed for
  # human review.
  mkUpdateScript = resolver:
    writeShellScript "ampinstmgr-update" ''
      set -euo pipefail

      release=$(${resolver})
      latest=$(${lib.getExe gnused} -n 's/^version=//p' <<<"$release")
      url=$(${lib.getExe gnused} -n 's/^url=//p' <<<"$release")
      sha256=$(${lib.getExe gnused} -n 's/^sha256=//p' <<<"$release")

      if [[ "$latest" == "''${UPDATE_NIX_OLD_VERSION:?}" ]]; then
        printf '[]\n'
        exit 0
      fi
      test "$(
        printf '%s\n%s\n' "$UPDATE_NIX_OLD_VERSION" "$latest" |
          ${coreutils}/bin/sort -V |
          ${coreutils}/bin/tail -n 1
      )" = "$latest"

      archive=$(${coreutils}/bin/mktemp)
      trap '${coreutils}/bin/rm -f "$archive"' EXIT
      ${lib.getExe curl} -fsSL "$url" -o "$archive"
      printf '%s  %s\n' "$sha256" "$archive" |
        ${coreutils}/bin/sha256sum --check --quiet --strict
      hash="sha256-$(
        printf '%s' "$sha256" |
          ${coreutils}/bin/basenc --base16 --decode |
          ${coreutils}/bin/base64
      )"
      [[ "$hash" =~ ^sha256-[A-Za-z0-9+/=]+$ ]]

      test "$(${lib.getExe gnugrep} -Fxc "    version = \"''${UPDATE_NIX_OLD_VERSION}\";" package.nix)" = 1
      test "$(${lib.getExe gnugrep} -Ec '^      hash = "sha256-[A-Za-z0-9+/=]+";$' package.nix)" = 1
      test "$(${lib.getExe gnugrep} -Ec '^  srcFormat = "(tgz|deb)";$' package.nix)" = 1

      ${lib.getExe gnused} -i \
        "s|^    version = \"''${UPDATE_NIX_OLD_VERSION}\";$|    version = \"$latest\";|" \
        package.nix
      ${lib.getExe gnused} -i \
        "s|^      hash = \"sha256-[A-Za-z0-9+/=]*\";$|      hash = \"$hash\";|" \
        package.nix
      ${lib.getExe gnused} -i \
        's|^  srcFormat = "tgz";$|  srcFormat = "deb";|' \
        package.nix

      printf \
        '[{"attrPath":"ampinstmgr","oldVersion":"%s","newVersion":"%s","files":["package.nix"]}]\n' \
        "$UPDATE_NIX_OLD_VERSION" \
        "$latest"
    '';

  updateScript = mkUpdateScript releaseResolver;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ampinstmgr";
    version = "2.8.0.8";

    src = fetchurl {
      urls = [
        "https://github.com/whitestrake/nix-amp/releases/download/upstream-ampinstmgr-${finalAttrs.version}/ampinstmgr-${finalAttrs.version}.x86_64.${srcFormat}"
        "https://repo.cubecoders.com/ampinstmgr-${finalAttrs.version}.x86_64.${srcFormat}"
      ];
      hash = "sha256-ClZFvTGRSl42FYJcDiWDZ0BCgXCqq0AcyyriEq0ikbk=";
    };

    sourceRoot = ".";
    # A null attribute name is omitted, keeping the tgz derivation unchanged.
    ${
      if srcFormat == "deb"
      then "unpackCmd"
      else null
    } = "dpkg-deb -x \"$curSrc\" .";

    nativeBuildInputs =
      [
        autoPatchelfHook
        makeWrapper
      ]
      ++ lib.optional (srcFormat == "deb") dpkg;

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
      inherit mkReleaseResolver mkUpdateScript releaseResolver srcFormat;
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
