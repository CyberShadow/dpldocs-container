{ production ? true
, uid ? 1000
}:
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c00f20377be57a37df5cf7986198aab6051c0057.tar.gz";
    sha256 = "sha256:0y5lxq838rzia2aqf8kh2jdv8hzgi7a6hlswsklzkss27337hrcn";
  };
  pkgs = import nixpkgs {};

  # The source code for the program which generates the HTML documentation.
  adrdoxSource = pkgs.fetchFromGitHub {
    owner = "adamdruppe";
    repo = "adrdox";
    rev = "f4c59ebe368c74a148817c0d53bec626f5131ff0";
    sha256 = "sha256-zXncgEHlejKm3UAW+ypWzIjUJMTadcJugrCFpnZfrFI=";
  };

  # The source code for the program which downloads Dub packages,
  # and generates their documentation using adrdox.
  dpldocsSource = pkgs.fetchFromGitHub {
    owner = "adamdruppe";
    repo = "dpldocs";
    rev = "ec9da691ff83e4d2a4a71835a37b27d365086720";
    sha256 = "sha256-shICsuoKU5WRzIL12oMdfOe1V0WIDpaOClHSbryt098=";
  };

  # adrdox templates for serving documentation as on dpldocs.info.
  dpldocsBuildCopy = pkgs.fetchzip {
    urls = [
      "https://dpldocs.info/dpldocs-build-copy.zip"
      # Vladimir's mirror:
      "https://dump.cy.md/2c4ca07aece80c1664ebed92d21a76ad/dpldocs-build-copy.zip"
    ];
    sha256 = "sha256-Kn3+j4mcMb4JnpfuH1sDh1x7rDP/iwbJUaDpWgsH7OY=";
  };

  # Adam's general purpose library.
  arsd = pkgs.fetchFromGitHub {
    owner = "adamdruppe";
    repo = "arsd";
    rev = "b0557bba5f60f5f14adcfa211070c0d0a55f9042";
    sha256 = "sha256-WhxtToMEK+v6VKVhfa8bl2kY2Jn93im72ykMBwhqxgg=";
  };

  adrdox = pkgs.stdenv.mkDerivation {
    name = "adrdox";
    src = adrdoxSource;

    buildInputs = [
      pkgs.dmd
      pkgs.postgresql
    ];
    # The Makefile is detected and invoked automatically.
    makeFlags = "pq";  # We need the target that builds with PostgreSQL support.
    installPhase = ''
      install -Dt $out/bin doc2
    '';
  };

  dpldocs = pkgs.stdenv.mkDerivation {
    name = "dpldocs";
    src = dpldocsSource;
    patches = [
      # Allow running the database as an unprivileged user
      ./0002-dl-Un-hardcode-the-database-username.patch
    ] ++ (pkgs.lib.optionals (!production) [
      # Relax Host header check
      ./0001-dl-Allow-running-on-non-default-HTTP-ports.patch
    ]);

    buildInputs = [
      pkgs.postgresql
    ];
    buildPhase = ''
      find . -type f -print0 | xargs -0 sed -i s/dpldocs.info/dpldocs.dlang.org/g
      ${pkgs.dmd}/bin/dmd \
        ${pkgs.lib.optionalString (!production) "-g -debug"} \
        -i -mv=arsd=${arsd} -version=scgi dl.d
    '';
    installPhase = ''
      install -Dt $out/bin dl
    '';
  };

  nginxConfig = pkgs.writeText "nginx.conf" ''
    daemon off;
    pid /dev/null;
    worker_processes 1;  # TODO
    events { worker_connections 1024; }
    http {
      access_log /dev/stderr;
      error_log /dev/stderr;
      server {
        listen 8081;
        location / {
          # Invoke dpldocs via SCGI
          include ${pkgs.nginx}/conf/scgi_params;
          scgi_pass 127.0.0.1:4000;
        }
      }
    }
  '';

  containerScript = pkgs.writeScript "container" ''
    #!${pkgs.runtimeShell}
    set -eEuo pipefail

    # Create a PostgreSQL cluster, if necessary
    if [[ ! -e /dpldocs-db/PG_VERSION ]]; then
      ${pkgs.postgresql}/bin/initdb /dpldocs-db
    fi

    # Start PostgreSQL
    ${pkgs.postgresql}/bin/pg_ctl start -D /dpldocs-db

    # Initialize the database, if necessary
    if ! ${pkgs.postgresql}/bin/psql -d adrdox -c "SELECT 1" &>/dev/null; then
      ${pkgs.postgresql}/bin/createdb adrdox
      ${pkgs.postgresql}/bin/psql -d adrdox -f ${adrdoxSource}/db.sql
    fi

    # Start dpldocs
    (
      export DPLDOCS_DB='dbname=adrdox'  # Connect with default username
      ${dpldocs}/bin/dl --port 4000
    ) &

    # Run nginx
    exec ${pkgs.nginx}/bin/nginx \
      -e stderr \
      -c ${nginxConfig}
  '';

  containerImage = pkgs.dockerTools.streamLayeredImage {
    name = "dpldocs";
    tag = "latest";
    fakeRootCommands = ''
      set -eEuo pipefail

      # Create /bin/sh (needed for initdb)
      mkdir -m 555 bin
      ln -s ${pkgs.bash}/bin/bash bin/sh

      # Create /tmp for nginx
      mkdir -m1777 tmp

      # Create PostgreSQL UNIX socket directory
      mkdir -p run/postgresql
      chown ${toString uid}:${toString uid} run/postgresql

      # Create dpldocs working directories
      mkdir dpldocs dpldocs-db
      chown ${toString uid}:${toString uid} dpldocs dpldocs-db

      # Prepare dpldocs build directory
      cp -a ${dpldocsBuildCopy} dpldocs-build
      chmod -R u+rwX dpldocs-build
      chown -R ${toString uid}:${toString uid} dpldocs-build
      ln -s ${adrdox}/bin/doc2 dpldocs-build/doc2
    '';
    config = {
      User = toString uid;
      Cmd = [ containerScript ];
      Env = [
        # Allow dpldocs to call the code.dlang.org API and download package archives over HTTPS
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      ExposedPorts = {
        "8080/tcp" = {};
      };
    };
  };
in {
  inherit adrdox dpldocs containerImage;
}
