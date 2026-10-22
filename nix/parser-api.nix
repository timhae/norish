{
  lib,
  python3,
  python3Packages,
  makeWrapper,
}:

let
  project = lib.importTOML ../apps/parser-api/pyproject.toml;
  version = project.project.version;

  dependencies = with python3Packages; [
    beautifulsoup4
    fastapi
    recipe-scrapers
    uvicorn
  ];

  pythonEnv = python3.withPackages (_: dependencies);
in
python3Packages.buildPythonApplication (finalAttrs: {
  pname = "norish-parser-api";
  inherit version;
  pyproject = true;
  src = ../apps/parser-api;

  build-system = [ python3Packages.setuptools ];
  inherit dependencies;

  # pyproject.toml pins exact versions for the uv lockfile; the nixpkgs
  # packages are newer but API-compatible.
  pythonRelaxDeps = true;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  disabledTests = [ ];

  postInstall = ''
    makeWrapper ${pythonEnv}/bin/python $out/bin/norish-parser-api \
      --add-flags "-m uvicorn app.main:app" \
      --prefix PYTHONPATH : "$out/${python3.sitePackages}"
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
