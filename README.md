# khepri

NixOS docker container orchestration in native nix similar to docker-compose. 

`khepri` allows you to easily define "container compositions" natively in your NixOS configuration similarly how you would define them in a `docker-compose.yaml`. This enables your NixOS configuration to become the source of truth for your system, without the need for another orchestration layer on top.

The main use-case for `khepri` is to easily run containerized workloads on NixOS, when NixOS modules for a application are not available/applicable and running a large container orchestrator like kubernetes is overkill.

# Usage

## Installation

Assuming you are using flakes to configure your NixOS system, you can add the `khepri` module as follows:

```nix
{
  inputs = {
    nixpkgs.url = "https://github.com/NixOS/nixpkgs/tarball/nixos-23.11";
    khepri = { url = "git+https://github.com/jrester/khepri.git"; };
  };
  outputs = { self, nixpkgs, khepri }: {
    nixosConfigurations.yourSystem = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix khepri.nixosModules.default ];
    };
  };
}
```

## Example

```nix
{ config, pkgs, lib, ... }: {
  khepri.compositions = {
    # The first composition for running the reverse proxy caddy
    caddy = {
      networks.proxy_net = { external = true;};
      volumes = ["caddy_data"];
      services = {
        caddy = {
          image = "caddy:alpine";
          networks = [ "proxy_net" ];
          volumes = [
            "caddy_data:/data:rw"
            "/etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro"
          ];
          ports = [ "80:80/tcp" "443:443/tcp" "443:443/udp" ];
        };
      };
    };
    # The second composition for running paperless-ngx
    paperless = {
      networks = {
        paperless = { };
        proxy_net = { external = true; };
      };
      volumes = [ "data" "pgdata" "redisdata" "documents" ];
      services = {
        broker = {
          image = "docker.io/library/redis:7";
          volumes = [ "redisdata:/data:rw" ];
          networks = [ "paperless" ];
        };
        db = {
          image = "docker.io/library/postgres:15";
          environment = {
            POSTGRES_DB = "paperless";
            POSTGRES_PASSWORD = "paperless";
            POSTGRES_USER = "paperless";
          };
          volumes = [ "pgdata:/var/lib/postgresql/data:rw" ];
          networks = [ "paperless" ];
        };
        tika = {
          image = "ghcr.io/paperless-ngx/tika:latest";
          networks = [ "paperless" ];
        };
        gotenberg = {
          image = "docker.io/gotenberg/gotenberg:7.8";
          cmd = [
            "gotenberg"
            "--chromium-disable-javascript=true"
            "--chromium-allow-list=file:///tmp/.*"
          ];
          networks = [ "paperless" ];
        };
        webserver = {
          image = "ghcr.io/paperless-ngx/paperless-ngx:latest";
          containerName = "paperless_web";
          environment = {
            PAPERLESS_DBHOST = "db";
            PAPERLESS_OCR_LANGUAGE = "deu";
            PAPERLESS_REDIS = "redis://broker:6379";
            PAPERLESS_SECRET_KEY = "super-secret-key";
            PAPERLESS_TASK_WORKERS = "2";
            PAPERLESS_TIKA_ENABLED = "1";
            PAPERLESS_TIKA_ENDPOINT = "http://tika:9998";
            PAPERLESS_TIKA_GOTENBERG_ENDPOINT = "http://gotenberg:3000";
            PAPERLESS_TIME_ZONE = "Europe/Berlin";
          };
          volumes = [
            "documents:/usr/src/paperless/media:rw"
            "data:/usr/src/paperless/data:rw"
          ];
          ports = [ "8000:8000/tcp" ];
          dependsOn = [ "db" "broker" "tika" "gotenberg" ];
          networks = [ "paperless" "proxy_net" ];
        };
      };
    };
  };
}
```


# Features

`khepri` orientates itself at the features of docker-compose. Currently, only a subset of the features of docker-compose are supported:

* volumes:
  * volume definitions
* networks:
  * network definitions
  * external/internal settings
* services:
  * container_name
  * port mappings
  * environment variables
  * depends_on
  * network bindings
  * volume mappings


# Comparison to other tools

## compose2nix

[compose2nix](https://github.com/aksiksi/compose2nix) can be used to automatically generate a NixOS configuration from a docker-compose.yaml file. Although, the results of this conversion can be easily integrated into your NixOS configuration, they are very verbose. Changes to your container setup, can become quite cumbersome. For example, systemd dependencies must be configured manually, instead of "just" adding a new volume to your container.
`khepri` in contrast provides an interface, that is similar to docker-compose and performs the steps done by `compose2nix` automatically under hood. Additionally, all of this happens natively in nix, to provide a streamlined deployment experience.

## arion

[arion](https://github.com/hercules-ci/arion) is a nix wrapper around docker-compose, offering a similar experience to docker-compose. Instead of writing a `docker-compose.yaml` file you would write a `arion-compose.nix` file and control it using `arion <up/down>`. Therefore, `arion` does not provide a native integration with NixOS, like `khepri`.
