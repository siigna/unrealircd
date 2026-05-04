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

            # config.guess needs a writable $TMPDIR; set it so the
            # Nix sandbox doesn't use $HOME/unrealircd/tmp which doesn't exist.
            TMPDIR = "/tmp/bx-test-ircd/tmp";

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
                $out/var/log/unrealircd \
                $out/var/lib/unrealircd \
                $out/var/run
              mkdir -p /tmp/bx-test-ircd/tmp /tmp/bx-test-ircd/cache
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
              # --with-rundir sets defaults for tmp/data/log/cache/pid/ctl.
              # Individual flags override these.  We want tmp and cache to be
              # writable at test runtime, so we point rundir at /tmp/bx-test-ircd.
              # Explicit --with-datadir etc. keep data inside $out.
              "--with-rundir=/tmp/bx-test-ircd"
              # Override tmpdir explicitly so config.guess can write there
              "--with-tmpdir=/tmp/bx-test-ircd/tmp"
              "--with-cachedir=/tmp/bx-test-ircd/cache"
              "--with-datadir=${placeholder "out"}/var/lib/unrealircd"
              "--with-logdir=${placeholder "out"}/var/log/unrealircd"
              "--with-pidfile=/tmp/bx-test-ircd/unrealircd.pid"
              "--with-controlfile=/tmp/bx-test-ircd/unrealircd.ctl"

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

              # Generate a self-signed TLS certificate into CONFDIR/tls/ so that
              # the server can start without requiring external cert provisioning.
              # This is a development/test cert — replace for production use.
              mkdir -p $out/etc/unrealircd/tls
              ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 \
                -keyout $out/etc/unrealircd/tls/server.key.pem \
                -out    $out/etc/unrealircd/tls/server.cert.pem \
                -days 3650 -nodes \
                -subj "/CN=unrealircd.local" 2>/dev/null
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
