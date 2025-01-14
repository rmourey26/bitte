{ lib, pkgs, config, etcEncrypted, ... }:
let
  deployType = config.currentCoreNode.deployType or config.currentAwsAutoScalingGroup.deployType;
  isSops = deployType == "aws";
  relEncryptedFolder = lib.last (builtins.split "-" (toString config.secrets.encryptedRoot));

  docker-passwords-script = src: ''
    export PATH="${lib.makeBinPath (with pkgs; [ coreutils jq ])}"
    jq -r -e < ${src} .hashed \
      > /var/lib/docker-registry/docker-passwords
    chown docker-registry /var/lib/docker-registry/docker-passwords
  '';
in {

  networking.firewall.allowedTCPPorts = [
    config.services.dockerRegistry.port
  ];

  systemd.services.docker-registry.serviceConfig.Environment = [
    "REGISTRY_AUTH=htpasswd"
    "REGISTRY_AUTH_HTPASSWD_REALM=docker-registry"
    "REGISTRY_AUTH_HTPASSWD_PATH=/var/lib/docker-registry/docker-passwords"
  ];

  services = {
    dockerRegistry = {
      enable = lib.mkDefault true;
      enableDelete = true;
      enableGarbageCollect = true;
      enableRedisCache = true;
      listenAddress = "0.0.0.0";

      extraConfig.redis = {
        addr = "${config.services.dockerRegistry.redisUrl}";
        password = "${config.services.dockerRegistry.redisPassword}";
        db = 0;
        dialtimeout = "10ms";
        readtimeout = "10ms";
        writetimeout = "10ms";
        pool = {
          maxidle = 16;
          maxactive = 64;
          idletimeout = "300s";
        };
      };
    };

    redis.enable = true;
  };

  secrets.generate.redis-password = lib.mkIf isSops ''
    export PATH="${lib.makeBinPath (with pkgs; [ coreutils sops xkcdpass ])}"

    if [ ! -s ${relEncryptedFolder}/redis-password.json ]; then
      xkcdpass \
      | sops --encrypt --kms '${config.cluster.kms}' /dev/stdin \
      > ${relEncryptedFolder}/redis-password.json
    fi
  '';

  secrets.install.redis-password = lib.mkIf isSops {
    source = "${etcEncrypted}/redis-password.json";
    target = /run/keys/redis-password;
    inputType = "binary";
    outputType = "binary";
  };

  secrets.generate.docker-passwords = lib.mkIf isSops ''
    export PATH="${
      lib.makeBinPath (with pkgs; [ coreutils sops jq pwgen apacheHttpd ])
    }"

    if [ ! -s ${relEncryptedFolder}/docker-passwords.json ]; then
      password="$(pwgen -cB 32)"
      hashed="$(echo "$password" | htpasswd -i -B -n developer)"

      echo '{}' \
        | jq --arg password "$password" '.password = $password' \
        | jq --arg hashed "$hashed" '.hashed = $hashed' \
        | sops --encrypt --input-type json --output-type json --kms '${config.cluster.kms}' /dev/stdin \
        > ${relEncryptedFolder}/docker-passwords.new.json
      mv ${relEncryptedFolder}/docker-passwords.new.json ${relEncryptedFolder}/docker-passwords.json
    fi
  '';

  secrets.install.docker-passwords = lib.mkIf isSops {
    source = "${etcEncrypted}/docker-passwords.json";
    target = /run/keys/docker-passwords-decrypted;
    script = docker-passwords-script "/run/keys/docker-passwords-decrypted";
  };

  # For the prem case, hydrate-secrets handles the push to vault instead of sops
  # TODO: add proper docker password generation creds in the Rakefile
  # TODO: add more unified handling between aws and prem secrets
  age.secrets = lib.mkIf (!isSops) {
    docker-passwords = {
      file = config.age.encryptedRoot + "/docker/password.age";
      path = "/run/keys/docker-passwords-decrypted";
      owner = "root";
      group = "root";
      mode = "0644";
      script = docker-passwords-script "$src" + ''
        mv "$src" "$out"
      '';
    };

    redis-password = {
      file = config.age.encryptedRoot + "/redis/password.age";
      path = "/run/keys/redis-password";
      owner = "root";
      group = "root";
      mode = "0644";
    };
  };
}
