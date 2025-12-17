_: {
  packages.mkYarnWorkspace = {
    lib,
    mkYarnWrapper,
    mkYarnCache,
    mkYarnUnplugged,
    mkYarnRun,
    mkYarnProject,
  }: {
    nodejs,
    yarnSrc,
    env,
    token,
    src,
    preRun,
    ...
  } @ opts: let
    nodeOptions =
      if (builtins.hasAttr "nodeOptions" opts)
      then {nodeOptions = opts.nodeOptions;}
      else {};

    # Apply filtering to create source hash based on included files only
    # This prevents rebuilds when excluded files change
    exclude = opts.exclude or [];
    filteredSrc =
      if exclude != [] then
        # Use cleanSourceWith to filter files at the path level
        # This works with builtins.readFile because it operates on paths
        lib.cleanSourceWith {
          src = src;
          filter = path: type:
            let
              pathStr = toString path;
              srcStr = toString src;
              # Get relative path from src root
              relPath = lib.removePrefix srcStr pathStr;
              # Check if path matches any exclusion pattern
              isExcluded = lib.any (excludePath:
                lib.hasPrefix excludePath relPath
              ) exclude;
            in
              !isExcluded;
        }
      else
        src;
  in rec {
    yarn = mkYarnWrapper {inherit nodejs yarnSrc env;};
    cache = mkYarnCache {
      token = token;
      src = filteredSrc;
      yarn = yarn;
    };
    unplugged = mkYarnUnplugged {
      src = filteredSrc;
      inherit yarn cache;
    };
    run = mkYarnRun ({inherit yarn cache unplugged preRun;} // nodeOptions);
    mkProject = projOpts:
      mkYarnProject ({
          inherit yarn cache;
          rootSrc = filteredSrc;
          # Don't pass exclude to mkYarnProject since filtering already applied
        }
        // nodeOptions // projOpts);
  };
}
