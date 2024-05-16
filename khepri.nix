{ lib, pkgs, config, ... }:
with lib;
let
  cfg = config.khepri;
  compositionNetworkOptions = { ... }: {
    options = {
      external = mkOption {
        default = false;
        type = types.bool;
      };
    };
  };
  compositionOptions = { ... }: {
    options = {
      services = mkOption {
        default = { };
        type = types.attrsOf (types.submodule serviceOptions);
      };
      volumes = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      networks = mkOption {
        type = types.attrsOf (types.submodule compositionNetworkOptions);
        default = { };
      };
    };
  };
  serviceOptions = { ... }: {
    options = {
      image = mkOption { type = types.str; };
      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      containerName = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      volumes = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      cmd = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      networks = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      ports = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      dependsOn = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };
  # Helper functions to enable consistent name generation
  mkContainerName = compositionName: serviceName: serviceConfiguration:
    if serviceConfiguration.containerName != null then
      serviceConfiguration.containerName
    else
      "${compositionName}_${serviceName}";
  mkNetworkName = compositionName: networkName: networkConfiguration:
    if networkConfiguration.external then
      networkName
    else
      "${compositionName}_${networkName}";
  mkSystemdTargetName = compositionName:
    "khepri-compose-${compositionName}-root";
  mkSystemdVolumeName = compositionName: volumeName:
    "docker-volume-${compositionName}_${volumeName}";
  mkSystemdNetworkName = compositionName: networkName:
    "docker-network-${compositionName}_${networkName}";

  mkCanonicalServiceConfiguration =
    compositionName: compositionConfiguration: serviceName: serviceConfiguration:
    let
      mappedVolumes =
        map (volumeMapping: head (builtins.split ":" volumeMapping))
        serviceConfiguration.volumes;
      # Cross reference those mapped volumes with the volumes definied in the compoistion, so that we only link docker volumes and not direct file mounts
      # TODO: Additionally, some sanity checks might be usefull here
      serviceVolumes =
        filter (volume: elem volume compositionConfiguration.volumes)
        mappedVolumes;
      # Construct the resulting mappings. For serviceVolumes, the mapping must be updated with the canonical name of that volume
      volumeMappings = map (mapping:
        let
          volumeMappingParts = (builtins.split ":" mapping);
          volumeName = head volumeMappingParts;
        in if elem volumeName serviceVolumes then
          strings.concatStringsSep ":" (flatten [
            "${compositionName}_${volumeName}"
            (tail volumeMappingParts)
          ])
        else
          mapping) serviceConfiguration.volumes;
      # Make sure to construct the canonical network name, to be able to distinguish between internal and external networks.
      canonicalNetworkNames = map (networkName:
        mkNetworkName compositionName networkName
        (getAttr networkName compositionConfiguration.networks))
        serviceConfiguration.networks;
      containerName =
        mkContainerName compositionName serviceName serviceConfiguration;
    in {
      serviceName = serviceName;
      containerName = containerName;
      hostName = if serviceConfiguration.containerName != null then
        serviceConfiguration.containerName
      else
        serviceName;
      # Concrete mappings e.g. '/data:/var/data:rw'
      volumeMappings = volumeMappings;
      # Canonical name of each volume as definied in a compositions 'volumes' section
      volumes = serviceVolumes;
      primaryNetwork =
        if canonicalNetworkNames == [ ] then "" else head canonicalNetworkNames;
      additionalNetworks = if canonicalNetworkNames == [ ] then
        [ ]
      else
        tail canonicalNetworkNames;
      dependsOn = map (dependencyServiceName:
        mkContainerName compositionName dependencyServiceName
        (getAttr dependencyServiceName compositionConfiguration.services))
        serviceConfiguration.dependsOn;
      # Some extra parameters that are passed as is
      image = serviceConfiguration.image;
      environment = serviceConfiguration.environment;
      cmd = serviceConfiguration.cmd;
      ports = serviceConfiguration.ports;

      # Additional helpers for systemd
      systemdTarget = mkSystemdTargetName compositionName;
      systemdVolumeDependencies = map (volumeName:
        "${mkSystemdVolumeName compositionName volumeName}.service")
        serviceVolumes;
      systemdNetworkDependencies = map (networkName:
        "${mkSystemdNetworkName compositionName networkName}.service")
        serviceConfiguration.networks;
    };

  mkContainerConfiguration = serviceConfiguration:
    nameValuePair serviceConfiguration.containerName {
      image = serviceConfiguration.image;
      environment = serviceConfiguration.environment;
      volumes = serviceConfiguration.volumeMappings;
      cmd = serviceConfiguration.cmd;
      ports = serviceConfiguration.ports;
      dependsOn = serviceConfiguration.dependsOn;
      extraOptions = let
        network = if serviceConfiguration.primaryNetwork != "" then
          [ "--network=${serviceConfiguration.primaryNetwork}" ]
        else
          [ ];
      in network ++ [ "--network-alias=${serviceConfiguration.hostName}" ];
    };

  mkSystemdService = serviceConfiguration:
    let
      dependencies = flatten [
        serviceConfiguration.systemdVolumeDependencies
        serviceConfiguration.systemdNetworkDependencies
      ];
      networkConnectCmds = strings.concatStringsSep "&&" (map (networkName:
        "${pkgs.docker}/bin/docker network connect ${networkName} ${serviceConfiguration.containerName}")
        (serviceConfiguration.additionalNetworks));
    in nameValuePair "docker-${serviceConfiguration.containerName}" {
      path = [ pkgs.docker pkgs.gnugrep ];
      serviceConfig = {
        Restart = lib.mkOverride 500 "always";
        RestartMaxDelaySec = lib.mkOverride 500 "1m";
        RestartSec = lib.mkOverride 500 "100ms";
        RestartSteps = lib.mkOverride 500 9;
      };
      after = dependencies;
      requires = dependencies;
      partOf = [ "${serviceConfiguration.systemdTarget}.target" ];
      wantedBy = [ "${serviceConfiguration.systemdTarget}.target" ];
      postStart = if length serviceConfiguration.additionalNetworks > 0 then ''
        until [ `${pkgs.docker}/bin/docker container ls --format 'table {{.Names}}' | tail -n +2 | ${pkgs.gnugrep}/bin/grep -w "${serviceConfiguration.containerName}" -c` == 1 ]; do
          sleep 1;
        done;

        ${networkConnectCmds}
      '' else
        "";
    };

  mkVolumes = compositionName: serviceConfiguration:
    (map (volumeName:
      nameValuePair (mkSystemdVolumeName compositionName volumeName)
      (mkVolumeConfiguration compositionName volumeName))
      serviceConfiguration.volumes);

  mkVolumeConfiguration = compositionName: volumeName:
    let fullVolumeName = "${compositionName}_${volumeName}";
    in {
      path = [ pkgs.docker ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        docker volume inspect ${fullVolumeName} || docker volume create ${fullVolumeName}
      '';
      partOf = [ "${mkSystemdTargetName compositionName}.target" ];
      wantedBy = [ "${mkSystemdTargetName compositionName}.target" ];
    };

  mkNetworks = compositionName: compositionConfiguration:
    (mapAttrsToList (networkName: networkConfiguration:
      nameValuePair (mkSystemdNetworkName compositionName networkName)
      (mkNetworkConfiguration compositionName networkName networkConfiguration))
      compositionConfiguration.networks);
  mkNetworkConfiguration = compositionName: networkName: networkConfiguration:
    let
      fullNetworkName =
        mkNetworkName compositionName networkName networkConfiguration;
      fullTargetName = "${mkSystemdTargetName compositionName}.target";
    in {
      path = [ pkgs.docker ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "${pkgs.docker}/bin/docker network rm -f ${fullNetworkName}";
      };
      script = ''
        docker network inspect ${fullNetworkName} || docker network create ${fullNetworkName}
      '';
      partOf = [ fullTargetName ];
      wantedBy = [ fullTargetName ];

    };
in {
  options.khepri = {
    compositions = mkOption {
      type = types.attrsOf (types.submodule compositionOptions);
      default = { };
    };
  };

  config = mkIf (cfg.compositions != { }) (let
    serviceConfigurations = flatten (mapAttrsToList
      (compositionName: compositionConfiguration:
        (mapAttrsToList (serviceName: serviceConfiguration:
          (mkCanonicalServiceConfiguration compositionName
            compositionConfiguration serviceName serviceConfiguration))
          compositionConfiguration.services)) cfg.compositions);
    targets = lists.unique
      (map (serviceConfiguration: serviceConfiguration.systemdTarget)
        serviceConfigurations);
  in {
    virtualisation.oci-containers.containers = listToAttrs
      (map (serviceConfiguration: mkContainerConfiguration serviceConfiguration)
        serviceConfigurations);
    systemd.services = let
      mainServices = listToAttrs
        (map (serviceConfiguration: mkSystemdService serviceConfiguration)
          serviceConfigurations);
      volumes = listToAttrs
        (flatten (mapAttrsToList (n: v: mkVolumes n v) cfg.compositions));
      networks = listToAttrs
        (flatten (mapAttrsToList (n: v: mkNetworks n v) cfg.compositions));
    in mkMerge [ mainServices volumes networks ];
    systemd.targets = listToAttrs (map
      (target: nameValuePair target ({ wantedBy = [ "multi-user.target" ]; }))
      targets);
  });
}

