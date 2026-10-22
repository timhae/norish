/*
  Norish NixOS integration test.

  Covers the pieces that only exist when the module is assembled: local
  PostgreSQL/Redis provisioning, migrations, the separate parser service the
  web server reuses, Obscura, nginx, sign-up/session handling and a rendered
  page.

  Not covered: URL imports through Obscura against a private test page (Obscura
  deliberately blocks private-network targets), AI features, video parsing.
*/
{ self, ... }:
let
  masterKey = "X4fjLgB8egCPwlOQW8iC3JGXAtUIMUOGmk/y29n+YSw=";
in
{
  name = "norish";

  nodes.machine =
    { ... }:
    {
      imports = [ self.nixosModules.default ];

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 8192;
      };

      environment.etc."norish/master-key".text = masterKey;

      networking.hosts."127.0.0.1" = [ "norish.test" ];

      services.norish = {
        enable = true;
        domain = "norish.test";
        masterKeyFile = "/etc/norish/master-key";
        nginx = {
          enable = true;
          enableACME = false;
          forceSSL = false;
        };
        extraEnvironment = {
          AUTH_RATE_LIMIT_ENABLED = "false";
          INGREDIENT_CATALOGUE_URL = "";
          NEXT_PUBLIC_LOG_LEVEL = "error";
          LOG_LEVEL = "error";
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      parserPort = nodes.machine.services.norish.parser.port;
      obscuraPort = nodes.machine.services.norish.obscura.port;
      databaseName = nodes.machine.services.norish.database.name;
    in
    ''
      import json
      import shlex
      from datetime import timedelta

      start_all()

      machine.wait_for_unit("postgresql.target")
      machine.wait_for_unit("redis-norish.service")
      machine.wait_for_unit("norish-parser.service")
      machine.wait_for_unit("norish-obscura.service")
      machine.wait_for_unit("norish.service")
      machine.wait_for_unit("nginx.service")

      machine.wait_for_open_port(${toString parserPort})
      machine.wait_for_open_port(${toString obscuraPort})
      machine.wait_for_open_port(3000)

      with subtest("the parser service is healthy and independent of the web server"):
          machine.succeed("curl -fsS http://127.0.0.1:${toString parserPort}/health")
          # The web server reuses this process instead of spawning its own
          machine.succeed("systemctl is-active --quiet norish-parser.service")

      with subtest("the parser turns schema.org HTML into recipe data"):
          html = """
          <html><head><script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "Recipe",
            "name": "Nixos Test Soup",
            "recipeIngredient": ["1 carrot", "2 cups water"],
            "recipeInstructions": [{"@type": "HowToStep", "text": "Boil everything."}]
          }
          </script></head><body></body></html>
          """
          payload = json.dumps({"url": "https://example.com/recipe", "html": html})
          _, output = machine.execute(
              "curl -fsS -X POST -H 'content-type: application/json'"
              f" --data-binary {shlex.quote(payload)}"
              " http://127.0.0.1:${toString parserPort}/parse"
          )
          machine.log(output)
          parsed = json.loads(output)
          assert parsed["ok"] is True, output
          assert parsed["recipe"]["title"] == "Nixos Test Soup", output

      with subtest("Obscura listens on its CDP port"):
          machine.succeed("curl -fsS http://127.0.0.1:${toString obscuraPort}/json/version > /dev/null")

      with subtest("the database migrations ran"):
          machine.succeed(
              "sudo -u postgres psql -d ${databaseName} -tAc"
              " \"SELECT tablename FROM pg_tables WHERE schemaname = 'public'\""
              " | grep -x user"
          )
          machine.succeed(
              "sudo -u postgres psql -d ${databaseName} -tAc"
              " \"SELECT tablename FROM pg_tables WHERE schemaname = 'public'\""
              " | grep -x recipes"
          )

      with subtest("the health endpoint answers through nginx"):
          # The first request after boot can initialise auth and the DB pool.
          machine.wait_until_succeeds(
              "curl -fsS --max-time 300 -H 'Host: norish.test'"
              " http://127.0.0.1/api/v1/health",
              timeout=timedelta(minutes=15),
          )

      with subtest("the first user can sign up and gets a session"):
          machine.succeed(
              "curl -fsS --max-time 300 -c /tmp/norish.cookies"
              " -H 'Host: norish.test'"
              " -H 'Origin: http://norish.test'"
              " -H 'Content-Type: application/json'"
              " --data '{\"email\":\"nixos@example.org\",\"password\":\"NixosTest1234.\",\"name\":\"Nixos Test\"}'"
              " http://127.0.0.1/api/auth/sign-up/email > /tmp/norish-signup.json"
          )
          _, session = machine.execute(
              "curl -fsS --max-time 300 -b /tmp/norish.cookies"
              " -H 'Host: norish.test'"
              " http://127.0.0.1/api/auth/get-session"
          )
          machine.log(session)
          session_json = json.loads(session)
          assert session_json["user"]["email"] == "nixos@example.org", session

      with subtest("the login page renders"):
          status, page = machine.execute(
              "curl -sS --max-time 300 -L -w '\\n%{http_code}' http://norish.test/"
          )
          assert status == 0, page
          assert page.rstrip().endswith("200"), page
          assert "Norish" in page, page

      with subtest("the database still has the user after a server restart"):
          machine.succeed("systemctl restart norish.service")
          machine.wait_for_unit("norish.service")
          machine.wait_until_succeeds(
              "curl -fsS --max-time 300 -H 'Host: norish.test' http://127.0.0.1/api/v1/health"
          )
          machine.succeed(
              "sudo -u postgres psql -d ${databaseName} -tAc"
              " 'SELECT count(*) FROM \"user\"' | grep -x 1"
          )

      with subtest("no Norish unit restarted itself"):
          assert machine.succeed(
              "systemctl show --property=NRestarts --value norish.service"
          ).strip() == "0"
          assert machine.succeed(
              "systemctl show --property=NRestarts --value norish-parser.service"
          ).strip() == "0"
    '';

  interactive.nodes.machine = {
    networking.firewall.allowedTCPPorts = [ 80 ];
    virtualisation.forwardPorts = [
      {
        from = "host";
        host.port = 8888;
        guest.port = 80;
      }
    ];
  };
}
