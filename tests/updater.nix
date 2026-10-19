{
  pkgs,
  ampinstmgr,
}: let
  # Throwaway signing keys: "fixture" is trusted by the test resolver and
  # "other" stands in for an attacker.
  keys =
    pkgs.runCommand "ampinstmgr-updater-fixture-keys" {
      nativeBuildInputs = [pkgs.gnupg];
    } ''
      for name in fixture other; do
        export GNUPGHOME="$TMPDIR/$name"
        mkdir -m 700 "$GNUPGHOME"
        gpg --batch --pinentry-mode loopback --passphrase "" \
          --quick-gen-key "$name <$name@example.invalid>" ed25519 sign never
        mkdir -p "$out/$name"
        gpg --batch --export > "$out/$name/keyring.gpg"
        gpg --batch --pinentry-mode loopback --passphrase "" \
          --export-secret-keys > "$out/$name/secret.gpg"
        gpgconf --kill gpg-agent
      done
    '';

  resolver = ampinstmgr.mkReleaseResolver {
    keyring = "${keys}/fixture/keyring.gpg";
    baseUrl = "file:///nonexistent";
  };
  updateScript = ampinstmgr.mkUpdateScript resolver;
in
  pkgs.runCommand "ampinstmgr-updater-fixture" {
    nativeBuildInputs = with pkgs; [
      diffutils
      gnupg
      jq
      openssl
    ];
  } ''
    set -euo pipefail

    for name in fixture other; do
      mkdir -m 700 "$TMPDIR/gnupg-$name"
      GNUPGHOME="$TMPDIR/gnupg-$name" gpg --batch --quiet \
        --import ${keys}/$name/secret.gpg
    done

    printf 'fixture archive\n' > "$TMPDIR/archive.deb"
    archive_sha256=$(sha256sum "$TMPDIR/archive.deb" | cut -d' ' -f1)

    stanza() {
      printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSHA256: %s\n\n' "$@"
    }

    # Write a flat repository under $1 from Packages on stdin, signed by $2.
    repo() {
      local dir=$1 signer=$2
      mkdir -p "$dir/debian"
      cat > "$dir/debian/Packages"
      printf 'Origin: fixture\nSuite: stable\nSHA256:\n %s %16s Packages\n' \
        "$(sha256sum "$dir/debian/Packages" | cut -d' ' -f1)" \
        "$(stat -c %s "$dir/debian/Packages")" > "$dir/Release"
      GNUPGHOME="$TMPDIR/gnupg-$signer" gpg --batch --quiet \
        --pinentry-mode loopback --passphrase "" \
        --clearsign --output "$dir/debian/InRelease" "$dir/Release"
      cp "$TMPDIR/archive.deb" "$dir/ampinstmgr-9999.0.0.0.x86_64.deb"
    }

    rejects() {
      local name=$1
      shift
      if AMP_REPO_URL="file://$TMPDIR/$name" "$@" > /dev/null 2>&1; then
        echo "repository '$name' must be rejected" >&2
        exit 1
      fi
    }

    valid() {
      stanza other-package 1.0 amd64 ./other-package-1.0.deb "$archive_sha256"
      stanza ampinstmgr 9999.0.0.0 amd64 ./ampinstmgr-9999.0.0.0.x86_64.deb "$archive_sha256"
    }

    # Valid repository
    valid | repo "$TMPDIR/valid" fixture
    AMP_REPO_URL="file://$TMPDIR/valid" ${resolver} > actual
    cat > expected <<EOF
    version=9999.0.0.0
    url=file://$TMPDIR/valid/ampinstmgr-9999.0.0.0.x86_64.deb
    sha256=$archive_sha256
    EOF
    diff -u expected actual

    # Signature, key and checksum failures
    valid | repo "$TMPDIR/tampered" fixture
    stanza ampinstmgr 9999.0.0.1 amd64 ./ampinstmgr-9999.0.0.1.x86_64.deb "$archive_sha256" \
      >> "$TMPDIR/tampered/debian/Packages"
    rejects tampered ${resolver}

    valid | repo "$TMPDIR/other-key" other
    rejects other-key ${resolver}

    valid | repo "$TMPDIR/unsigned" fixture
    cp "$TMPDIR/unsigned/Release" "$TMPDIR/unsigned/debian/InRelease"
    rejects unsigned ${resolver}

    rejects valid ${ampinstmgr.releaseResolver}

    # Malformed package indexes
    {
      valid
      stanza ampinstmgr 9999.0.0.1 amd64 ./ampinstmgr-9999.0.0.1.x86_64.deb "$archive_sha256"
    } | repo "$TMPDIR/two-stanzas" fixture
    rejects two-stanzas ${resolver}

    stanza other-package 1.0 amd64 ./other-package-1.0.deb "$archive_sha256" |
      repo "$TMPDIR/no-stanza" fixture
    rejects no-stanza ${resolver}

    stanza ampinstmgr 9999.0.0.0 arm64 ./ampinstmgr-9999.0.0.0.x86_64.deb "$archive_sha256" |
      repo "$TMPDIR/arm" fixture
    rejects arm ${resolver}

    stanza ampinstmgr 9999.0. amd64 ./ampinstmgr-9999.0..x86_64.deb "$archive_sha256" |
      repo "$TMPDIR/malformed-version" fixture
    rejects malformed-version ${resolver}

    stanza ampinstmgr 9999.0.0.0 amd64 ../ampinstmgr-9999.0.0.0.x86_64.deb "$archive_sha256" |
      repo "$TMPDIR/filename" fixture
    rejects filename ${resolver}

    stanza ampinstmgr 9999.0.0.0 amd64 ./ampinstmgr-9999.0.0.0.x86_64.deb "''${archive_sha256:1}" |
      repo "$TMPDIR/short-hash" fixture
    rejects short-hash ${resolver}

    # The update script rewrites only the version, hash and archive format.
    cp ${../package.nix} package.nix
    chmod u+w package.nix
    cp package.nix package.nix.orig

    UPDATE_NIX_OLD_VERSION=${ampinstmgr.version} \
      AMP_REPO_URL="file://$TMPDIR/valid" ${updateScript} > result.json
    jq -e '. == [{
      "attrPath": "ampinstmgr",
      "oldVersion": "${ampinstmgr.version}",
      "newVersion": "9999.0.0.0",
      "files": ["package.nix"]
    }]' result.json

    sri="sha256-$(openssl dgst -sha256 -binary "$TMPDIR/archive.deb" | base64)"
    test "$(grep -Fxc '    version = "9999.0.0.0";' package.nix)" = 1
    test "$(grep -Fxc "      hash = \"$sri\";" package.nix)" = 1
    test "$(grep -Fxc '  srcFormat = "deb";' package.nix)" = 1
    changed=$(diff package.nix.orig package.nix | grep -c '^[<>]' || true)
    case "${ampinstmgr.srcFormat}" in
      tgz) test "$changed" = 6 ;;
      deb) test "$changed" = 4 ;;
    esac

    # An unchanged version is a no-op.
    cp package.nix.orig package.nix
    stanza ampinstmgr ${ampinstmgr.version} amd64 ./ampinstmgr-${ampinstmgr.version}.x86_64.deb "$archive_sha256" |
      repo "$TMPDIR/current" fixture
    UPDATE_NIX_OLD_VERSION=${ampinstmgr.version} \
      AMP_REPO_URL="file://$TMPDIR/current" ${updateScript} > result.json
    jq -e '. == []' result.json
    cmp package.nix.orig package.nix

    touch "$out"
  ''
