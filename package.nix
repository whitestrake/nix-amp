{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  bzip2,
  cacert,
  coreutils,
  git,
  gnutar,
  numactl,
  socat,
  tmux,
  unzip,
  wget,
  xz,
  zlib,
}:
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
    stdenv.cc.cc.lib
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p \
      "$out/bin" \
      "$out/opt/cubecoders" \
      "$out/share/ampinstmgr/upstream-systemd"

    cp -a opt/cubecoders/amp "$out/opt/cubecoders/"
    rm "$out/opt/cubecoders/amp/getamp"

    cp etc/ampinstmgr.conf "$out/share/ampinstmgr/"
    cp etc/systemd/system/* "$out/share/ampinstmgr/upstream-systemd/"

    ln -s ../opt/cubecoders/amp/ampinstmgr "$out/bin/ampinstmgr"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/opt/cubecoders/amp/ampinstmgr" \
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

  meta = {
    description = "Instance manager for CubeCoders AMP";
    homepage = "https://cubecoders.com/AMP";
    license = lib.licenses.unfree;
    platforms = ["x86_64-linux"];
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    mainProgram = "ampinstmgr";
  };
})
