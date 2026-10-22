{
  lib,
  stdenv,
  nodejs_22,
  pnpm_10,
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
    ../dist-server
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
    nodejs_22
    pnpm_10
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
    pnpm = pnpm_10;
    fetcherVersion = 4;
    hash = "sha256-W1rMALvDxLQ1oI+WRIaKFDGvLhFfx3sNtVFbUy/qYZQ=";
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

    pnpm --filter @norish/web run build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p ${runtimeRoot} $out/bin

    # The custom server bundle. Workspace packages are inlined here; npm
    # packages stay external and resolve from the deploy node_modules below.
    cp -r dist-server ${runtimeRoot}/

    # Next.js standalone output, plus the static/public files Next does not
    # trace, mirroring the layout of the shipped Docker image.
    mkdir -p ${runtimeRoot}/apps/web/.next
    cp -r apps/web/.next/standalone/apps/web/.next/. ${runtimeRoot}/apps/web/.next/
    cp -r apps/web/.next/static ${runtimeRoot}/apps/web/.next/
    cp -r apps/web/public ${runtimeRoot}/apps/web/
    cp apps/web/next.config.js ${runtimeRoot}/apps/web/
    mkdir -p ${runtimeRoot}/apps/web/config ${runtimeRoot}/apps/web/i18n
    cp apps/web/config/next-intl-request-config-path.js ${runtimeRoot}/apps/web/config/
    cp apps/web/i18n/request.ts ${runtimeRoot}/apps/web/i18n/

    cp package.json pnpm-workspace.yaml ${runtimeRoot}/
    cp apps/web/package.json ${runtimeRoot}/apps/web/

    # The app discovers its runtime data (migrations, prompts, icon set, Lua
    # scripts) relative to the workspace root, so the packages tree travels
    # with the server.
    cp -r packages ${runtimeRoot}/

    # Production dependency closure. The custom server keeps npm packages
    # external, so the hoisted workspace node_modules is exactly what it
    # resolves at runtime. Pruning is offline: the pnpm store was populated by
    # fetchPnpmDeps before the sandbox lost network access.
    CI=true pnpm prune --prod --ignore-scripts
    cp -r node_modules ${runtimeRoot}/

    # Workspace code is already in dist-server; drop the deploy copies and
    # build-only tooling (kept deliberately conservative: only packages the
    # server never imports at runtime).
    rm -rf ${runtimeRoot}/node_modules/@norish
    rm -rf ${runtimeRoot}/node_modules/{typescript,@esbuild,esbuild,tsx,drizzle-kit,@tailwindcss,tailwindcss,postcss,vitest,@vitest,jsdom,turbo,rollup,terser}
    rm -rf ${runtimeRoot}/node_modules/{eslint,@eslint,@typescript-eslint,prettier,@prisma,prisma}
    rm -rf ${runtimeRoot}/node_modules/ffmpeg-static

    # Test files, tsconfigs and caches are not runtime data.
    find ${runtimeRoot}/packages -type d -name __tests__ -exec rm -rf {} + 2>/dev/null || true
    find ${runtimeRoot}/packages -type f \
      \( -name '*.test.ts' -o -name '*.test.tsx' -o -name '*.spec.ts' -o -name '*.spec.tsx' \
      -o -name 'vitest.config.*' -o -name 'tsconfig*.json' -o -name 'eslint.config.*' \) \
      -delete 2>/dev/null || true
    find ${runtimeRoot}/packages -type d \( -name dist -o -name .cache -o -name .turbo \) -prune -exec rm -rf {} + 2>/dev/null || true

    # Dropping build-only packages and the workspace deploy copies leaves
    # their .bin and dev-config symlinks behind. None of them is needed.
    find ${runtimeRoot} -type l ! -exec test -e {} \; -delete

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

    makeWrapper ${nodejs_22}/bin/node $out/bin/norish \
      --add-flags "${runtimeRoot}/dist-server/index.mjs" \
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
    ${nodejs_22}/bin/node -e '
      const sharp = require("sharp");
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
