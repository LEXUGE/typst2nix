{
  description = "typst2nix - Package Management and Tooling for Typst implemented in Nix ";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
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
        # Merging with prev.typst2nix.registery makes sure that order of overlay application doesn't matter
        typst2nix.registery =
          # Get prev if exists
          (if attrByPath [ "typst2nix" "registery" ] null prev != null then prev.typst2nix.registery else { })
          // (mapAttrsRecursive
            (n: v: (helpers.bundleTypstPkg
              {
                pkgs = final;
                path = v;
                namespace = head n;
              }))
            (helpers.listPackages "${official-packages}/packages"));
      });

      helpers = rec {
        buildTypst = { pkgs, pname, version, src, path, ext ? "pdf" }:
          let
            registery = pkgs.typst2nix.registery;
            dependencies = getDependencies [ ] registery src;
          in
          (pkgs.stdenv.mkDerivation rec {
            inherit pname version src;

            buildInputs = [ pkgs.typst ];
            env =
              let
                joinedDeps = pkgs.symlinkJoin {
                  name = pname + version + "joinedDeps";
                  paths = (map (p: attrByPath p.path null registery) dependencies);
                };
              in
              {
                XDG_DATA_HOME = joinedDeps;
              };

            buildPhase = ''
              mkdir $out
              typst compile ${path} $out/${pname}.${ext} --root .
            '';
          });

        # TODO: implement `exclude` keyword.
        bundleTypstPkg = { pkgs, path, namespace, }:
          let
            typstManifest = (importTOML (path + "/typst.toml"));
            registery = pkgs.typst2nix.registery;
          in
          (pkgs.stdenv.mkDerivation rec {
            pname = typstManifest.package.name;
            version = typstManifest.package.version;
            src = path;

            installPhase = ''
              mkdir -p $out/typst/packages/${namespace}/${pname}/${version}
              cp -r . $out/typst/packages/${namespace}/${pname}/${version}/
            '';

            passthru.typstDeps = getDependencies [ "${namespace}" "${pname}" ] registery path;
          });

        # Get collected dependencies (i.e. including the dependencies of the dependencies)
        # NOTE: An example of testing if collected dependency works: preview/anti-matter
        # NOTE: the entire dependecy resolution is doing some sort of passive failing
        # If a package cannot be found in registery, nothing happens.
        # Only will typst error if it is an actual package import (i.e. not in comment section)
        # This saves us from determining and/or wrangling with "fake import".
        getDependencies = selfPath: registery: path:
          flatten (map (p: [ p ] ++ (attrByPath (p.path ++ [ "passthru" "typstDeps" ]) [ ] registery))
            (getDependencies' selfPath path));

        # get dependencies of a specific package of a specific version using regex on each line.
        # regex for matching dependencies:
        # .*@([[:alnum:]]+)/([[:alnum:]]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*
        getDependencies' = selfPath: path:
          let
            filtered = filter (p: hasSuffix ".typ" p) (filesystem.listFilesRecursive path);
          in
          # Order matters, otherwise `take N null` will error
          filter (p: (p.path != null) && ((take 2 p.path) != selfPath)) (flatten (map
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
                (listPackages path)
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

        packages = {
          cetz-manual = (self.helpers.buildTypst rec {
            inherit pkgs;
            src = "${official-packages}/packages/preview/cetz/${version}";
            path = "./manual.typ";
            version = "0.1.2";
            pname = "cetz-manual";
          });

          anti-matter-manual = (self.helpers.buildTypst rec {
            inherit pkgs;
            src = "${official-packages}/packages/preview/anti-matter/${version}";
            path = "./docs/manual.typ";
            version = "0.1.1";
            pname = "anti-matter-manual";
          });

          physica-manual = (self.helpers.buildTypst rec {
            inherit pkgs;
            src = pkgs.fetchFromGitHub {
              owner = "Leedehai";
              repo = "typst-physics";
              rev = "v0.8.1";
              hash = "sha256-uyp2t8Fmewp7/yolFECSBkAH6iPvHKvzRqkC32SmWbo=";
            };
            path = "./physica-manual.typ";
            version = "git";
            pname = "physica-manual";
          });

          quill-guide = (self.helpers.buildTypst rec {
            inherit pkgs;
            src = pkgs.fetchFromGitHub {
              owner = "Mc-Zen";
              repo = "quill";
              rev = "fa4770a4beef1da987ed3146caa0d4afbb8ec1d8";
              hash = "sha256-L78Y+qXjyE8I8Mv56ZpjciACOBipSLoLJEdeieM/aBI=";
            };
            path = "./docs/guide/quill-guide.typ";
            version = "git";
            pname = "quill-guide";
          });
        };

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
        } // packages;
      });
}
