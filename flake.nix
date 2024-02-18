{
  description = "A scrollable-tiling Wayland compositor.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    crate2nix.url = "github:nix-community/crate2nix";

    niri-src.url = "github:YaLTeR/niri/v0.1.2";
    niri-src.flake = false;
  };

  outputs = inputs @ {
    self,
    flake-parts,
    crate2nix,
    niri-src,
    nixpkgs,
    ...
  }: let
    niri-src-is-unchanged = (builtins.fromJSON (builtins.readFile (self + /flake.lock))).nodes.niri-src.locked.rev == niri-src.rev;
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux"];
      perSystem = {
        self',
        config,
        system,
        pkgs,
        ...
      }: let
        tools = pkgs.callPackage "${crate2nix}/tools.nix" {};

        makeWorkspace = {
          src,
          pkgs,
        }:
          import (
            tools.generatedCargoNix {
              inherit src;
              name = "niri";
            }
          ) {
            inherit pkgs;
            buildRustCrateForPkgs = pkgs:
              pkgs.buildRustCrate.override {
                defaultCrateOverrides =
                  pkgs.defaultCrateOverrides
                  // (with pkgs; {
                    libspa-sys = attrs: {
                      nativeBuildInputs = [pkg-config rustPlatform.bindgenHook];
                      buildInputs = [pipewire];
                    };

                    libspa = attrs: {
                      nativeBuildInputs = [pkg-config];
                      buildInputs = [pipewire];
                    };

                    pipewire-sys = attrs: {
                      nativeBuildInputs = [pkg-config rustPlatform.bindgenHook];
                      buildInputs = [pipewire];
                    };

                    gobject-sys = attrs: {
                      nativeBuildInputs = [pkg-config glib];
                    };

                    gio-sys = attrs: {
                      nativeBuildInputs = [pkg-config glib];
                    };

                    niri-config = attrs: {
                      prePatch = ''sed -i 's#\.\./\.\.#${niri-src}#' src/lib.rs'';
                    };

                    niri = attrs: {
                      buildInputs = [libxkbcommon libinput mesa libglvnd wayland pixman];

                      # we want backtraces to be readable
                      dontStrip = true;

                      extraRustcOpts = [
                        "-C link-arg=-Wl,--push-state,--no-as-needed"
                        "-C link-arg=-lEGL"
                        "-C link-arg=-lwayland-client"
                        "-C link-arg=-Wl,--pop-state"

                        "-C debuginfo=line-tables-only"

                        # "/source/" is not very readable. "./" is better, and it matches default behaviour of cargo.
                        "--remap-path-prefix $NIX_BUILD_TOP/source=./"
                      ];

                      passthru.providedSessions = ["niri"];

                      postInstall = ''
                        mkdir -p $out/share/systemd/user
                        mkdir -p $out/share/wayland-sessions
                        mkdir -p $out/share/xdg-desktop-portal

                        cp ${niri-src}/resources/niri-session $out/bin/niri-session
                        cp ${niri-src}/resources/niri.service $out/share/systemd/user/niri.service
                        cp ${niri-src}/resources/niri-shutdown.target $out/share/systemd/user/niri-shutdown.target
                        cp ${niri-src}/resources/niri.desktop $out/share/wayland-sessions/niri.desktop
                        cp ${niri-src}/resources/niri-portals.conf $out/share/xdg-desktop-portal/niri-portals.conf
                      '';

                      postFixup = ''sed -i "s#/usr#$out#" $out/share/systemd/user/niri.service'';
                    };
                  });
              };
          };
      in {
        packages = {
          niri =
            pkgs.lib.makeOverridable (args: let
              workspace = makeWorkspace args;
            in
              workspace.workspaceMembers.niri.build // {inherit workspace;})
            {
              inherit pkgs;
              src = niri-src;
            };
          default = self'.packages.niri;
        };

        apps = {
          niri = {
            type = "app";
            program = "${self'.packages.niri}/bin/niri";
          };
          default = self'.apps.niri;
        };

        formatter = pkgs.alejandra;
      };

      flake = {
        homeModules.config = {
          lib,
          config,
          pkgs,
          ...
        }:
          with lib; let
            cfg = config.programs.niri;
          in {
            options.programs.niri = {
              config = mkOption {
                type = types.nullOr types.str;
                default = null;
              };
              package = mkOption {
                type = types.package;
                default = self.packages.${pkgs.stdenv.system}.niri.override {inherit pkgs;};
              };
            };

            config.xdg.configFile.niri-config = {
              enable = !isNull cfg.config;
              target = "niri/config.kdl";
              source =
                pkgs.runCommand "config.kdl" {
                  config = cfg.config;
                  passAsFile = ["config"];
                  buildInputs = [cfg.package];
                } ''
                  niri validate -c $configPath
                  cp $configPath $out
                '';
            };
          };
        nixosModules.niri = {
          lib,
          config,
          options,
          pkgs,
          ...
        }: let
          cfg = config.programs.niri;

          nixpkgs-niri-is-useful = pkgs ? niri && builtins.compareVersions pkgs.niri.version "0.1.2" != -1;
          override-cfg = "programs.niri.package = niri.packages.${pkgs.stdenv.system}.niri.override {inherit pkgs;};";
        in
          with lib; {
            options.programs.niri = {
              enable = mkEnableOption "niri";
              package = mkOption {
                type = types.package;
                default =
                  if nixpkgs-niri-is-useful
                  then pkgs.niri
                  else self.packages.${pkgs.stdenv.system}.niri.override {inherit pkgs;};
              };

              acknowledge-warning.will-use-nixpkgs = mkOption {
                type = types.bool;
                default = false;
              };

              acknowledge-warning.is-using-nixpkgs = mkOption {
                type = types.bool;
                default = false;
              };
            };

            config = mkMerge [
              (mkIf (!cfg.acknowledge-warning.is-using-nixpkgs && nixpkgs-niri-is-useful) {
                warnings = let
                  is-using-nixpkgs = cfg.package == pkgs.niri;
                in [
                  ''
                    Niri v${pkgs.niri.version} is available in nixpkgs. It is now the default.

                    ${
                      if niri-src-is-unchanged
                      then
                        (
                          if is-using-nixpkgs
                          then ''
                            You seem to have been using stable niri previously, but now you're using the nixpkgs package:
                            - New updates will be downloaded from the nixpkgs cache, instead of being built locally.
                            - Updates may be slightly slower, but you will still get them.

                            If you want to keep using the previous package, for whatever reason:
                            - Set `${override-cfg}`
                          ''
                          else ''
                            You seem to have been using stable niri previously, and you've overriden the used package:
                            - You will not benefit from binary caching.

                            There is no real good reason to do this. You should probably switch to the nixpkgs package:
                            - Unset `programs.niri.package`, or set it to the default of `pkgs.niri`.
                          ''
                        )
                      else
                        (
                          if is-using-nixpkgs
                          then ''
                            You're overriding this flake to use a specific revision of niri, but you still haven't set `programs.niri.package`:
                            - You're actually using the nixpkgs package, which is based on stable niri.

                            You should probably override it to use your specific revision:
                            - Set `${override-cfg}`
                            - This will cause future rebuilds to use the unstable version, just as previously.

                            If you intended to use the nixpkgs package:
                            - Unset `inputs.niri.inputs.niri-src`. At some point, this input will be deprecated. (if you use it, you can keep it for now)
                          ''
                          else ''
                            You're overriding this flake to use a specific revision of niri, and you've already set `programs.niri.package`:
                            - No action is necessary.
                            - You will keep getting updates as before.
                            - Nothing will change for you.
                          ''
                        )
                    }
                    You can dismiss this warning by setting `programs.niri.acknowledge-warning.is-using-nixpkgs = true`.
                  ''
                ];
              })
              (mkIf (!cfg.acknowledge-warning.will-use-nixpkgs && !nixpkgs-niri-is-useful) {
                warnings = [
                  ''
                    The default niri package will soon change to the one in nixpkgs when v0.1.2 is available.

                    ${
                      if niri-src-is-unchanged
                      then ''
                        You seem to be using the default, stable package. You probably want to use nixpkgs when it's available:
                        - No action is necessary. The new package will be used when it's available.
                        - You will soon benefit from binary caching of nixpkgs.
                        - You will still get updates, but they might be slightly slower.

                        If you want to keep using the current package, for whatever reason:
                        - Set `${override-cfg}`
                      ''
                      else ''
                        You're using a specific revision of niri. To prevent this change from affecting you:
                        - Set `${override-cfg}`

                        Otherwise, if you want to use stable niri from the nixpkgs package and benefit from binary caching of stable niri:
                        - Unset `inputs.niri.inputs.niri-src`. At some point, this input will be deprecated. (but you can keep it for now)
                      ''
                    }
                    You can dismiss this warning by setting `programs.niri.acknowledge-warning.will-use-nixpkgs = true;`.
                  ''
                ];
              })
              (mkIf cfg.enable {
                environment.systemPackages = [cfg.package];
                services.xserver.displayManager.sessionPackages = [cfg.package];
                services.gnome.gnome-keyring.enable = true;
                xdg.portal = {
                  enable = true;
                  extraPortals = [pkgs.xdg-desktop-portal-gnome];
                  configPackages = [cfg.package];
                };
              })
              (optionalAttrs (options ? home-manager) {
                home-manager.sharedModules = [
                  self.homeModules.config
                  {
                    programs.niri.package = mkForce cfg.package;
                  }
                ];
              })
            ];
          };
        nixosModules.default = self.nixosModules.niri;
        homeModules.niri = {
          lib,
          config,
          pkgs,
          ...
        }:
          with lib; let
            cfg = config.programs.niri;
          in {
            imports = [
              self.homeModules.config
            ];
            options.programs.niri = {
              enable = mkEnableOption "niri";
            };

            config = mkIf cfg.enable {
              home.packages = [cfg.package];
              services.gnome-keyring.enable = true;
              xdg.portal = {
                enable = true;
                extraPortals = [pkgs.xdg-desktop-portal-gnome];
                configPackages = [cfg.package];
              };
            };
          };
      };
    };
}
