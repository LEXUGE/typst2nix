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

    typst-ts-mode = {
      url = "git+https://git.sr.ht/~meow_king/typst-ts-mode";
      flake = false;
    };
  };
  outputs = { self, nixpkgs, utils, pre-commit-hooks, official-packages, typst-ts-mode, ... }:
    with utils.lib;
    with nixpkgs.lib;
    with builtins;
    rec {
      overlays = rec {
        default = registery;
        registery = (final: prev: {
          # Merging with prev.typst2nix.registery makes sure that order of overlay application doesn't matter
          typst2nix = {
            registery =
              # Get prev if exists
              (prev.typst2nix.registery or { }) // (mapAttrsRecursive
                (n: v: (helpers.bundleTypstPkg
                  {
                    pkgs = final;
                    path = v;
                    namespace = head n;
                  }))
                (helpers.listPackages "${official-packages}/packages"));
          };
        });

        emacsTooling = (final: prev: {
          typst-ts-mode = final.elpaBuild {
            pname = "typst-ts-mode";
            version = "git";
            src = "${typst-ts-mode}/typst-ts-mode.el";
          };
        });
      };

      helpers = rec {
        mkTypstEnv = pkgs: src:
          let
            registery = pkgs.typst2nix.registery;
            dependencies = getDependencies [ ] registery src;
          in
          pkgs.symlinkJoin {
            name = "typstEnv";
            paths = (map (p: attrByPath p.path null registery) dependencies);
          };

        mkWrappedTypst = pkgs: src: with pkgs; (runCommand "typst-wrapped"
          { nativeBuildInputs = [ makeWrapper ]; }
          ''
            mkdir -p $out/bin
            makeWrapper ${typst}/bin/typst $out/bin/typst --set XDG_DATA_HOME ${mkTypstEnv pkgs src}
          '');


        buildTypst = { pkgs, pname, version, src, path, ext ? "pdf" }:
          (pkgs.stdenv.mkDerivation rec {
            inherit pname version src;

            buildInputs = [ (mkWrappedTypst pkgs src) ];
            # Alternatively, use
            # env = {
            #   XDG_DATA_HOME = (mkTypstEnv pkgs src);
            # };

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
                  path = match ".*@([[:alnum:]-]+)/([[:alnum:]-]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*" l;
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
          # WARN: this may not work for other emacs distribution
          typst-ts-mode = ((pkgs.emacsPackagesFor pkgs.emacs29).overrideScope self.overlays.emacsTooling).typst-ts-mode;

          cetz-manual = (self.helpers.buildTypst rec {
            inherit pkgs;
            src = pkgs.fetchFromGitHub {
              owner = "cetz-package";
              repo = "cetz";
              rev = "e06775f273d03b07a3ef1734defff5121c03524b";
              hash = "sha256-zqU5GxRyAx7JtvOlH9YIyvhrbOV9o/2zWsoVe8A/Ah8=";
            };
            path = "./manual.typ";
            version = "0.2.2";
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
              rev = "v0.9.3";
              hash = "sha256-XfIKa2chLeX6fmIJ8wogCktMOe1L658SkrsjNihOWbs=";
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
              rev = "v0.2.1";
              hash = "sha256-LkasVbT769VzUtRuFXwCJ6aSEze9Gob5rlx61Z63qf4=";
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

              typstfmt = mkForce {
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
