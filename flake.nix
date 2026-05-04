{
  description = "Open-source IRC server with a focus on modularity and security";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "unrealircd";
            version = "6.2.5-git";

            src = ./.;

            nativeBuildInputs = with pkgs; [ pkg-config ];

            buildInputs = with pkgs; [
              openssl
              pcre2
              libargon2
              libsodium
              c-ares
              jansson
              curl
            ];

            # --with-tmpdir compiles the value into the binary AND sets $TMPDIR in the
            # configure shell before config.guess runs.  Pre-create the output dirs so
            # config.guess finds a writable $TMPDIR.
            preConfigure = ''
              mkdir -p \
                $out/bin \
                $out/lib/unrealircd/modules \
                $out/etc/unrealircd \
                $out/var/tmp/unrealircd \
                $out/var/log/unrealircd \
                $out/var/cache/unrealircd \
                $out/var/lib/unrealircd
            '';

            configureFlags = [
              # Required: bypasses the "please use ./Config" guard
              "--enable-dynamic-linking"

              # CHECK_SSL defaults to enable_ssl=no; point it at the Nix store path so
              # it finds openssl/ssl.h and sets CRYPTOLIB="-lssl -lcrypto".
              "--enable-ssl=${pkgs.openssl.dev}"

              # Binary layout:
              #   $out/bin/unrealircd         — management wrapper (start/stop/restart/…)
              #   $out/lib/unrealircd/        — daemon binary, unrealircdctl, upgrade script
              #   $out/lib/unrealircd/modules — loadable .so modules
              "--with-bindir=${placeholder "out"}/lib/unrealircd"
              "--with-scriptdir=${placeholder "out"}/bin"
              "--with-modulesdir=${placeholder "out"}/lib/unrealircd/modules"
              "--with-docdir=${placeholder "out"}/share/doc/unrealircd"

              # Runtime directories – compiled in as defaults; actual runtime dirs should
              # be configured by the admin (or a NixOS service module).  Pointing them
              # under $out keeps the install phase entirely inside the sandbox.
              "--with-confdir=${placeholder "out"}/etc/unrealircd"
              "--with-datadir=${placeholder "out"}/var/lib/unrealircd"
              "--with-logdir=${placeholder "out"}/var/log/unrealircd"
              "--with-cachedir=${placeholder "out"}/var/cache/unrealircd"
              "--with-tmpdir=${placeholder "out"}/var/tmp/unrealircd"
              "--with-pidfile=${placeholder "out"}/var/run/unrealircd.pid"

              # Use system libraries for everything; no private lib dir needed
              "--without-privatelibdir"
              "--with-system-pcre2"
              "--with-system-argon2"
              "--with-system-sodium"
              "--with-system-cares"
              "--with-system-jansson"

              # Remote includes / URL fetching via libcurl
              "--enable-libcurl"
            ];

            postInstall = ''
              # The install target symlinks $out/bin/source → the build directory.
              # Remove it so the store path contains no references to /build.
              rm -f $out/bin/source

              # Expose the control utility alongside the management wrapper
              ln -s $out/lib/unrealircd/unrealircdctl $out/bin/unrealircdctl
            '';

            meta = with pkgs.lib; {
              description = "Highly advanced IRC server with modularity and security features";
              longDescription = ''
                UnrealIRCd is an open-source IRC server with extensive IRCv3 support,
                SSL/TLS, cloaking, JSON-RPC, advanced anti-flood and anti-spam systems,
                GeoIP, remote includes, and a highly configurable module system.
              '';
              homepage = "https://www.unrealircd.org";
              license = licenses.gpl2Plus;
              mainProgram = "unrealircd";
              platforms = platforms.unix;
            };
          };
        });

      overlays.default = final: prev: {
        unrealircd = self.packages.${final.system}.default;
      };

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = with pkgs; [ gdb ];
          };
        });
    };
}
