{ config, pkgs, lib, pkiFiles, letsencryptCertMaterial, ... }:
let
  deployType = config.currentCoreNode.deployType or config.currentAwsAutoScalingGroup.deployType;
in {
  options = {
    services.ingress = { enable = lib.mkEnableOption "Enable Ingress"; };
  };
  config = {

    systemd.services.ingress = lib.mkIf config.services.ingress.enable {
      description = "HAProxy (ingress)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        StartLimitInterval = "20s";
        StartLimitBurst = 10;
      };

      serviceConfig = let
        certChainFile = if deployType == "aws" then pkiFiles.certChainFile
                        else pkiFiles.serverCertChainFile;
        certKeyFile = if deployType == "aws" then pkiFiles.keyFile
                      else pkiFiles.serverKeyFile;
        preScript = pkgs.writeBashChecked "ingress-start-pre" ''
          export PATH="${lib.makeBinPath [ pkgs.coreutils ]}"
          set -exuo pipefail
          cp ${pkiFiles.caCertFile} consul-ca.pem
          cp ${certKeyFile} consul-key.pem
          cat ${certChainFile} ${certKeyFile} > consul-crt.pem

          cat \
            ${letsencryptCertMaterial.certFile} \
            ${letsencryptCertMaterial.keyFile} \
            ${../lib/letsencrypt.pem} \
          > acme-full.pem

          # when the master process receives USR2, it reloads itself using exec(argv[0]),
          # so we create a symlink there and update it before reloading
          ln -sf ${pkgs.haproxy}/sbin/haproxy /run/ingress/haproxy
          # when running the config test, don't be quiet so we can see what goes wrong
          /run/ingress/haproxy -c -f /var/lib/ingress/haproxy.conf

          chown --reference . --recursive .
        '';
      in {
        StateDirectory = "ingress";
        RuntimeDirectory = "ingress";
        WorkingDirectory = "/var/lib/ingress";
        DynamicUser = true;
        User = "ingress";
        Group = "ingress";
        Type = "notify";
        ExecStartPre = "!${preScript}";
        ExecStart =
          "/run/ingress/haproxy -Ws -f /var/lib/ingress/haproxy.conf -p /run/ingress/haproxy.pid";
        # support reloading
        ExecReload = [
          "${pkgs.haproxy}/sbin/haproxy -c -f /var/lib/ingress/haproxy.conf"
          "${pkgs.coreutils}/bin/ln -sf ${pkgs.haproxy}/sbin/haproxy /run/ingress/haproxy"
          "${pkgs.coreutils}/bin/kill -USR2 $MAINPID"
        ];
        KillMode = "mixed";
        SuccessExitStatus = "143";
        Restart = "always";
        TimeoutStopSec = "30s";
        RestartSec = "5s";
        # upstream hardening options
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        SystemCallFilter =
          "~@cpu-emulation @keyring @module @obsolete @raw-io @reboot @swap @sync";
        # needed in case we bind to port < 1024
        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
      };
    };
  };

}
