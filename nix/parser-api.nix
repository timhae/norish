{
  lib,
  python314,
  python314Packages,
  makeWrapper,
}:

let
  project = lib.importTOML ../apps/parser-api/pyproject.toml;
  version = project.project.version;

  dependencies = with python314Packages; [
    beautifulsoup4
    fastapi
    recipe-scrapers
    uvicorn
  ];

  pythonEnv = python314.withPackages (_: dependencies);
in
python314Packages.buildPythonApplication (finalAttrs: {
  pname = "norish-parser-api";
  inherit version;
  pyproject = true;
  src = ../apps/parser-api;

  # pyproject.toml points at a README that the application does not ship, and
  # it asks for 3.15 while nixpkgs' Python 3.15 package set is not usable yet.
  # The parser uses no 3.15-only syntax, so build it on the current stable
  # interpreter.
  postPatch = ''
    echo "# Norish parser API" > README.md
    substituteInPlace pyproject.toml \
      --replace-fail 'requires-python = ">=3.15,<3.16"' 'requires-python = ">=3.14,<3.16"'
  '';

  build-system = [ python314Packages.setuptools ];
  inherit dependencies;

  # pyproject.toml pins exact versions for the uv lockfile; the nixpkgs
  # packages are newer but API-compatible.
  pythonRelaxDeps = true;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python314Packages.pytestCheckHook ];

  disabledTests = [ ];

  postInstall = ''
    makeWrapper ${pythonEnv}/bin/python $out/bin/norish-parser-api \
      --add-flags "-m uvicorn app.main:app" \
      --prefix PYTHONPATH : "$out/${python314.sitePackages}"
  '';

  pythonImportsCheck = [ "app.main" ];

  passthru = {
    inherit dependencies pythonEnv;
    tests = { };
  };

  meta = {
    description = "FastAPI wrapper around recipe-scrapers used by Norish";
    homepage = "https://github.com/norish-recipes/norish";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "norish-parser-api";
  };
})
