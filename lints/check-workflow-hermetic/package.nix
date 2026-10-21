{
  lib,
  stdenvNoCC,
  makeWrapper,
  bashNonInteractive,
  yq-go,
  git,
  findutils,
  coreutils,
  gnugrep,
}:

stdenvNoCC.mkDerivation {
  pname = "check-workflow-hermetic";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./check-workflow-hermetic
      ../../lib/house-rules.bash
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  # In buildInputs so patchShebangs resolves `#!/usr/bin/env bash` to this bash.
  # The non-interactive build keeps readline and ncurses out of the closure.
  buildInputs = [ bashNonInteractive ];

  dontConfigure = true;
  dontBuild = true;

  # The script lives in libexec and bin/ holds a makeWrapper launcher, not a
  # wrapProgram rename: the launcher execs the script under its own name, so
  # `${0##*/}` in its messages reads `check-workflow-hermetic`.
  installPhase = ''
    runHook preInstall

    install -D --mode=0644 lib/house-rules.bash "$out/share/house-rules/house-rules.bash"
    install -D --mode=0755 lints/check-workflow-hermetic/check-workflow-hermetic \
      "$out/libexec/house-rules/check-workflow-hermetic"
    substituteInPlace "$out/libexec/house-rules/check-workflow-hermetic" \
      --replace-fail '@houseRulesLib@' "$out/share/house-rules/house-rules.bash"
    patchShebangs --host "$out/libexec/house-rules/check-workflow-hermetic"
    makeWrapper "$out/libexec/house-rules/check-workflow-hermetic" "$out/bin/check-workflow-hermetic" \
      --prefix PATH : ${
        lib.makeBinPath [
          yq-go
          git
          findutils
          coreutils
          gnugrep
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "Check that every GitHub Actions run step goes through the repo's devShell wrapper";
    mainProgram = "check-workflow-hermetic";
    platforms = lib.platforms.unix;
  };
}
