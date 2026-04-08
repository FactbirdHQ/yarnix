_: {
  packages.mkYarnCache = {
    pkgs,
    lib,
    ...
  }: {
    token,
    src,
    yarn,
  }: let
    # TODO: Replace with https://github.com/NixOS/nix/pull/7340
    jsonFromYaml = yaml:
      pkgs.runCommand "fromYAML" {}
      "${pkgs.yaml2json}/bin/yaml2json < ${yaml} > $out";

    # Yarn uses a locator hash to save dependency zip files in the Yarn cache to avoid duplications
    # yarn-cache/"${name}-${type}-${version}-${locator-hash}-${archive-hash}.zip"
    #getLocatorHash = resolution: (pkgs.runCommand "locator-hash-${resolution}" {} ''
    #    ${pkgs.yarnix-cli}/bin/yarnix-cli locator-hash "${resolution}" | cut -c-10 | tr -d '\n'  > $out'');

    # Yarn does not store checksums for optional dependencies, so we store checksums for these in npm-hashes.json
    npmHashes = builtins.fromJSON (builtins.readFile (src + "/npm-hashes.json"));

    # Read the yarn.lock as a Nix attrset
    deps =
      builtins.fromJSON (builtins.readFile (jsonFromYaml (src + "/yarn.lock")));

    # Yarn puts a prefix on checksums that define the compression of the dependency zip
    # We need to know the length of this prefix, so we can extract the actually checksum
    cacheKeyPrefixLength = builtins.stringLength deps.__metadata.cacheKey + 1;

    # Filter platform specific dependencies
    filterYarnConditions = {conditions, ...}: let
      systemInfo =
        {
          x86_64-linux = {
            os = "linux";
            cpu = "x64";
            libc = "glibc";
          };
          aarch64-linux = {
            os = "linux";
            cpu = "arm64";
            libc = "glibc";
          };
          x86_64-darwin = {
            os = "darwin";
            cpu = "x64";
          };
          aarch64-darwin = {
            os = "darwin";
            cpu = "arm64";
          };
        }
      .${
          pkgs.stdenv.system
        }
      or {
        };

      required =
        map (part: builtins.elemAt (builtins.split "=" part) 2)
        (builtins.filter (x: !(builtins.isList x))
          (builtins.split " & " conditions));

      actual = [systemInfo.os systemInfo.cpu systemInfo.libc];
    in
      builtins.all (x: x) (lib.zipListsWith (a: b: a == b) required actual);

    # Create an array of all (meaningful) dependencies
    depKeys = builtins.filter (depKey: let
      dep = builtins.getAttr depKey deps;
    in
      ((builtins.match "__metadata|.*@(workspace|file):.*" depKey) == null)
      && ((builtins.hasAttr "checksum" dep)
        || (builtins.hasAttr "conditions" dep && builtins.hasAttr dep.resolution npmHashes)
        || (filterYarnConditions dep)))
    (builtins.attrNames deps);

    fetchNpm = depKey: let
      dep = builtins.getAttr depKey deps;
      matchRes = builtins.match "(@[^/]*)?/?([^@]*)@npm:.*" dep.resolution;
      owner = builtins.elemAt matchRes 0;
      name =
        if matchRes != null
        then builtins.elemAt matchRes 1
        else throw "Npm dependency '${depKey}' is formatted wrongly";
      inherit (dep) version;
      hash =
        if (builtins.hasAttr "checksum" dep)
        then
          (builtins.substring cacheKeyPrefixLength
            (builtins.stringLength dep.checksum)
            dep.checksum)
        else null;
      outputHash =
        if hash != null
        then hash
        else if
          (builtins.hasAttr dep.resolution npmHashes
            && npmHashes.${dep.resolution} != "")
        then npmHashes.${dep.resolution}
        else
          (builtins.warn
            "'${dep.resolution}' is missing a checksum - please add the reported value to npm-hashes.json"
            lib.fakeSha512);
      prefix =
        if owner != null
        then "${owner}/${name}"
        else name;
      pkgName =
        if ((builtins.substring 0 1 prefix) == "@")
        then (builtins.substring 1 (builtins.stringLength prefix) prefix)
        else prefix;
      url = "https://registry.npmjs.org/${prefix}/-/${name}-${version}.tgz";
    in {
      inherit version prefix url hash;
      name = builtins.replaceStrings ["/"] ["-"] prefix;
      key = depKey;
      type = "npm";
      inherit (dep) resolution;
      archive = pkgs.fetchurl {
        name = "${pkgName}-${version}.zip";
        inherit url;
        sha512 = outputHash;
        curlOptsList = ["-LH" "Authorization: Bearer ${token}"];
        postFetch = ''
          ${pkgs.yarnix-cli}/bin/yarnix-cli tgz-to-zip "${prefix}" $out $out
        '';
      };
    };

    fetchPatch = depKey: let
      dep = builtins.getAttr depKey deps;
      matchRes = builtins.match "(@[^/]*)?/?([^@]*)@patch:.*" dep.resolution;
      owner = builtins.elemAt matchRes 0;
      name =
        if matchRes != null
        then builtins.elemAt matchRes 1
        else throw "Npm dependency '${depKey}' is wrongly formatted";
      inherit (dep) version;
      hash =
        if (builtins.hasAttr "checksum" dep)
        then
          (builtins.substring cacheKeyPrefixLength
            (builtins.stringLength dep.checksum)
            dep.checksum)
        else null;
      # Conditional dependencies in Yarn are without checksum - we store these explicitly instead as a workaround
      outputHash =
        if hash != null
        then hash
        else if
          (builtins.hasAttr dep.resolution npmHashes
            && npmHashes.${dep.resolution} != "")
        then npmHashes.${dep.resolution}
        else
          (builtins.warn
            "'${dep.resolution}' is missing a checksum - please add the reported value to npm-hashes.json"
            lib.fakeSha512);
      prefix =
        if owner != null
        then "${owner}/${name}"
        else name;
      pkgName =
        if ((builtins.substring 0 1 prefix) == "@")
        then (builtins.substring 1 (builtins.stringLength prefix) prefix)
        else prefix;
    in {
      inherit version prefix hash;
      type = "patch";
      name = builtins.replaceStrings ["/"] ["-"] prefix;
      key = depKey;
      inherit (dep) resolution;
      archive = pkgs.stdenvNoCC.mkDerivation {
        name = "${pkgName}-${version}.zip";
        inherit version;

        src = "${src}/.yarn/patches";

        dontUnpack = true;

        nativeBuildInputs = [pkgs.cacert];

        buildPhase = ''
          mkdir -p .yarn

          cp --reflink=auto --recursive $src/ .yarn/patches

          echo "With .yarn/patches/"
          ls .yarn/patches/

          export HOME=.
          touch package.json
          ${pkgs.yarnix-cli}/bin/yarnix-cli fetch-patch "${dep.resolution}" $out
        '';

        dontInstall = true;

        outputHashMode = "flat";
        outputHashAlgo = "sha512";
        inherit outputHash;
      };
    };

    fetchArchive = depKey: let
      dep = builtins.getAttr depKey deps;
      # Replace URL escapes
      resolution =
        builtins.replaceStrings ["%3A" "%2F" "%40"] [":" "/" "@"]
        dep.resolution;
      matchRes =
        builtins.match "((@[^/]*)?/?(.*))@.*::__archiveUrl=(https://.*/(.*))"
        resolution;
      name = builtins.elemAt matchRes 0;
      owner =
        if matchRes == null
        then throw "Archive dependency '${resolution}' is formatted wrongly"
        else builtins.elemAt matchRes 1;
      repo = builtins.elemAt matchRes 2;
      url = builtins.elemAt matchRes 3;
      rev = builtins.elemAt matchRes 4;
      hash =
        builtins.substring cacheKeyPrefixLength
        (builtins.stringLength dep.checksum)
        dep.checksum;
      key = "github:${owner}/${repo}#${rev}";
    in {
      name = builtins.replaceStrings ["/"] ["-"] name;
      type = "npm";
      inherit (dep) resolution version;
      inherit hash key;
      archive = pkgs.fetchurl {
        name = "${name}-${rev}.zip";
        inherit url;
        sha512 = hash;
        curlOptsList = ["-LH" "Authorization: Bearer ${token}"];
        postFetch = ''
          ${pkgs.yarnix-cli}/bin/yarnix-cli tgz-to-zip ${name} $out $out
        '';
      };
    };

    # Not currently used (Kept for potential future use)
    fetchGithub = depKey: let
      dep = builtins.getAttr depKey deps;
      matchRes =
        builtins.match
        "((@[^/]*)?/?(.*))@(git@github.com:|https://github.com/)(.*)#commit=(.*)"
        dep.resolution;
      name =
        if matchRes == null
        then throw "Github dependency '${dep.resolution}' is formatted wrongly"
        else builtins.elemAt matchRes 0;
      owner = builtins.elemAt matchRes 1;
      nixName = builtins.replaceStrings ["@" "/"] ["" "-"] name;
      repo = builtins.elemAt matchRes 2;
      path = builtins.elemAt matchRes 4;
      rev = builtins.elemAt matchRes 5;
      git = builtins.fetchGit {
        name = "${nixName}-${rev}.git";
        allRefs = true;
        url = "https://${token}@github.com/${path}";
        inherit rev;
      };
    in {
      inherit (dep) resolution;
      name = builtins.replaceStrings ["/"] ["-"] name;
      version = rev;
      key = "github:${owner}/${repo}#${rev}";
      type = "github";
      locator = dep.resolution;
      hash =
        builtins.substring cacheKeyPrefixLength
        (builtins.stringLength dep.checksum)
        dep.checksum;
      archive = pkgs.stdenv.mkDerivation {
        name = "${nixName}-${rev}.zip";
        buildInputs = [pkgs.gnutar yarn];
        unpackPhase = ''
          cp -ra ${git} ${repo}-${rev}
          (
            cd ${repo}-${rev};
            yarn pack --install-if-needed --out ../tarball.tgz;
          )
          ${pkgs.yarnix-cli}/bin/yarnix-cli tgz-to-zip ${name} tarball.tgz $out
        '';
      };
    };

    # Fetch source from each dependency
    sources = map (depKey: let
      dep = builtins.getAttr depKey deps;
    in
      if (builtins.match ".*@patch:.*" dep.resolution) != null
      then fetchPatch depKey
      else if (builtins.match ".*__archiveUrl.*" dep.resolution) != null
      then fetchArchive depKey
      else if (builtins.match ".*github.com.*" dep.resolution) != null
      then fetchGithub depKey
      else fetchNpm depKey)
    depKeys;

    # Create a derivation with the expected name in the cache
    mkSourceDrv = {
      archive,
      name,
      type,
      version,
      resolution,
      hash,
      ...
    }: let
      name-drv =
        if type == "patch"
        then "yarn-cache-${lib.replaceStrings ["@"] [""] name}-patch"
        else "yarn-cache-${lib.replaceStrings ["@"] [""] name}-${version}";
      hash10 =
        if hash == null
        then deps.__metadata.cacheKey # WARN: optional dependencies don't have checksums so they use cacheKey
        else builtins.substring 0 10 hash;
      zip-name =
        if type == "patch"
        then "${name}-${type}-$locator_hash-${hash10}.zip"
        else if type == "github"
        then "${name}-https-$locator_hash-${hash10}.zip"
        else "${name}-${type}-${version}-$locator_hash-${hash10}.zip";
    in
      pkgs.runCommand name-drv {} ''
        mkdir -p $out
        locator_hash=$(${pkgs.yarnix-cli}/bin/yarnix-cli locator-hash "${resolution}" | cut -c-10 | tr -d '\n')
        cp -L ${archive} $out/${zip-name}
      '';

    sourceDrvs = map mkSourceDrv sources;
  in
    pkgs.runCommand "yarn-cache" {} ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (deriv: ''
          cp -rL ${deriv}/* $out/
        '')
        sourceDrvs}
    '';
}
