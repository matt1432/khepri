{
  lib,
  pkgs,
  config,
  ...
}: let
  inherit (lib) mkOption types unique;
  inherit (lib.lists) elem optionals;
  inherit (lib.strings) concatStringsSep;
  inherit (lib.attrsets) mapAttrsToList nameValuePair;

  inherit (lib) mkMerge mkIf listToAttrs head tail filter flatten findSingle getAttr mkForce mkOverride length;

  cfg = config.khepri;

  # ------------------------------------------------
  # OPTIONS
  # ------------------------------------------------
  compositionNetworkOptions = {...}: {
    options = {
      external = mkOption {
        default = false;
        type = types.bool;
      };
    };
  };

  compositionOptions = {...}: {
    options = {
      networks = mkOption {
        type = types.attrsOf (types.submodule compositionNetworkOptions);
        default = {};
      };

      services = mkOption {
        default = {};
        type = types.attrsOf (types.submodule serviceOptions);
      };

      volumes = mkOption {
        type = with types; listOf str;
        default = [];
      };
    };
  };

  serviceOptions = {name, ...}: {
    options = {
      capAdd = mkOption {
        type = with types; listOf str;
        default = [];
      };
      capDrop = mkOption {
        type = with types; listOf str;
        default = [];
      };

      cmd = mkOption {
        type = with types; listOf str;
        default = [];
      };

      containerName = mkOption {
        type = types.str;
        default = name;
      };

      cpus = mkOption {
        type = with types; nullOr numbers.nonnegative;
        default = null;
      };

      dependsOn = mkOption {
        type = with types; listOf str;
        default = [];
      };

      devices = mkOption {
        type = with types; listOf str;
        default = [];
      };

      dns = mkOption {
        type = with types; listOf str;
        default = [];
      };

      entrypoint = mkOption {
        type = with types; nullOr str;
        default = null;
      };

      environment = mkOption {
        type = with types; attrsOf str;
        default = {};
      };

      environmentFiles = mkOption {
        type = with types; listOf path;
        default = [];
      };

      expose = mkOption {
        type = with types; listOf str;
        default = [];
      };

      extraHosts = mkOption {
        type = with types; listOf str;
        default = [];
      };

      image = mkOption {
        type = with types; either str package;
      };

      networks = mkOption {
        type = with types; listOf str;
        default = [];
      };

      ports = mkOption {
        type = with types; listOf str;
        default = [];
      };

      privileged = mkOption {
        type = types.bool;
        default = false;
      };

      restart = mkOption {
        type = types.enum ["no" "always" "on-failure" "unless-stopped"];
        default = "no";
      };

      sysctls = mkOption {
        type = with types; listOf str;
        default = [];
      };

      tmpfs = mkOption {
        type = with types; listOf str;
        default = [];
      };

      user = mkOption {
        type = with types; nullOr str;
        default = null;
      };

      volumes = mkOption {
        type = with types; listOf str;
        default = [];
      };
    };
  };

  # ------------------------------------------------
  # FUNCTIONS
  # ------------------------------------------------
  mkContainerName = compositionName: serviceConfiguration:
    "${compositionName}_${serviceConfiguration.containerName}";

  mkNetworkName = compositionName: networkName: networkConfiguration:
    if networkConfiguration.external
    then networkName
    else "${compositionName}_${networkName}";

  mkSystemdTargetName = compositionName: "khepri-compose-${compositionName}-root";

  mkSystemdVolumeName = compositionName: volumeName: "docker-volume-${compositionName}_${volumeName}";

  mkSystemdNetworkName = compositionName: networkName: "docker-network-${compositionName}_${networkName}";

  getImageNameFromDerivation = drv: let
    attrNamesOf = lib.attrNames drv;
  in
    if elem "destNameTag" attrNamesOf
    then
      # image comming from dockerTools.pullImage
      drv.destNameTag
    else
      # image comming from dockerTools.buildImage
      if
        elem "imageName" attrNamesOf
        && elem "imageTag" attrNamesOf
      then "${drv.imageName}:${drv.imageTag}"
      else
        throw
        "Image '${drv}' is missing the attribute 'destNameTag'. Available attributes: ${
          concatStringsSep "," attrNamesOf
        }";

  composeRestartToSystemdRestart = restartStr:
    if restartStr == "unless-stopped"
    then "always"
    else restartStr;

  mkCanonicalServiceConfiguration = compositionName: compositionConfiguration: serviceName: serviceConfiguration: networkConfigurations: let
    mappedVolumes =
      map (volumeMapping: head (builtins.split ":" volumeMapping))
      serviceConfiguration.volumes;

    # Canonical name of each volume as definied in a compositions 'volumes' section
    # Cross reference those mapped volumes with the volumes definied in the composition, so that we only link docker volumes and not direct file mounts
    # TODO: Additionally, some sanity checks might be usefull here
    serviceVolumes =
      filter (volume: elem volume compositionConfiguration.volumes)
      mappedVolumes;

    # Construct the resulting mappings. For serviceVolumes, the mapping must be updated with the canonical name of that volume
    volumeMappings = map (mapping: let
      volumeMappingParts = builtins.split ":" mapping;
      volumeName = head volumeMappingParts;
    in
      if elem volumeName serviceVolumes
      then
        concatStringsSep ":" (flatten [
          "${compositionName}_${volumeName}"
          (tail volumeMappingParts)
        ])
      else mapping)
    serviceConfiguration.volumes;

    # Map all attached networks to their final name
    attachedNetworksConfigurations = map (networkName: (findSingle (networkConfiguration:
        networkConfiguration.name
        == networkName
        && networkConfiguration.composition == compositionName) (throw
        "error: network '${networkName}' is referenced by service '${serviceName}' in composition '${compositionName}' but definition on composition level could not be found")
      (throw
        "error: multiple network configurations for '${networkName}' found")
      networkConfigurations))
    serviceConfiguration.networks;

    containerName = mkContainerName compositionName serviceConfiguration;

    imageName =
      if builtins.isString serviceConfiguration.image
      then serviceConfiguration.image
      else getImageNameFromDerivation serviceConfiguration.image;
  in {
    hostName = serviceConfiguration.containerName;

    primaryNetwork =
      if attachedNetworksConfigurations == []
      then ""
      else (head attachedNetworksConfigurations).canonicalName;

    additionalNetworks =
      if attachedNetworksConfigurations == []
      then []
      else
        map (networkConfiguration: networkConfiguration.canonicalName)
        (tail attachedNetworksConfigurations);

    dependsOn = map (dependencyServiceName:
      mkContainerName compositionName
      (getAttr dependencyServiceName compositionConfiguration.services))
    serviceConfiguration.dependsOn;

    imageFile =
      if builtins.isAttrs serviceConfiguration.image
      then serviceConfiguration.image
      else null;

    # Additional information for systemd
    systemdTarget = mkSystemdTargetName compositionName;
    systemdVolumeDependencies =
      map (volumeName: "${mkSystemdVolumeName compositionName volumeName}.service")
      serviceVolumes;

    # Create the dependencies to the systemd services for each non-external service
    systemdNetworkDependencies =
      map
      (networkConfiguration: "${networkConfiguration.systemdService}.service")
      (filter (networkConfiguration: !networkConfiguration.external)
        attachedNetworksConfigurations);

    # Already handled params
    image = imageName;
    volumes = serviceVolumes;
    inherit
      containerName
      serviceName
      volumeMappings
      ;

    # Some extra parameters that are passed as is
    inherit
      (serviceConfiguration)
      capAdd
      capDrop
      cmd
      cpus
      devices
      dns
      entrypoint
      environment
      environmentFiles
      expose
      extraHosts
      ports
      privileged
      restart
      sysctls
      tmpfs
      user
      ;
  };

  mkCanonicalNetworkConfiguration = compositionName: networkName: networkConfiguration: {
    name = networkName;
    canonicalName = mkNetworkName compositionName networkName networkConfiguration;
    external = networkConfiguration.external;

    composition = compositionName;

    # Additional information for systemd
    systemdTarget = mkSystemdTargetName compositionName;
    systemdService = mkSystemdNetworkName compositionName networkName;
  };

  mkContainerConfiguration = serviceConfiguration:
    nameValuePair serviceConfiguration.containerName {
      volumes = serviceConfiguration.volumeMappings;
      inherit
        (serviceConfiguration)
        cmd
        dependsOn
        entrypoint
        environment
        environmentFiles
        image
        imageFile
        ports
        user
        ;

      extraOptions = let
        cpusOption =
          optionals (serviceConfiguration.cpus != null)
          ["--cpus=${toString serviceConfiguration.cpus}"];

        networkOption =
          optionals (serviceConfiguration.primaryNetwork != "")
          ["--network=${serviceConfiguration.primaryNetwork}"];

        privilegedOption =
          optionals serviceConfiguration.privileged
          ["--privileged"];

        capAddOptions =
          map (cap: "--cap-add=${cap}") serviceConfiguration.capAdd;

        capDropOptions =
          map (cap: "--cap-drop=${cap}") serviceConfiguration.capDrop;

        deviceOptions =
          map (device: "--device=${device}") serviceConfiguration.devices;

        dnsOptions =
          map (dns: "--dns=${dns}") serviceConfiguration.dns;

        exposeOptions =
          map (port: "--expose=${port}") serviceConfiguration.expose;

        extraHostsOptions =
          map (host: "--add-host=${host}") serviceConfiguration.extraHosts;

        sysctlsOptions =
          map (sysctl: "--sysctl=${sysctl}") serviceConfiguration.sysctls;

        tmpfsOptions =
          map (tmpfs: "--tmpfs=${tmpfs}") serviceConfiguration.tmpfs;
      in
        networkOption
        ++ capAddOptions
        ++ capDropOptions
        ++ cpusOption
        ++ deviceOptions
        ++ dnsOptions
        ++ exposeOptions
        ++ extraHostsOptions
        ++ privilegedOption
        ++ sysctlsOptions
        ++ tmpfsOptions
        ++ ["--network-alias=${serviceConfiguration.hostName}"];
    };

  mkSystemdServicesForContainers = serviceConfigurations: (map
    (serviceConfiguration: mkSystemdServiceForContainer serviceConfiguration)
    serviceConfigurations);

  mkSystemdServiceForContainer = serviceConfiguration: let
    dependencies = flatten [
      serviceConfiguration.systemdVolumeDependencies
      serviceConfiguration.systemdNetworkDependencies
    ];

    networkConnectCmds =
      concatStringsSep "&&" (map (networkName: "${pkgs.docker}/bin/docker network connect ${networkName} ${serviceConfiguration.containerName}")
        (serviceConfiguration.additionalNetworks));
  in
    nameValuePair "docker-${serviceConfiguration.containerName}" {
      path = [pkgs.docker pkgs.gnugrep];

      serviceConfig = {
        Restart = mkForce (composeRestartToSystemdRestart serviceConfiguration.restart);
        RestartMaxDelaySec = mkOverride 500 "1m";
        RestartSec = mkOverride 500 "100ms";
        RestartSteps = mkOverride 500 9;
      };

      after = dependencies;
      requires = dependencies;
      partOf = ["${serviceConfiguration.systemdTarget}.target"];
      wantedBy = ["${serviceConfiguration.systemdTarget}.target"];
      postStart =
        if length serviceConfiguration.additionalNetworks > 0
        then ''
          until [ `${pkgs.docker}/bin/docker container ls --format 'table {{.Names}}' | tail -n +2 | ${pkgs.gnugrep}/bin/grep -w "${serviceConfiguration.containerName}" -c` == 1 ]; do
            sleep 1;
          done;

          ${networkConnectCmds}
        ''
        else "";
    };

  mkSystemdServicesForVolumes = compositionName: serviceConfiguration: (map (volumeName:
    nameValuePair (mkSystemdVolumeName compositionName volumeName)
    (mkSystemdServiceForVolume compositionName volumeName))
  serviceConfiguration.volumes);

  mkSystemdServiceForVolume = compositionName: volumeName: let
    fullVolumeName = "${compositionName}_${volumeName}";
  in {
    path = [pkgs.docker];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      docker volume inspect ${fullVolumeName} || docker volume create ${fullVolumeName}
    '';
    partOf = ["${mkSystemdTargetName compositionName}.target"];
    wantedBy = ["${mkSystemdTargetName compositionName}.target"];
  };

  mkSystemdServicesForNetworks = networkConfigurations:
    map (networkConfiguration: (nameValuePair "docker-network-${networkConfiguration.canonicalName}"
      (mkSystemdServiceForNetwork networkConfiguration)))
    networkConfigurations;

  mkSystemdServiceForNetwork = networkConfiguration: let
    fullTargetName = "${networkConfiguration.systemdTarget}.target";
  in {
    path = [pkgs.docker];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${pkgs.docker}/bin/docker network rm -f ${networkConfiguration.canonicalName}";
    };

    script = ''
      docker network inspect ${networkConfiguration.canonicalName} || docker network create ${networkConfiguration.canonicalName}
    '';

    partOf = [fullTargetName];
    wantedBy = [fullTargetName];
  };
in {
  options.khepri = {
    compositions = mkOption {
      type = types.attrsOf (types.submodule compositionOptions);
      default = {};
    };
  };

  config = mkIf (cfg.compositions != {}) (let
    networkConfigurations = flatten (mapAttrsToList
      (compositionName: compositionConfiguration: (mapAttrsToList (networkName: networkConfiguration: (mkCanonicalNetworkConfiguration compositionName networkName
        networkConfiguration))
      compositionConfiguration.networks))
      cfg.compositions);

    serviceConfigurations = flatten (mapAttrsToList
      (compositionName: compositionConfiguration: (mapAttrsToList (serviceName: serviceConfiguration: (mkCanonicalServiceConfiguration compositionName
        compositionConfiguration
        serviceName
        serviceConfiguration
        networkConfigurations))
      compositionConfiguration.services))
      cfg.compositions);

    targets =
      unique
      (map (serviceConfiguration: serviceConfiguration.systemdTarget)
        serviceConfigurations);
  in {
    virtualisation.oci-containers.containers =
      listToAttrs
      (map (serviceConfiguration: mkContainerConfiguration serviceConfiguration)
        serviceConfigurations);

    systemd.services = let
      containers =
        listToAttrs (mkSystemdServicesForContainers serviceConfigurations);
      volumes = listToAttrs (flatten
        (mapAttrsToList (n: v: mkSystemdServicesForVolumes n v)
          cfg.compositions));
      networks = listToAttrs (mkSystemdServicesForNetworks
        (filter (networkConfiguration: !networkConfiguration.external)
          networkConfigurations));
    in
      mkMerge [containers volumes networks];

    systemd.targets = listToAttrs (map
      (target: nameValuePair target {wantedBy = ["multi-user.target"];})
      targets);
  });
}
