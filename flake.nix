{
  description = "Norish - household-first recipe app (package, NixOS module and tests)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: _prev: {
        norish = final.callPackage ./nix/package.nix { };
        norish-parser-api = final.callPackage ./nix/parser-api.nix { };
      };

      nixosModules = rec {
        norish =
          { pkgs, lib, ... }:
          {
            imports = [ ./nixos/module.nix ];
            services.norish = {
              package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.norish;
              parserApiPackage = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.norish-parser-api;
            };
          };
        default = norish;
      };

      packages = forAllSystems (system: rec {
        inherit (mkPkgs system) norish norish-parser-api;
        default = norish;
      });

      formatter = forAllSystems (system: (mkPkgs system).nixfmt);

      checks = forAllSystems (system: rec {
        norish = (mkPkgs system).testers.runNixOSTest (import ./nixos/test.nix { inherit self; });
        default = norish;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs_22
              pnpm_10
              python314
              nixfmt
            ];
          };
        }
      );
    };
}
