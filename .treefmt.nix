{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    yamlfmt.enable = true;
    prettier = {
      enable = true;
      includes = [ "*.json" ];
    };
  };

  # shfmt via explicit entries rather than programs.shfmt: that module
  # hardcodes `-s` (simplify), which strips quotes inside `[[ ]]` and
  # contradicts the quote-every-expansion rule. Two entries because the bats
  # dialect is a parser flag that must not apply to the other files. The
  # extensionless scripts are listed by directory because treefmt matches on
  # globs, not shebangs.
  settings.formatter = {
    shfmt = {
      command = "${pkgs.shfmt}/bin/shfmt";
      options = [
        "--write"
        "--indent"
        "2"
        "--case-indent"
        "--binary-next-line"
        "--space-redirects"
      ];
      includes = [
        "*.bash"
        ".ci/*"
        ".githooks/*"
        "lints/*"
        "run-all-checks"
        "run-tests"
      ];
      # `lints/*` also matches each lint's package.nix, which is nixfmt's.
      excludes = [ "*.nix" ];
    };
    shfmt-bats = {
      command = "${pkgs.shfmt}/bin/shfmt";
      options = [
        "--write"
        "--indent"
        "2"
        "--case-indent"
        "--binary-next-line"
        "--space-redirects"
        "--language-dialect"
        "bats"
      ];
      includes = [ "*.bats" ];
    };
  };

  settings.global.excludes = [
    "flake.lock"
    # Managed centrally by tofu-github-repos; yamlfmt would strip its blank
    # lines and make it drift from the pushed copy.
    ".github/workflows/merge-gate.yml"
  ];
}
