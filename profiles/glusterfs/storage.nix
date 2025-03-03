{ config, self, pkgs, lib, nodeName, pkiFiles, ... }:
let
  # with 3 storage nodes, and redundancy at 1, we have 2/3 of size*3. We only
  # want to use 90% to ensure the quota is actually applied in time, so ew set
  # it to 2*0.9 = 1.8.
  quotaSize =
    config.tf.core.configuration.resource.aws_ebs_volume.${nodeName}.size * 1.8;
in {

  services.glusterfs.enable = true;

  systemd.services.glusterd.path = with pkgs; [ nettools ];

  boot.kernelModules = [ "xfs" ];

  fileSystems = {
    "/data/brick1" = {
      label = "brick";
      device = "/dev/nvme1n1";
      fsType = "xfs";
      formatOptions = "-i size=512";
      autoFormat = true;
    };

    "/mnt/gv0" = {
      device = "${nodeName}:/gv0";
      fsType = "glusterfs";
    };
  };

  systemd.services."mnt-gv0.mount" = {
    after = [ "setup-glusterfs.service" ];
    wants = [ "setup-glusterfs.service" ];

    serviceConfig.Restart = "on-failure";
    serviceConfig.RestartSec = "20s";
  };

  systemd.services.setup-glusterfs = {
    wantedBy = [ "multi-user.target" ];
    after = [ "glusterfs.service" ];
    path = with pkgs; [ glusterfs gnugrep xfsprogs utillinux jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "20s";
      ExecStart = pkgs.writeBashChecked "setup-glusterfs.sh" ''
        set -exuo pipefail

        for peer in storage-{0..2}; do
          gluster peer probe $peer
        done

        xfs_growfs /data/brick1

        mkdir -p /data/brick1/gv0
        if ! gluster volume info 2>&1 | grep 'Volume Name: gv0'; then
          gluster volume create gv0 \
            disperse 3 \
            redundancy 1 \
            storage-0:/data/brick1/gv0 \
            storage-1:/data/brick1/gv0 \
            storage-2:/data/brick1/gv0 \
            force
        fi

        gluster volume start gv0 force

        gluster volume bitrot gv0 enable || true
        gluster volume quota gv0 enable || true
        gluster volume quota gv0 limit-usage / ${toString quotaSize}GB || true
      '';
    };
  };
}
