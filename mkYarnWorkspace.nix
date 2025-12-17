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

    # Apply exclusions at the workspace level to create filtered source
    # This ensures ALL components (cache, unplugged, project) use the filtered source
    exclude = opts.exclude or [];
    filteredSrc =
      if exclude != [] then
        lib.fileset.toSource {
          root = src;
          fileset =
            let
              # Include all files by default
              baseFileset = lib.fileset.gitTracked src;

              # Exclude specified paths
              excludedPaths = map (path:
                lib.fileset.maybeMissing (src + path)
              ) exclude;
            in
              lib.fileset.difference baseFileset (lib.fileset.unions excludedPaths);
        }
      else
        src;
  in rec {
    yarn = mkYarnWrapper {inherit nodejs yarnSrc env;};
    cache = mkYarnCache {token = token; src = filteredSrc; yarn = yarn;};
    unplugged = mkYarnUnplugged {src = filteredSrc; inherit yarn cache;};
    run = mkYarnRun ({inherit yarn cache unplugged preRun;} // nodeOptions);
    mkProject = projOpts:
      mkYarnProject ({
          inherit yarn cache;
          rootSrc = filteredSrc;
          exclude = []; # Already applied at workspace level
        }
        // nodeOptions // projOpts);
  };
}
