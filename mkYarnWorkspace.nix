_: {
  packages.mkYarnWorkspace = {
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
  in rec {
    yarn = mkYarnWrapper {inherit nodejs yarnSrc env;};
    cache = mkYarnCache {inherit token src yarn;};
    unplugged = mkYarnUnplugged {inherit src yarn cache;};
    run = mkYarnRun ({inherit yarn cache unplugged preRun;} // nodeOptions);
    mkProject = projOpts:
      mkYarnProject ({
          inherit yarn cache;
          rootSrc = opts.src;
          exclude = opts.exclude or [];
        }
        // nodeOptions // projOpts);
  };
}
