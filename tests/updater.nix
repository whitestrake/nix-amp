{
  pkgs,
  ampinstmgr,
}:
pkgs.runCommand "ampinstmgr-updater-fixture" {} ''
  cat > index.html <<'EOF'
  <a href="ampinstmgr-2.8.0.3.x86_64.tgz">old</a>
  <a href="ampinstmgr-2.8.0.4.x86_64.tgz">current</a>
  <a href="ampinstmgr-2.8.1.0.x86_64.tgz">latest</a>
  <a href="ampinstmgr-latest.x86_64.tgz">latest alias</a>
  <a href="ampinstmgr-2.8.2.0.x86_64.deb">deb</a>
  <a href="ampinstmgr-2.8.3.0-1.x86_64.rpm">rpm</a>
  <a href="ampinstmgr-2.8.4.0.aarch64.tgz">arm</a>
  <a href="ampinstmgr-2.8.5..x86_64.tgz">malformed</a>
  EOF

  ${ampinstmgr.versionParser} < index.html > actual

  cat > expected <<'EOF'
  2.8.0.3
  2.8.0.4
  2.8.1.0
  EOF

  diff -u expected actual

  if ${ampinstmgr.versionParser} </dev/null; then
    echo "empty indexes must fail closed" >&2
    exit 1
  fi

  touch "$out"
''
