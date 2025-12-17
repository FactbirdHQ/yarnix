{
  inputs = {
    env = {
      url = "file+file:///dev/null";
      flake = false;
    };
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
    flakelight = {
      url = "github:accelbread/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    devenv,
    flakelight,
    ...
  } @ inputs:
    flakelight ./. {
      inherit inputs;
      nixpkgs.config = {allowUnfree = true;};
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
      packages = {
        devenv-up = {stdenv}: self.devShells.${stdenv.system}.default.config.procfileScript;
        devenv-test = {stdenv}: self.devShells.${stdenv.system}.default.config.test;
      };

      imports = [./yarnix-cli.nix ./mkYarnWrapper.nix ./mkYarnCache.nix ./mkYarnUnplugged.nix ./mkYarnRun.nix ./mkYarnProject.nix ./mkYarnWorkspace.nix];

      devShells.default = {pkgs}:
        devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              devenv.root = let env = builtins.fromJSON (builtins.readFile inputs.env.outPath); in env.PWD;
              packages = with pkgs.nodePackages; [
                nodejs
                yarn
              ];
            }
          ];
        };
    };
}
