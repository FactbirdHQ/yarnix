_: {
  packages.mkYarnUnplugged = {
    pkgs,
    lib,
  }: {
    src,
    cache,
    yarn,
  }: let
    findFolders = path:
      builtins.foldl' (acc: elem: let
        prefix =
          if builtins.length acc == 0
          then ""
          else "${lib.last acc}/";
      in
        acc ++ ["${prefix}${elem}"]) [] (lib.splitString "/" path);

    inherit (builtins.fromJSON (builtins.readFile (src + "/package.json"))) workspaces;
    packageJsonFolders = lib.unique (lib.flatten (map findFolders workspaces));
    packageJsonFiles = map (workspace: "${workspace}/package.json") workspaces;
    files = ["package.json" ".yarnrc.yml" ".pnp.cjs" ".pnp.loader.mjs" ".npmrc" "yarn.lock" ".yarn"] ++ packageJsonFolders ++ packageJsonFiles;

    # Check if src is already a derivation, lib.sources-based value, or store path
    isStorePath = builtins.isString src && lib.hasPrefix "/nix/store/" src;
    isPreFiltered = lib.isDerivation src || src ? _isLibCleanSourceWith || isStorePath;

    yarnSrc = if isPreFiltered then
      src
    else
      pkgs.lib.fileset.toSource {
        root = src;
        fileset = pkgs.lib.fileset.unions [
          (lib.fileset.fromSource (pkgs.lib.cleanSourceWith {
            inherit src;
            filter = path: type: let
              relPath = builtins.concatStringsSep "/" (lib.drop 4 (lib.splitString "/" (toString path)));
              fileNameMatching = lib.any (name: name == relPath) files;
            in
              fileNameMatching;
          }))
          (src + "/.yarn/patches")
          (src + "/.yarn/releases")
          (src + "/.yarn/plugins")
        ];
      };
  in
    pkgs.stdenvNoCC.mkDerivation {
      name = "yarn-unplugged";
      src = yarnSrc;

      buildInputs = [yarn];

      configurePhase = ''
        cp --reflink=auto --recursive ${cache} .yarn/cache

        export HOME="$TMP"
      '';

      buildPhase = ''
        yarn install --immutable --immutable-cache

        cp --reflink=auto --recursive .yarn/unplugged $out
      '';

      dontFixup = true;
    };
}
