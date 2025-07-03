{
  description = "typst2nix - Package Management and Tooling for Typst implemented in Nix ";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      utils,
      pre-commit-hooks,
      ...
    }:
    with utils.lib;
    with nixpkgs.lib;
    with builtins;
    {
      helpers = rec {
        # Control root with `src`, control the entry point with `main`
        buildTypstDoc =
          {
            pkgs,
            pname,
            version,
            src,
            main,
            ext ? "pdf",
            inputs ? { },
          }:
          let
            convertedInputs = foldr (a: b: a + " " + b) "" (
              mapAttrsToList (n: v: "--input " + n + "=" + v) inputs
            );
          in
          (pkgs.stdenv.mkDerivation rec {
            inherit pname version src;

            buildInputs = [
              (pkgs.typst.withPackages (extractDependencies {
                path = src;
              }))
            ];

            buildPhase = ''
              mkdir $out
              typst compile ${main} $out/${pname}.${ext} --root . ${convertedInputs}
            '';
          });

        # Extract dependencies of a typst document from source (including the dependencies of the dependencies)
        # extracted dependencies must be present in the registry at the moment.
        extractDependencies =
          {
            this ? null,
            path,
          }:
          registry:
          flatten (
            map (p: trace "[typst2nix] extracted dependency ${p.dep.name} from source" resolveDeps p.dep) (
              extractDependencies' { inherit this path; } registry
            )
          );

        # Recursively collect all dependencies of a typst package
        resolveDeps =
          typstPkg:
          flatten (
            [ typstPkg ]
            ++ (map (
              p: trace "[typst2nix] found ${typstPkg.name} depends on ${p.name}" (resolveDeps p)
            ) typstPkg.passthru.typstDeps)
          );

        toPackageName = lst: "${elemAt lst 0}_${replaceStrings [ "." ] [ "_" ] (elemAt lst 1)}";

        # get dependencies of source on a specific package of a specific version using regex on each line.
        # regex for matching dependencies:
        # .*@[[:alnum:]]+/([[:alnum:]]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*
        # returns
        # [
        #   "cetz"
        #   "0.4.0"
        # ]
        extractDependencies' =
          { this, path }:
          registry:
          let
            filtered = filter (p: hasSuffix ".typ" p) (filesystem.listFilesRecursive path);
          in
          filter (x: x.dep != this) (
            flatten (
              map (
                # for each typst source file path
                p:
                let
                  lines = splitString "\n" (readFile p);
                in
                map (l: {
                  dep =
                    let
                      dep' = match ".*@[[:alnum:]-]+/([[:alnum:]-]+):([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*" l;
                    in
                    if dep' != null then registry."${(toPackageName dep')}" else null;
                }) lines
              ) filtered
            )
          );
      };
    }
    // eachSystem defaultSystems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      rec {
        packages = {
          # Manual is no longer available in the latest cetz
          # cetz-manual = (
          #   self.helpers.buildTypstDoc rec {
          #     inherit pkgs;
          #     src = pkgs.fetchFromGitHub {
          #       owner = "cetz-package";
          #       repo = "cetz";
          #       rev = "v${version}";
          #       hash = "sha256-XaV4g/LOFGxh8zpQGwQPZrjIdlDxuhHJZpCN4Zp7gNU=";
          #     };
          #     main = "./manual.typ";
          #     version = "0.4.0";
          #     pname = "cetz-manual";
          #   }
          # );

          anti-matter-manual = (
            self.helpers.buildTypstDoc rec {
              inherit pkgs;
              src = pkgs.fetchFromGitHub {
                owner = "tingerrr";
                repo = "anti-matter";
                rev = "v${version}";
                hash = "sha256-J1ByutA/0ciP4/Q1N6ZJ71YNZpOH4XjxsD0+7DHl69M=";
              };
              main = "./docs/manual.typ";
              version = "0.1.1";
              pname = "anti-matter-manual";
            }
          );

          physica-manual = (
            self.helpers.buildTypstDoc rec {
              inherit pkgs;
              src = pkgs.fetchFromGitHub {
                owner = "Leedehai";
                repo = "typst-physics";
                rev = "v${version}";
                hash = "sha256-cMRjlmam97nl2A0SzaMUn6jDttcBE2sj90BF+jd5kpU=";
              };
              main = "./physica-manual.typ";
              version = "0.9.5";
              pname = "physica-manual";
            }
          );

          quill-guide = (
            self.helpers.buildTypstDoc rec {
              inherit pkgs;
              src = pkgs.fetchFromGitHub {
                owner = "Mc-Zen";
                repo = "quill";
                rev = "v${version}";
                hash = "sha256-/QTNzaqTUv2m5EqZI70I6nlqSo7aCR5oOWFdy3oFIZc=";
              };
              main = "./docs/guide/quill-guide.typ";
              version = "0.7.1";
              pname = "quill-guide";
            }
          );
        };

        checks = {
          pre-commit-check = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt-rfc-style.enable = true;

              shellcheck.enable = true;
              shfmt.enable = true;

              typstyle.enable = true;
            };
          };
        } // packages;
      }
    );
}
