_: {
  packages.mkYarnProject = {
    pkgs,
    lib,
  }: {
    yarn,
    cache,
    rootSrc,
    ...
  } @ opts: let
    filteredSrc = lib.fileset.fileFilter (file:
      lib.any (regex: builtins.match regex file.name != null) [
        ".*.(t|j)sx?"
        "justfile"
        ".*.gql"
        ".*.graphqls"
        ".*.json"
        ".*.xlsx"
        ".*.xml"
        ".*.svg"
        ".*.gif"
        ".*.html"
        ".*.mp3"
        ".*.wsdl"
        ".*.pem"
        ".*.ts.snap"
      ])
    opts.src;

    # Create attribute set with paths to all Nodejs projects
    rootPackageJson = builtins.fromJSON (builtins.readFile (rootSrc + "/package.json"));
    projectPackageJson =
      if builtins.hasAttr "packageJson" opts
      then builtins.fromJSON (builtins.readFile opts.packageJson)
      else if builtins.hasAttr "src" opts
      then builtins.fromJSON (builtins.readFile (opts.src + "/package.json"))
      else rootPackageJson;
    inherit (rootPackageJson) workspaces;
    workspacePaths = builtins.listToAttrs (map (workspace: {
        inherit (builtins.fromJSON (builtins.readFile "${rootSrc}/${workspace}/package.json")) name;
        value = workspace;
      })
      workspaces);

    # Helper function to get workspace dependencies
    getWorkspaceDependencies = path: let
      packageJson = builtins.fromJSON (builtins.readFile path);
      dependencies =
        if builtins.hasAttr "dependencies" packageJson
        then packageJson.dependencies
        else {};
      devDependencies =
        if builtins.hasAttr "devDependencies" packageJson
        then packageJson.devDependencies
        else {};
      allDependencies = dependencies // devDependencies;
      workspaceDependencies = builtins.filter (dep: allDependencies.${dep} == "workspace:^") (builtins.attrNames allDependencies);
    in
      map (dep: workspacePaths."${dep}") workspaceDependencies;

    # Recursively collect all workspace dependencies
    collectWorkspaceDependencies = curDependencies: path: let
      directDependencies = getWorkspaceDependencies (rootSrc + "/${path}/package.json");
      newDeps = builtins.filter (path: !(builtins.elem path curDependencies)) directDependencies;
      allDependencies = builtins.foldl' collectWorkspaceDependencies (curDependencies ++ directDependencies) newDeps;
    in
      lib.unique (directDependencies ++ allDependencies);

    # Check if rootSrc is already a derivation, lib.sources-based value, or store path string
    # If so, we cannot use path operations or filesets on it
    # builtins.filterSource returns a store path string (starts with /nix/store/)
    isStorePath = builtins.isString rootSrc && lib.hasPrefix "/nix/store/" rootSrc;
    isPreFiltered = lib.isDerivation rootSrc || rootSrc ? _isLibCleanSourceWith || isStorePath;

    # Create filesets for all workspace (workspace:^) dependencies
    # Only compute these if rootSrc is not pre-filtered
    rootWorkspaceDependencies =
      if isPreFiltered then []
      else if builtins.hasAttr "packageJson" opts
      then getWorkspaceDependencies opts.packageJson
      else if builtins.hasAttr "src" opts
      then getWorkspaceDependencies (opts.src + "/package.json")
      else [];
    allWorkspaceDependencies = if isPreFiltered then [] else lib.unique (builtins.foldl' collectWorkspaceDependencies rootWorkspaceDependencies rootWorkspaceDependencies);
    workspaceDependencyFilesets = if isPreFiltered then [] else map (path: lib.fileset.fileFilter (file: lib.any (regex: builtins.match regex file.name != null) [".*(.(t|j)sx?|json|graphqls|gql)"]) (rootSrc + "/${path}")) allWorkspaceDependencies;
    workspaceDependencyFilesetsInstall = if isPreFiltered then [] else map (path: lib.fileset.fileFilter (file: lib.any (regex: builtins.match regex file.name != null) ["package\.json"]) (rootSrc + "/${path}")) allWorkspaceDependencies;

    yarnFiles = if isPreFiltered then null else lib.fileset.fileFilter (file:
      lib.any (regex: builtins.match regex file.name != null) [
        "common.just"
        "tsconfig.json"
        "tsconfig.ui.json"
        ".yarnrc.yml"
        ".pnp.loader.mjs"
      ])
    rootSrc;

    yarnInstallFiles = if isPreFiltered then null else lib.fileset.fileFilter (file:
      lib.any (regex: builtins.match regex file.name != null) [
        ".yarnrc.yml"
        ".pnp.cjs"
        ".pnp.loader.mjs"
        "yarn.lock"
      ])
    rootSrc;

    # If rootSrc is already a derivation (pre-filtered), use it directly
    # Otherwise, apply fileset filtering
    installSrc =
      if isPreFiltered then
        rootSrc
      else
        lib.fileset.toSource {
          root = rootSrc;
          fileset =
            let
              # Base fileset with existing filters
              baseFileset = lib.fileset.unions ([
                  yarnInstallFiles
                  (rootSrc + /modules/transpilation)
                  (rootSrc + /.yarn/plugins)
                  (rootSrc + /.yarn/releases)
                  (rootSrc + /.yarn/patches)
                ]
                ++ workspaceDependencyFilesetsInstall
                ++ (lib.optional (lib.hasAttr "src" opts) filteredSrc)
                ++ (lib.optional (lib.hasAttr "fileset" opts) opts.fileset)
                ++ (lib.optional (lib.hasAttr "packageJson" opts) opts.packageJson));

              # Apply exclusions if provided
              exclude = opts.exclude or [];
              excludedPaths = map (path:
                lib.fileset.maybeMissing (rootSrc + path)
              ) exclude;

              # Subtract excluded paths from base fileset
              finalFileset =
                if exclude != [] then
                  lib.fileset.difference baseFileset (lib.fileset.unions excludedPaths)
                else
                  baseFileset;
            in
              finalFileset;
        };

    projectSrc =
      if isPreFiltered then
        rootSrc
      else
        lib.fileset.toSource {
          root = rootSrc;
          fileset =
            let
              # Base fileset with existing filters
              baseFileset = lib.fileset.unions ([
                  yarnFiles
                  (rootSrc + /modules/transpilation)
                  (rootSrc + /.yarn/plugins)
                  (rootSrc + /.yarn/releases)
                  (rootSrc + /.yarn/patches)
                ]
                ++ (lib.optionals (!(lib.hasAttr "ignoreDependencySources" opts)) workspaceDependencyFilesets)
                ++ (lib.optional (lib.hasAttr "src" opts) filteredSrc)
                ++ (lib.optional (lib.hasAttr "fileset" opts) opts.fileset)
                ++ (lib.optional (lib.hasAttr "packageJson" opts) opts.packageJson));

              # Apply exclusions if provided
              exclude = opts.exclude or [];
              excludedPaths = map (path:
                lib.fileset.maybeMissing (rootSrc + path)
              ) exclude;

              # Subtract excluded paths from base fileset
              finalFileset =
                if exclude != [] then
                  lib.fileset.difference baseFileset (lib.fileset.unions excludedPaths)
                else
                  baseFileset;
            in
              finalFileset;
        };

    focusedProjectRoot = builtins.toJSON (rootPackageJson
      // {
        workspaces = ["modules/transpilation" workspacePaths."${projectPackageJson.name}"] ++ allWorkspaceDependencies;
        devDependencies = [];
      });

    focused-yarn-install = pkgs.stdenvNoCC.mkDerivation {
      name = "${lib.replaceStrings ["@"] [""] projectPackageJson.name}-focused-yarn-install";
      buildInputs = [yarn];
      src = installSrc;

      configurePhase = ''
        cp --reflink=auto --recursive ${cache} .yarn/cache
        chmod -R 755 .yarn/cache
        echo '${focusedProjectRoot}' > package.json

        export HOME="$TMP"
      '';

      buildPhase = ''
        pushd ${workspacePaths."${projectPackageJson.name}"}
        yarn install
        popd
      '';

      installPhase = ''
        mkdir -p $out/.yarn
        cp -R .yarn/cache $out/.yarn
        if [ -d .yarn/unplugged ]; then
          cp -R .yarn/unplugged $out/.yarn
        fi
        cp yarn.lock $out
        cp .pnp.cjs $out
        cp .pnp.loader.mjs $out
      '';

      dontFixup = true;
    };
    setNodeOptions =
      if (builtins.hasAttr "nodeOptions" opts)
      then "export NODE_OPTIONS=\"${opts.nodeOptions}\""
      else "";
  in
    pkgs.stdenvNoCC.mkDerivation ({
        buildInputs = [yarn pkgs.just pkgs.typeshare pkgs.jq] ++ (opts.buildInputs or []);
        src = projectSrc;
        configurePhase = ''
          echo '${focusedProjectRoot}' > package.json
          cp --reflink=auto --recursive ${focused-yarn-install}/.yarn/cache .yarn
          if [ -d ${focused-yarn-install}/.yarn/unplugged ]; then
            cp --reflink=auto --recursive ${focused-yarn-install}/.yarn/unplugged .yarn
          fi
          cp --reflink=auto --recursive ${focused-yarn-install}/yarn.lock .
          cp --reflink=auto --recursive ${focused-yarn-install}/.pnp.cjs .
          cp --reflink=auto --recursive ${focused-yarn-install}/.pnp.loader.mjs .

          export WORKSPACE_ROOT="$PWD"
          ${setNodeOptions}

          export HOME="$TMP"
        '';
        installPhase = ''
          if [ -d .webpack ]; then
            mv .webpack $out
          elif [ -d dist ]; then
            mv dist $out
          elif [ -d storybook-static ]; then
            mv storybook-static $out
          else
            mkdir -p $out
          fi
        '';
        dontFixup = true;
        doCheck = true;
        checkPhase = ''
          yarn tsc --noEmit
        '';
      }
      // (builtins.removeAttrs opts ["buildInputs" "ignoreDependencySources" "src" "rootSrc" "fileset" "yarn" "cache" "nodeOptions"]));
}
