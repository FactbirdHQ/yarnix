_: {
  packages.mkYarnProject = {
    pkgs,
    lib,
  }: {
    yarn,
    cache,
    rootSrc,
    workspaceDependencies ? null,
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

    # Compute workspace dependencies from package.json
    # This works regardless of whether rootSrc is pre-filtered
    # We need to detect dependencies from opts.src or opts.packageJson when available
    rootWorkspaceDependencies =
      if workspaceDependencies != null then workspaceDependencies
      else if builtins.hasAttr "packageJson" opts
      then getWorkspaceDependencies opts.packageJson
      else if builtins.hasAttr "src" opts
      then getWorkspaceDependencies (opts.src + "/package.json")
      else [];

    # Recursively collect all workspace dependencies
    allWorkspaceDependencies =
      if workspaceDependencies != null then workspaceDependencies
      else lib.unique (builtins.foldl' collectWorkspaceDependencies rootWorkspaceDependencies rootWorkspaceDependencies);

    # Create filesets for workspace dependencies - only when rootSrc is not pre-filtered
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

    # Required files for yarn install that must always be included
    # These are computed from repoRoot when it's provided
    repoRootYarnInstallFiles =
      if lib.hasAttr "repoRoot" opts then
        lib.fileset.fileFilter (file:
          lib.any (regex: builtins.match regex file.name != null) [
            ".yarnrc.yml"
            ".pnp.cjs"
            ".pnp.loader.mjs"
            "yarn.lock"
          ])
        opts.repoRoot
      else null;

    # Workspace dependency package.json files when using repoRoot
    # These are needed for yarn to recognize the workspaces
    repoRootWorkspaceDependencyPackageJsons =
      if lib.hasAttr "repoRoot" opts && workspaceDependencies != null then
        map (path: opts.repoRoot + "/${path}/package.json") workspaceDependencies
      else [];

    # Workspace dependency source filesets when using repoRoot
    # These are needed for the build to resolve workspace imports
    repoRootWorkspaceDependencyFilesets =
      if lib.hasAttr "repoRoot" opts && workspaceDependencies != null then
        map (path: lib.fileset.fileFilter (file: lib.any (regex: builtins.match regex file.name != null) [".*(.(t|j)sx?|json|graphqls|gql)"]) (opts.repoRoot + "/${path}")) workspaceDependencies
      else [];

    # If rootSrc is already a derivation (pre-filtered), use it directly
    # Otherwise, apply fileset filtering
    # When repoRoot and fileset are provided, merge opts.fileset with required yarn files
    installSrc =
      if lib.hasAttr "fileset" opts && lib.hasAttr "repoRoot" opts then
        lib.fileset.toSource {
          root = opts.repoRoot;
          fileset = lib.fileset.unions ([
            repoRootYarnInstallFiles
            (opts.repoRoot + /modules/transpilation)
            (opts.repoRoot + /.yarn/plugins)
            (lib.fileset.maybeMissing (opts.repoRoot + /.yarn/releases))
            (opts.repoRoot + /.yarn/patches)
            (lib.fileset.maybeMissing (opts.repoRoot + /.yarn/unplugged))
            opts.fileset
          ] ++ repoRootWorkspaceDependencyPackageJsons);
        }
      else if isPreFiltered then
        rootSrc
      else if builtins.hasAttr "src" opts then
        # When src is provided, use the full rootSrc for yarn install
        # The focused install will still work correctly as it uses the workspacePaths
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
                  (lib.fileset.maybeMissing (rootSrc + /.yarn/releases))
                  (rootSrc + /.yarn/patches)
                  (lib.fileset.maybeMissing (rootSrc + /.yarn/unplugged))
                ]
                ++ workspaceDependencyFilesetsInstall
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
      if lib.hasAttr "fileset" opts && lib.hasAttr "repoRoot" opts then
        lib.fileset.toSource {
          root = opts.repoRoot;
          fileset = lib.fileset.unions ([opts.fileset] ++ repoRootWorkspaceDependencyFilesets);
        }
      else if isPreFiltered then
        rootSrc
      else if builtins.hasAttr "src" opts then
        # When src is provided, use the full rootSrc as the project source
        # The buildPhase will `cd` into the appropriate directory
        # This maintains backward compatibility with the `src = ./.;` pattern
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
                  (lib.fileset.maybeMissing (rootSrc + /.yarn/releases))
                  (rootSrc + /.yarn/patches)
                ]
                ++ (lib.optionals (!(lib.hasAttr "ignoreDependencySources" opts)) workspaceDependencyFilesets)
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

    # Allow preserving full workspaces list for packages that need to
    # read all workspace paths (e.g., CDK synth that generates CI configs)
    focusedProjectRoot = builtins.toJSON (rootPackageJson
      // {
        workspaces =
          if opts.preserveAllWorkspaces or false
          then rootPackageJson.workspaces
          else ["modules/transpilation" workspacePaths."${projectPackageJson.name}"] ++ allWorkspaceDependencies;
        devDependencies = [];
      });

    # Check if we're using the repoRoot + fileset pattern
    usesRepoRootFileset = lib.hasAttr "fileset" opts && lib.hasAttr "repoRoot" opts;

    focused-yarn-install = pkgs.stdenvNoCC.mkDerivation {
      name = "${lib.replaceStrings ["@"] [""] projectPackageJson.name}-focused-yarn-install";
      buildInputs = [yarn];
      # When using repoRoot + fileset, installSrc is already a toSource result
      # When pre-filtered, use installSrc directly
      # Otherwise, installSrc is a fileset that needs to be converted
      src = if usesRepoRootFileset || isPreFiltered
        then installSrc
        else lib.fileset.toSource {
          root = rootSrc;
          fileset = installSrc;
        };

      configurePhase = ''
        mkdir -p .yarn
        cp --reflink=auto --recursive ${cache} .yarn/cache
        chmod -R 755 .yarn/cache
        echo '${focusedProjectRoot}' > package.json

        export HOME="$TMP"
        export YARN_ENABLE_GLOBAL_CACHE=false

        yarn config set enableNetwork false
      '';

      buildPhase = ''
        # Save original files - yarn install will regenerate them with fewer packages
        # which breaks resolution at runtime
        echo "=== DEBUG: Files before yarn install ==="
        ls -la .pnp.* yarn.lock 2>/dev/null || echo "No pnp/yarn.lock files found"

        cp yarn.lock yarn.lock.original
        if [ -f .pnp.cjs ]; then
          echo "=== DEBUG: Saving original .pnp.cjs ==="
          cp .pnp.cjs .pnp.cjs.original
        else
          echo "=== DEBUG: .pnp.cjs NOT FOUND ==="
        fi
        if [ -f .pnp.loader.mjs ]; then
          cp .pnp.loader.mjs .pnp.loader.mjs.original
        fi
        # Save original unplugged directory - focused install may not unplug all packages
        if [ -d .yarn/unplugged ]; then
          echo "=== DEBUG: Saving original .yarn/unplugged ==="
          cp -R .yarn/unplugged .yarn/unplugged.original
        fi

        pushd ${workspacePaths."${projectPackageJson.name}"}
        YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn install
        popd

        echo "=== DEBUG: Files after yarn install ==="
        ls -la .pnp.* yarn.lock* 2>/dev/null || echo "No pnp/yarn.lock files found"
      '';

      installPhase = ''
        mkdir -p $out/.yarn
        cp -R .yarn/cache $out/.yarn
        # Copy the focused-install's unplugged directory
        if [ -d .yarn/unplugged ]; then
          cp -R .yarn/unplugged $out/.yarn
        fi
        # Use the ORIGINAL files to preserve all package mappings
        # The focused install removes packages from .pnp.cjs and version aliases from yarn.lock
        cp yarn.lock.original $out/yarn.lock
        if [ -f .pnp.cjs.original ]; then
          cp .pnp.cjs.original $out/.pnp.cjs
          # Copy unplugged packages to match ALL virtual hashes expected by original .pnp.cjs
          # The focused install creates packages with different virtual hashes than the original
          # A package may have multiple virtual instances (different hashes) for different consumers
          if [ -d $out/.yarn/unplugged ]; then
            cd $out/.yarn/unplugged
            for focused_dir in */; do
              # Remove trailing slash
              focused_dir_clean=$(echo "$focused_dir" | sed 's|/$||')
              # Extract package name (everything before -virtual-)
              pkg_name=$(echo "$focused_dir_clean" | sed 's/-virtual-.*//')
              focused_hash=$(echo "$focused_dir_clean" | sed 's/.*-virtual-//')
              # Find ALL hashes expected by .pnp.cjs for this package (not just the first one)
              for original_hash in $(grep -oP "$pkg_name-virtual-\K[a-f0-9]+" $out/.pnp.cjs 2>/dev/null | sort -u); do
                target_dir="$pkg_name-virtual-$original_hash"
                if [ ! -d "$target_dir" ]; then
                  echo "Copying unplugged package: $focused_dir_clean -> $target_dir"
                  cp -R "$focused_dir_clean" "$target_dir"
                fi
              done
            done
            cd - > /dev/null
          fi
        else
          cp .pnp.cjs $out
        fi
        if [ -f .pnp.loader.mjs.original ]; then
          cp .pnp.loader.mjs.original $out/.pnp.loader.mjs
        else
          cp .pnp.loader.mjs $out
        fi
      '';

      dontFixup = true;
    } // (
      if usesRepoRootFileset || isPreFiltered
      then { src = installSrc; }
      else {
        fileset = lib.fileset.toSource {
          root = rootSrc;
          fileset = installSrc;
        };
      }
    );
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

          if [ -d .yarn ]; then
            chmod -R +w .yarn 2>/dev/null || rm -rf .yarn
          fi
          mkdir -p .yarn

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
      // (builtins.removeAttrs opts ["buildInputs" "ignoreDependencySources" "src" "rootSrc" "fileset" "yarn" "cache" "nodeOptions" "repoRoot" "workspaceDependencies" "packageJson"]));
}
