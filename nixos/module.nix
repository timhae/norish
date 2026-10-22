/*
  NixOS module for Norish.

  The application is a Next.js custom server (dist-server) plus a small
  FastAPI parser. The parser is a separate unit because the server only spawns
  its own Python interpreter when no parser is already listening on
  127.0.0.1:${parser.port}; with the unit below it detects the healthy service
  and reuses it. PostgreSQL, Redis and Obscura are local by default so a
  single `services.norish.enable = true` gives a working URL-import stack.
*/
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.norish;

  stateDir = "/var/lib/${cfg.stateDir}";
  cacheDir = "/var/cache/${cfg.stateDir}";

  tlsEnabled = cfg.nginx.enable && (cfg.nginx.forceSSL || cfg.nginx.enableACME);

  authUrl =
    if cfg.authUrl != null then
      cfg.authUrl
    else if cfg.nginx.enable && cfg.domain != null then
      "${if tlsEnabled then "https" else "http"}://${cfg.domain}"
    else
      "http://${cfg.host}:${toString cfg.port}";

  obscuraEndpoint =
    if cfg.obscura.endpoint != null then
      cfg.obscura.endpoint
    else
      "ws://127.0.0.1:${toString cfg.obscura.port}";

  # The local PostgreSQL is reached through its unix socket and peer
  # authentication, so no password has to be generated or stored.
  localDatabaseUrl = "postgresql://${cfg.database.user}@localhost/${cfg.database.name}?host=${cfg.database.host}&port=${toString cfg.database.port}";

  databaseEnvironment =
    if cfg.database.urlFile != null then
      { }
    else if cfg.database.createLocally then
      { DATABASE_URL = localDatabaseUrl; }
    else if cfg.database.passwordFile != null then
      {
        DATABASE_HOST = cfg.database.host;
        DATABASE_PORT = toString cfg.database.port;
        DATABASE = cfg.database.name;
        DATABASE_USER = cfg.database.user;
      }
    else
      {
        DATABASE_URL = "postgresql://${cfg.database.user}@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}";
      };

  redisEnvironment =
    if cfg.redis.urlFile != null then
      { }
    else if cfg.redis.url != null then
      { REDIS_URL = cfg.redis.url; }
    else
      { REDIS_URL = "redis://${cfg.redis.host}:${toString cfg.redis.port}"; };

  baseEnvironment = {
    NODE_ENV = "production";
    HOST = cfg.host;
    PORT = toString cfg.port;
    AUTH_URL = authUrl;
    TRUSTED_ORIGINS = "${authUrl},http://127.0.0.1:${toString cfg.port}";
    UPLOADS_DIR = "${stateDir}/uploads";
    NEXT_CACHE_DIR = cacheDir;
    HOME = stateDir;
    PARSER_API_PORT = toString cfg.parser.port;
    OBSCURA_ENDPOINT = obscuraEndpoint;
    YT_DLP_BIN_DIR = "${cfg.ytDlpPackage}/bin";
  };
in
{
  options.services.norish = {
    enable = mkEnableOption "Norish, a household-first recipe app";

    package = mkPackageOption pkgs "norish" { };

    parserApiPackage = mkPackageOption pkgs "norish-parser-api" { };

    user = mkOption {
      type = types.str;
      default = "norish";
      description = "User account the Norish services run as.";
    };

    group = mkOption {
      type = types.str;
      default = "norish";
      description = "Group the Norish services run as.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "norish";
      description = ''
        Name below `/var/lib` for uploads, and below `/var/cache` for the
        Next.js cache.
      '';
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Interface the Norish HTTP server listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Port the Norish HTTP server listens on.";
    };

    authUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://norish.example.org";
      description = ''
        Public URL of this installation (`AUTH_URL`). Derived from
        {option}`services.norish.domain` when nginx is enabled, otherwise from
        {option}`services.norish.host` and {option}`services.norish.port`.
      '';
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "norish.example.org";
      description = "Domain of the nginx virtual host.";
    };

    masterKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/keys/norish-master-key";
      description = ''
        File containing the 32-byte-or-longer `MASTER_KEY` used to encrypt
        stored secrets. Read through systemd credentials and never placed in
        the Nix store.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional environment file for additional settings or secrets (for
        example AI or SMTP settings). Values in
        {option}`services.norish.extraEnvironment` take precedence.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        PASSWORD_AUTH_ENABLED = "true";
        OIDC_ISSUER = "https://auth.example.org";
      };
      description = "Extra environment variables for the Norish server.";
    };

    ytDlpPackage = mkPackageOption pkgs "yt-dlp" { };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Create a local PostgreSQL database and use it through the unix
          socket with peer authentication. The database user must equal the
          Norish system user.
        '';
      };

      host = mkOption {
        type = types.str;
        default = if cfg.database.createLocally then "/run/postgresql" else "127.0.0.1";
        defaultText = literalExpression ''"/run/postgresql" when createLocally, otherwise "127.0.0.1"'';
        description = "PostgreSQL host, or socket directory for a local database.";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port.";
      };

      name = mkOption {
        type = types.str;
        default = "norish";
        description = "PostgreSQL database name.";
      };

      user = mkOption {
        type = types.str;
        default = "norish";
        description = "PostgreSQL role used by Norish.";
      };

      urlFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/keys/norish-database-url";
        description = ''
          File containing a complete `DATABASE_URL`. Useful for external
          databases, where it also avoids assembling a URL from parts in the
          Nix store.
        '';
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/keys/norish-database-password";
        description = ''
          File containing the password for an external database. The server
          assembles the URL from the database options and encodes the
          credentials.
        '';
      };
    };

    redis = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = "Run a local Redis server for Norish.";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Redis host for a local Redis server or a URL built from parts.";
      };

      port = mkOption {
        type = types.port;
        default = 6379;
        description = "Redis port.";
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "redis://redis.example.org:6379";
        description = "Complete Redis URL for an external server.";
      };

      urlFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "File containing a complete `REDIS_URL`, useful for secrets.";
      };
    };

    parser = {
      port = mkOption {
        type = types.port;
        default = 8001;
        description = "Loopback port of the parser API.";
      };
    };

    obscura = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run Obscura, the headless browser used to render JavaScript-heavy
          recipe pages for URL imports.
        '';
      };

      package = mkPackageOption pkgs "obscura" { };

      port = mkOption {
        type = types.port;
        default = 9222;
        description = "Loopback port of the Obscura CDP server.";
      };

      endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "ws://127.0.0.1:9222";
        description = ''
          CDP endpoint of an external Obscura. If null and
          {option}`services.norish.obscura.enable` is true, the local unit's
          endpoint is used.
        '';
      };

      tokenFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/keys/norish-obscura-token";
        description = ''
          Optional file containing the Obscura CDP bearer token. Both the
          browser and the Norish server read it through systemd credentials.
        '';
      };
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = cfg.domain != null;
        defaultText = literalExpression "config.services.norish.domain != null";
        description = "Configure an nginx reverse proxy for Norish.";
      };

      useACMEHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of an existing ACME certificate to use.";
      };

      enableACME = mkOption {
        type = types.bool;
        default = false;
        description = "Obtain a TLS certificate for the virtual host with ACME.";
      };

      forceSSL = mkOption {
        type = types.bool;
        default = cfg.nginx.enableACME;
        defaultText = literalExpression "config.services.norish.nginx.enableACME";
        description = "Redirect HTTP requests to HTTPS.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.masterKeyFile != null;
        message = "services.norish.masterKeyFile must be set to a file containing a 32-byte-or-longer MASTER_KEY.";
      }
      {
        assertion = !cfg.database.createLocally || cfg.database.user == cfg.user;
        message = "services.norish.database.user must equal services.norish.user when database.createLocally is enabled (peer authentication).";
      }
      {
        assertion = !cfg.database.createLocally || cfg.database.host == "/run/postgresql";
        message = "services.norish.database.host must be /run/postgresql when database.createLocally is enabled.";
      }
      {
        assertion = !cfg.redis.createLocally || (cfg.redis.url == null && cfg.redis.urlFile == null);
        message = "services.norish.redis.url and urlFile must be null when redis.createLocally is enabled.";
      }
      {
        assertion = cfg.redis.createLocally || cfg.redis.url != null || cfg.redis.urlFile != null;
        message = "Set services.norish.redis.url or urlFile when redis.createLocally is disabled.";
      }
      {
        assertion = cfg.obscura.enable || cfg.obscura.endpoint != null;
        message = "services.norish.obscura.endpoint must be set when services.norish.obscura.enable is disabled.";
      }
      {
        assertion = !cfg.nginx.enable || cfg.domain != null;
        message = "services.norish.domain must be set when nginx is enabled.";
      }
      {
        assertion = cfg.parser.port != cfg.port;
        message = "services.norish.parser.port must differ from services.norish.port.";
      }
    ];

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = stateDir;
    };

    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.norish = mkIf cfg.redis.createLocally {
      enable = true;
      bind = cfg.redis.host;
      port = cfg.redis.port;
    };

    systemd.services.norish-parser = {
      description = "Norish parser API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        ExecStart = "${cfg.parserApiPackage}/bin/norish-parser-api --host 127.0.0.1 --port ${toString cfg.parser.port}";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        DynamicUser = false;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    systemd.services.norish-obscura = mkIf cfg.obscura.enable {
      description = "Norish Obscura headless browser";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        StateDirectory = "${cfg.stateDir}-obscura";
        CacheDirectory = "${cfg.stateDir}-obscura";
        LoadCredential = optional (cfg.obscura.tokenFile != null) "obscura_token:${cfg.obscura.tokenFile}";
      };

      script = ''
        ${optionalString (cfg.obscura.tokenFile != null) ''
          export OBSCURA_CDP_TOKEN="$(<"$CREDENTIALS_DIRECTORY/obscura_token")"
        ''}
        exec ${cfg.obscura.package}/bin/obscura serve \
          --host 127.0.0.1 \
          --port ${toString cfg.obscura.port} \
          --stealth
      '';
    };

    systemd.services.norish = {
      description = "Norish";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "norish-parser.service"
      ]
      ++ optional cfg.obscura.enable "norish-obscura.service"
      ++ optional cfg.database.createLocally "postgresql.target"
      ++ optional cfg.redis.createLocally "redis-norish.service";
      requires = [
        "norish-parser.service"
      ]
      ++ optional cfg.obscura.enable "norish-obscura.service"
      ++ optional cfg.database.createLocally "postgresql.target"
      ++ optional cfg.redis.createLocally "redis-norish.service";

      path = [
        pkgs.curl
        cfg.ytDlpPackage
        pkgs.ffmpeg
      ];

      environment = baseEnvironment // databaseEnvironment // redisEnvironment // cfg.extraEnvironment;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "${cfg.package}/lib/norish";
        StateDirectory = cfg.stateDir;
        CacheDirectory = cfg.stateDir;
        StateDirectoryMode = "0750";
        Restart = "on-failure";
        TimeoutStartSec = "10min";
        EnvironmentFile = optional (cfg.environmentFile != null) cfg.environmentFile;
        LoadCredential =
          optional (cfg.masterKeyFile != null) "master_key:${cfg.masterKeyFile}"
          ++ optional (cfg.database.urlFile != null) "database_url:${cfg.database.urlFile}"
          ++ optional (cfg.database.passwordFile != null) "database_password:${cfg.database.passwordFile}"
          ++ optional (cfg.redis.urlFile != null) "redis_url:${cfg.redis.urlFile}"
          ++ optional (cfg.obscura.tokenFile != null) "obscura_token:${cfg.obscura.tokenFile}";
        ExecStartPre = "${lib.getExe pkgs.curl} --fail --silent --show-error --retry 60 --retry-delay 1 --retry-all-errors http://127.0.0.1:${toString cfg.parser.port}/health";
        # Node's V8 JIT needs writable executable memory.
        MemoryDenyWriteExecute = false;
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          stateDir
          cacheDir
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };

      script = ''
        export MASTER_KEY="$(<"$CREDENTIALS_DIRECTORY/master_key")"
        ${optionalString (cfg.database.urlFile != null) ''
          export DATABASE_URL="$(<"$CREDENTIALS_DIRECTORY/database_url")"
        ''}
        ${optionalString (cfg.database.passwordFile != null) ''
          export DATABASE_PASSWORD="$(<"$CREDENTIALS_DIRECTORY/database_password")"
        ''}
        ${optionalString (cfg.redis.urlFile != null) ''
          export REDIS_URL="$(<"$CREDENTIALS_DIRECTORY/redis_url")"
        ''}
        ${optionalString (cfg.obscura.tokenFile != null) ''
          export OBSCURA_CDP_TOKEN="$(<"$CREDENTIALS_DIRECTORY/obscura_token")"
        ''}

        mkdir -p "$UPLOADS_DIR"
        exec ${cfg.package}/bin/norish
      '';
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;

      virtualHosts.${cfg.domain} = {
        inherit (cfg.nginx) useACMEHost enableACME forceSSL;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.port}";
          proxyWebsockets = true;
          extraConfig = ''
            client_max_body_size 100M;
            # The first request after a cold boot may initialise auth, the
            # database pool and Next's route handlers.
            proxy_connect_timeout 60s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
