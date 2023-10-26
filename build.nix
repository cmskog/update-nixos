{ pkgs ? import <nixpkgs> {} }:
pkgs.callPackage ./.
{

# Define your boot devices here:
#
# boot-devices =
# [
#   "/dev/disk/by-id/your-boot-disk-id"
# ];
# boot-partition-number = 42;
# uefi-partition-number = 142;

}
