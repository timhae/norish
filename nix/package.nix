{
  lib,
  stdenv,
  nodejs_26,
  pnpm_12,
  pnpmConfigHook,
  fetchPnpmDeps,
  python3,
  makeWrapper,
  autoPatchelfHook,
  patchelf,
  patchelfUnstable,
  zlib,
  libpq,
  ...
}:

let
  packageJson = lib.importJSON ../package.json;
  version = packageJson.version;

  pnpm = pnpm_12;

  # prebuilt libvips-cpp (from sharp) has its .init right after the program
  # headers, so growing RUNPATH relocates the section. patchelf < 0.19.1
  # leaves DT_INIT pointing at the old address, and Node segfaults while
  # dlopen()ing the library. Prefer the fixed stable package, and fall back
  # to the unstable snapshot on channels where the default is still old.
  patchelfForBinaries =
    if lib.versionAtLeast patchelf.version "0.19.1" then patchelf else patchelfUnstable;

  # Development files, build output and the parked workspaces that the web
  # build never reads. pnpm still needs the package.json of every lockfile
  # importer, so apps/mobile and apps/landing stay in the source.
  excludedPaths = [
    ../.git
    ../.github
    ../.scratch
    ../.turbo
    ../.runtime
    ../node_modules
    ../apps/docs
    ../apps/quick-import-extension
    ../apps/parser-api/.venv
    ../apps/web/.next
    ../apps/web/__tests__/e2e/.results
    ../apps/web/__tests__/e2e/.runtime
  ];

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference (lib.fileset.unions [ ../. ]) (
      lib.fileset.unions (map lib.fileset.maybeMissing excludedPaths)
    );
  };

  runtimeRoot = "${placeholder "out"}/lib/norish";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "norish";
  inherit version src;

  nativeBuildInputs = [
    nodejs_26
    pnpm
    pnpmConfigHook
    python3
    makeWrapper
    patchelfForBinaries
    autoPatchelfHook
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    libpq
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      ;
    inherit pnpm;
    fetcherVersion = 5;
    hash = "sha256-p3YdVunecVGb3+cgTQ/y+uh3KmR1lcy+8bRNBZ3fz3M=";
  };

  env = {
    # The parser has its own derivation; do not let the workspace postinstall
    # try to create a uv virtualenv inside the sandbox.
    SKIP_PARSER_API_INSTALL = "1";
    NEXT_TELEMETRY_DISABLED = "1";
    SHARP_IGNORE_GLOBAL_LIBVIPS = "1";
    NORISH_VERSION_REPORT_JSON = builtins.toJSON { root = version; };
  };

  buildPhase = ''
    runHook preBuild

    export NODE_ENV=production
    export SKIP_ENV_VALIDATION=1
    export DATABASE_URL="postgresql://build:build@localhost:5432/build"

    # SWC's native addon carrier materialises the binding into a private
    # cache and refuses the sandbox's build directory, whose parent is
    # writable by the Nix build users. Give it a cache and skip that check.
    export SWC_NATIVE_BINDING_CACHE="$(mktemp -d)"
    export SWC_NATIVE_BINDING_CACHE_SKIP_SECURITY_CHECK=1
    chmod 700 "$SWC_NATIVE_BINDING_CACHE"

    pnpm --filter @norish/web run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p ${runtimeRoot}/apps/web $out/bin

    # Next.js output. Production reads its config from
    # .next/required-server-files.json, exactly as the shipped image does.
    cp -r apps/web/.next ${runtimeRoot}/apps/web/.next
    cp -r apps/web/public ${runtimeRoot}/apps/web/public

    # The custom server runs from source through tsx, as it does in the image.
    cp -r apps/web/server ${runtimeRoot}/apps/web/server
    cp apps/web/package.json ${runtimeRoot}/apps/web/package.json

    # Production dependency closure, isolated like the Docker image. The
    # workspace copies live in the deploy store, so the packages below link to
    # the same code instead of shipping a second copy.
    pnpm --offline deploy --filter @norish/web --prod ./deploy
    cp -r deploy/node_modules ${runtimeRoot}/node_modules

    mkdir -p ${runtimeRoot}/packages
    for dir in packages/*/; do
      name=$(node -p "require('./''${dir}package.json').name")
      if [ -d "deploy/node_modules/$name/src" ]; then
        package=$(basename "$dir")
        mkdir -p "${runtimeRoot}/packages/$package"
        cp "''${dir}package.json" "${runtimeRoot}/packages/$package/"
        ln -s "../../node_modules/$name/src" "${runtimeRoot}/packages/$package/src"
      fi
    done

    # Next writes caches, preview/server-action keys and optimized images into
    # .next/cache, which is read-only in the store. Honour NEXT_CACHE_DIR like
    # the nixpkgs Next.js packages do, for both the CJS and ESM builds.
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/server/cache-dir.js \
      --replace-fail \
      "return _path.default.join(distDir, 'cache');" \
      "return process.env['NEXT_CACHE_DIR'] || _path.default.join(distDir, 'cache');"
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/esm/server/cache-dir.js \
      --replace-fail \
      "return path.join(distDir, 'cache');" \
      "return process.env['NEXT_CACHE_DIR'] || path.join(distDir, 'cache');"
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/server/lib/incremental-cache/file-system-cache.js \
      --replace-fail \
      "rootDir = _path.default.join(this.serverDistDir, '..', 'cache', 'fetch-cache');" \
      "rootDir = _path.default.join(process.env['NEXT_CACHE_DIR'] || _path.default.join(this.serverDistDir, '..', 'cache'), 'fetch-cache');"
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/esm/server/lib/incremental-cache/file-system-cache.js \
      --replace-fail \
      "rootDir = path.join(this.serverDistDir, '..', 'cache', 'fetch-cache');" \
      "rootDir = path.join(process.env['NEXT_CACHE_DIR'] || path.join(this.serverDistDir, '..', 'cache'), 'fetch-cache');"
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/server/image-optimizer.js \
      --replace-fail \
      "this.cacheDir = (0, _path.join)(/* turbopackIgnore: true */ distDir, 'cache', 'images');" \
      "this.cacheDir = (0, _path.join)(process.env['NEXT_CACHE_DIR'] || (0, _path.join)(/* turbopackIgnore: true */ distDir, 'cache'), 'images');"
    substituteInPlace ${runtimeRoot}/node_modules/next/dist/esm/server/image-optimizer.js \
      --replace-fail \
      "this.cacheDir = join(/* turbopackIgnore: true */ distDir, 'cache', 'images');" \
      "this.cacheDir = join(process.env['NEXT_CACHE_DIR'] || join(/* turbopackIgnore: true */ distDir, 'cache'), 'images');"

    makeWrapper ${nodejs_26}/bin/node $out/bin/norish \
      --add-flags "--import tsx ${runtimeRoot}/apps/web/server/index.ts" \
      --run "cd ${runtimeRoot}" \
      --set-default NODE_ENV production

    runHook postInstall
  '';

  doInstallCheck = true;

  # Loading sharp runs libvips-cpp's constructors and encoding proves its
  # .text/.plt survived patching. A corrupted RUNPATH/DT_INIT would otherwise
  # only surface as a crash when the service first loads an image.
  installCheckPhase = ''
    runHook preInstallCheck

    cd ${runtimeRoot}
    ${nodejs_26}/bin/node -e '
      const { createRequire } = require("module");
      const sharedRequire = createRequire(
        require.resolve("@norish/shared-server/logger", { paths: [process.cwd()] })
      );
      const sharp = sharedRequire("sharp");
      sharp({ create: { width: 8, height: 8, channels: 3, background: "#ff0000" } })
        .png()
        .toBuffer()
        .then(() => console.log("sharp is usable (libvips " + sharp.versions.vips + ")"))
        .catch((error) => { console.error(error); process.exit(1); });
    '

    runHook postInstallCheck
  '';

  passthru = {
    inherit runtimeRoot;
    updateScript = null;
  };

  meta = {
    description = "Household-first recipe app for planning meals, sharing groceries and cooking together";
    homepage = "https://github.com/norish-recipes/norish";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "norish";
  };
})
