{
  description = "typst2nix - Package Management and Tooling for Typst implemented in Nix ";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
    # rust-overlay.url = "github:oxalica/rust-overlay";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    official-packages = {
      url = "github:typst/packages";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, utils, pre-commit-hooks, official-packages, ... }:
    with utils.lib;
    with nixpkgs.lib;
    with builtins;
    rec {
      overlays.default = (final: prev: {
        typst2nix.registery = (mapAttrsRecursive
          (n: v: (helpers.bundleTypstPkg
            {
              stdenv = prev.stdenv;
              path = v;
              namespace = head n;
              registery = final.typst2nix.registery;
            }))
          (helpers.listPackages "${official-packages}/packages"));
      });

      helpers = {
        buildTypstPdf = { pkgs, pname, version, src, path }:
          let
            registery = pkgs.typst2nix.registery;
            dependencies = flatten (map (p: [ p ] ++ (attrByPath (p.path ++ [ "passthru" "typstDeps" ]) [ ] registery)) (helpers.getDependencies src));
          in
          (pkgs.stdenv.mkDerivation rec {
            inherit pname version src;

            buildInputs = [ pkgs.typst ];
            env =
              let joinedDeps = pkgs.symlinkJoin { name = pname + version + "joinedDeps"; paths = (map (p: attrByPath p.path null registery) dependencies); };
              in
              {
                XDG_DATA_HOME = joinedDeps;
              };

            buildPhase = ''
              mkdir $out
              typst compile ${path} $out/${pname}.pdf
            '';
          });

        bundleTypstPkg = { stdenv, path, registery, namespace }:
          let
            typstManifest = (importTOML (path + "/typst.toml"));
            dependencies = (helpers.getDependencies path);
          in
          (stdenv.mkDerivation rec {
            pname = typstManifest.package.name;
            version = typstManifest.package.version;
            src = path;

            installPhase = ''
              mkdir -p $out/typst/packages/${namespace}/${pname}/${version}
              cp -r . $out/typst/packages/${namespace}/${pname}/${version}/
            '';

            passthru.typstDeps = flatten (map (p: [ p ] ++ (attrByPath (p.path ++ [ "passthru" "typstDeps" ]) [ ] registery)) dependencies);
            # passthru.typstDeps = dependencies;
          });

        # get dependencies of a specific package of a specific version using regex on each line.
        # regex for matching dependencies:
        # .*@([[:alnum:]]+)/([[:alnum:]]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*
        getDependencies = path:
          let
            filtered = filter (p: hasSuffix ".typ" p) (filesystem.listFilesRecursive path);
          in
          filter (p: p.path != null) (flatten (map
            (p:
              let
                lines = splitString "\n" (readFile p);
              in
              map
                (l: {
                  path = match ".*@([[:alnum:]]+)/([[:alnum:]]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*" l;
                })
                lines
            )
            filtered));

        listPackages = dir:
          let
            filtered = listToAttrs (filter ({ name, value }: value == "directory") (attrsToList (readDir dir)));
          in
          (mapAttrs
            (name: type:
              let path = dir + "/${name}";
              in
              # This signifies we have reached a package
              if pathExists (path + "/typst.toml") then
                path
              else
                (helpers.listPackages path)
            )
            filtered);
      };
    } //
    eachSystem defaultSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
      in
      rec {
        # nix develop
        devShells.default = pkgs.mkShell {
          inherit (self.checks.${system}.pre-commit-check) shellHook;
          nativeBuildInputs = with pkgs; [ typst typstfmt ];
        };

        packages.manual = (self.helpers.buildTypstPdf {
          inherit pkgs;
          # src = "${official-packages}/packages/preview/cetz/0.1.2";
          # path = "./manual.typ";
          src = ./.;
          path = "test.typ";
          version = "0.1.2";
          pname = "manual";
        });
        # packages = pkgs.typst2nix;

        checks = {
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixpkgs-fmt.enable = true;

              shellcheck.enable = true;
              shfmt.enable = true;

              typstfmt = {
                enable = true;
                name = "Typst Format";
                entry = "${pkgs.typstfmt}/bin/typstfmt";
                files = "\\.(typ)$";
              };
            };
          };
        };
      });
}
