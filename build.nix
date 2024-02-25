{ pkgs ? import <nixpkgs> {} }:
[

  (
    pkgs.callPackage ./.
      {

        update-nixos-name = "un-some-usb-memory";
        boot-partitions =
        [
          "/dev/disk/by-partuuid/<some-boot-partition-uuid>"
        ];
        uefi-partitions =
        [
          "/dev/disk/by-partuuid/<some-uefi-partition-uuid>"
        ];

      }
  )

  (
    pkgs.callPackage ./.
      {

        update-nixos-name = "un-some-other-usb-memory-and-and-some-sd-card";
        boot-partitions =
        [
          "/dev/disk/by-partuuid/<some-boot-partition-uuid-on-the-usb-memory>"
          "/dev/disk/by-partuuid/<some-boot-partition-uuid-on-the-sd-card>"
        ];
        uefi-partitions =
        [
          "/dev/disk/by-partuuid/<some-uefi-partition-uuid-on-the-usb-memory>"
          "/dev/disk/by-partuuid/<some-uefi-partition-uuid-on-the-sd-card>"
        ];

      }
  )

]
