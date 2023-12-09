{ lib
, fetchgit
, elpaBuild
}:

elpaBuild {
  pname = "typst-ts-mode";
  version = "git";

  src = fetchgit {
    url = "https://git.sr.ht/~meow_king/typst-ts-mode";
    hash = "sha256-okrkMrcEH1CdCs5uOYdxiOSJ5br3jPLw8cVExL+3jkA=";
  };
}
