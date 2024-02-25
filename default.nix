{
  coreutils,
  cryptsetup,
  findutils,
  gnugrep,
  lib,
  lvm2,
  mount,
  nixos-rebuild,
  umount,
  util-linux,
  writeShellScriptBin,
  zfs,

  update-nixos-name ? "un",
  boot-partitions ? [],
  uefi-partitions ? []
} :


assert builtins.isString update-nixos-name;

assert builtins.isList boot-partitions;
assert builtins.length boot-partitions > 0;
assert builtins.all builtins.isString boot-partitions;

assert builtins.isList uefi-partitions;
assert builtins.length uefi-partitions > 0;
assert builtins.all builtins.isString uefi-partitions;

assert ((builtins.length boot-partitions) == (builtins.length uefi-partitions));


writeShellScriptBin
update-nixos-name
''
set \
  -o errexit \
  -o nounset \
  -o pipefail
shopt -s shift_verbose
set -o xtrace


declare -a BOOT_PARTITIONS
BOOT_PARTITIONS=(
${
  lib.strings.concatMapStrings
    (partition: " \"" + partition + "\"")
    boot-partitions
}
)
declare -a UEFI_PARTITIONS
UEFI_PARTITIONS=(
${
  lib.strings.concatMapStrings
    (partition: " \"" + partition + "\"")
    uefi-partitions
}
)
BOOT_ZFS_NAME="NixOS-boot"
BOOT_ROOT=/boot
UEFI_ROOT=$BOOT_ROOT/efi

UEFI_DM_NAME=uefi
UEFI_DM_DEVICE="/dev/mapper/$UEFI_DM_NAME"
BOOT_DM_NAME=boot
BOOT_DM_DEVICE="/dev/mapper/$BOOT_DM_NAME"
OPENED_BOOT_NAME=opened_boot
unset UEFI_PARTITION_SIZE_IN_SECTORS
unset BOOT_PARTITION_SIZE_IN_SECTORS
KIBI=$(( 2 ** 10 ))
MIBI=$(( $KIBI ** 2 ))

NIXOS_REBUILD_LOG="log.${update-nixos-name}.$(${coreutils}/bin/date)"

usage()
{
  local exit_value=$1
  shift

  local fmt="$1"
  fmt+='\n'
  shift

  printf "$fmt" "$@" >&2

  exit $exit_value
}

check_all_partitions()
{
  check_existance_and_equal_size

  check_for_all_identical_partitions
}

check_existance_and_equal_size()
{
  local all_devices_exist=y
  check_existance_and_equal_size_for_partition_type BOOT
  check_existance_and_equal_size_for_partition_type UEFI

  [[ $all_devices_exist ]]

  echo "All boot partitions have size $BOOT_PARTITION_SIZE_IN_SECTORS sectors and all UEFI partitions have size $UEFI_PARTITION_SIZE_IN_SECTORS sectors"
}

check_existance_and_equal_size_for_partition_type()
{
  local partitions_variable="$1_PARTITIONS"
  local -n partitions="$partitions_variable"

  if [[ -z "''${partitions[@]}" ]]
  then
    usage 2 "Array $partitions_variable is empty"
  fi

  for d in "''${partitions[@]}"
  do
    if [[ -b $d ]]
    then
      check_partition_size $d $1
    else
      echo "Block device for partition '$d'(of type $1) does not exist"
      all_devices_exist=
    fi
  done
}

check_partition_size()
{
  echo "Checking partition $1(type: $2)..."

  local partition_size_variable="$2_PARTITION_SIZE_IN_SECTORS"
  local partition_size=$(${util-linux}/bin/blockdev --getsz "$1")

  printf "\tSize: %d sectors(512 byte)\n" $partition_size

  if [[ -v $partition_size_variable ]]
  then
    if [[ $partition_size -ne ''${!partition_size_variable} ]]
    then
      usage 2 "Partition size(%d) for partition '$1' is not the same as the size hitherto seen %d\n" $partition_size ''${!partition_size_variable}
    fi
  else
    : ''${!partition_size_variable:=$partition_size}
  fi
}

check_for_all_identical_partitions()
{
  local partitions_identical=y

  check_for_identical_partitions_for_type BOOT
  check_for_identical_partitions_for_type UEFI

  [[ $partitions_identical ]]
}

check_for_identical_partitions_for_type()
{
  local partitions_variable="$1_PARTITIONS"
  local -n partitions="$partitions_variable"
  local common_checksum=

  for (( s=0; $s < (''${#partitions[@]} - 1); s++ ))
  do
    check_for_identical_partition \
      "''${partitions[$s]}" \
      "''${partitions[$(($s + 1))]}"
  done
}

check_for_identical_partition()
{
  echo "Comparing partition '$1' with '$2'..."
  local text=identical

  : ''${common_checksum:=$(checksum_partition "$1")}

  if [[ $common_checksum == $(checksum_partition "$2") ]]
  then
    :
  else
    text="NOT IDENTICAL"
    partitions_identical=
  fi

  echo "Partitions '$1' and '$2' are $text"
}

checksum_partition()
{
  ${coreutils}/bin/dd if="$1" bs=1M iflag=direct | ${coreutils}/bin/sha512sum | ${coreutils}/bin/cut -d ' ' -f 1
}

prepare_all_devices()
{
  prepare_device UEFI
  prepare_device BOOT
}

prepare_device()
{
  local partitions_variable=$1_PARTITIONS
  local -n partitions="$partitions_variable"
  local device_variable="$1_DM_DEVICE"
  local -n device="$device_variable"

  device="''${partitions[0]}"
}

remove_all_devices()
{
  remove_device UEFI
  remove_device BOOT
}

remove_device()
{
  local mirror_name_variable="$1_DM_NAME"
  local mirror_device_variable="$1_DM_DEVICE"

  if ${lvm2.bin}/bin/dmsetup remove ''${!mirror_name_variable}
  then
    :
  else
    echo "'dmsetup remove ''${!mirror_name_variable}' returned $?"
  fi
}

umount_with_check()
{
  if ${umount}/bin/umount $1
  then
    :
  else
    echo "'umount $1' returned $?"
  fi
}

close_and_remove_devices()
{
  umount_with_check "$UEFI_ROOT"
  umount_with_check "$BOOT_ROOT"

  if ${zfs}/bin/zpool export "$BOOT_ZFS_NAME"
  then
    :
  else
    echo "'zpool export $BOOT_ZFS_NAME' returned $?"
  fi

  if ${cryptsetup}/bin/cryptsetup close $OPENED_BOOT_NAME
  then
    :
  else
    echo "'cryptsetup close $BOOT_ZFS_NAME' returned $?"
  fi

  remove_all_devices
}

setup_and_open_devices()
{
  prepare_all_devices

  echo "Open boot device (LUKS UUID: $(${cryptsetup}/bin/cryptsetup luksUUID $BOOT_DM_DEVICE)):"
  ${cryptsetup}/bin/cryptsetup open $BOOT_DM_DEVICE $OPENED_BOOT_NAME

  ${zfs}/bin/zpool import "$BOOT_ZFS_NAME"

  ${coreutils}/bin/mkdir -p "$BOOT_ROOT"
  ${mount}/bin/mount -t zfs "$BOOT_ZFS_NAME" "$BOOT_ROOT"

  ${coreutils}/bin/mkdir -p "$UEFI_ROOT"
  ${mount}/bin/mount $UEFI_DM_DEVICE "$UEFI_ROOT"
}

exit_and_check()
{
  ignore_kill

  close_and_remove_devices
  check_for_all_identical_partitions
}

trap_exit()
{
  trap exit_and_check EXIT
}

ignore_kill()
{
  trap "" INT TERM
}

diagnostive_check_dir()
{
  local dir=$1
  local df_cmd="${coreutils}/bin/df --si '$dir'"
  local find_cmd="${findutils}/bin/find '$dir' -xdev -type d -print0 | ${findutils}/bin/xargs -0r ${coreutils}/bin/ls --fu -alt"

  ${coreutils}/bin/cat  <<-  END
	###
	### Output of "$df_cmd"
	###

	$(eval $df_cmd)

	###
	### Output of "$find_cmd"
	###

	$(eval $find_cmd)
	END
}

diagnostive_checks()
{
  ${coreutils}/bin/cat  <<-  END
	$1

	$(diagnostive_check_dir "''${BOOT_ROOT}")

	###
	### Output of "''${BOOT_ROOT}/grub/x86_64-efi/load.cfg"
	###

        $(${coreutils}/bin/cat "''${BOOT_ROOT}/grub/x86_64-efi/load.cfg")

	###
	### Output of "''${BOOT_ROOT}/grub/grub.cfg"
	###

        $(${coreutils}/bin/cat "''${BOOT_ROOT}/grub/grub.cfg")

	$(diagnostive_check_dir "''${UEFI_ROOT}")

	END
}

check_and_init()
{
  trap_exit
  setup_and_open_devices
}

duplicate_partitions()
{
  close_and_remove_devices

  setup_mirror BOOT
  setup_mirror UEFI
}

setup_mirror()
{
  local partitions_variable=$1_PARTITIONS
  local -n partitions="$partitions_variable"
  local partition_size_variable="$1_PARTITION_SIZE_IN_SECTORS"
  local mirror_name_variable="$1_DM_NAME"

  if [[ ''${#partitions[@]} -gt 1 ]]
  then
    echo "Checksum of first $1 partition: $(checksum_partition ''${partitions[0]})"

    {
      echo -n "0 ''${!partition_size_variable} mirror core 2 $(( ( 1 * $MIBI ) / 512 )) sync ''${#partitions[@]}"
      for d in "''${partitions[@]}"
      do
        echo -n " $d 0"
      done
      echo " 1 handle_errors"
    } | ${lvm2.bin}/bin/dmsetup create ''${!mirror_name_variable}

    local curr_event_nr=$(${lvm2.bin}/bin/dmsetup info -c --noheadings -o events "''${!mirror_name_variable}")

    echo "Before wait($1)"
    ${lvm2.bin}/bin/dmsetup status "''${!mirror_name_variable}"
    echo "curr_event_nr($1) = $curr_event_nr"

    ${lvm2.bin}/bin/dmsetup wait -v "''${!mirror_name_variable}" $curr_event_nr

    echo "status after wait($1)"
    ${lvm2.bin}/bin/dmsetup status "''${!mirror_name_variable}"

    ${lvm2.bin}/bin/dmsetup remove "''${!mirror_name_variable}"
  fi
}

do_real_upgrade()
{
  ignore_kill

  echo "nixos-rebuild log in file '$NIXOS_REBUILD_LOG'..."

  # Pick up the output of df before and after nixos-rebuild,
  # and the output of nixos-rebuild itself, in the log file
  {
    diagnostive_checks "Diagnostive checks before nixos-rebuild..."

    ${coreutils}/bin/cat  <<-  END

	###
	### Before nixos-rebuild $NIXOS_REBUILD_OPERATION $NIXOS_REBUILD_UPGRADE_OPTION --install-bootloader
	###
	END

    ${nixos-rebuild}/bin/nixos-rebuild \
      $NIXOS_REBUILD_OPERATION \
      $NIXOS_REBUILD_UPGRADE_OPTION \
      ''${NIXOS_REBUILD_NIXPKGS:+-I nixpkgs="$NIXOS_REBUILD_NIXPKGS"} \
      --install-bootloader --show-trace --verbose

    ${coreutils}/bin/cat  <<-  END
	###
	### After nixos-rebuild $NIXOS_REBUILD_OPERATION $NIXOS_REBUILD_UPGRADE_OPTION --install-bootloader
	###

	END

    diagnostive_checks "Diagnostive checks after nixos-rebuild..."
  }
# &> "$NIXOS_REBUILD_LOG"
}

handle_args()
{
  # Set defaults
  #
  NIXOS_REBUILD_OPERATION=dry-build
  unset NIXOS_REBUILD_UPGRADE
  unset NIXOS_REBUILD_NIXPKGS


  # Handle args
  #
  while [[ $# -ge 1 ]]
  do
    case $1 in

      (-b)
        NIXOS_REBUILD_OPERATION=boot
        ;;

      (-d)
        NIXOS_REBUILD_OPERATION=dry-build
        ;;

      (-n)
        if [[ $# -gt 1 ]]
        then
          shift
        else
          usage 2 "Option -n needs path argument"
        fi

        NIXOS_REBUILD_NIXPKGS="$1"
        if [[ ! -d $NIXOS_REBUILD_NIXPKGS ]]
        then
          usage 3 \
            "Argument to option -n(%s) is not a directory, or does not exist" \
            "$NIXOS_REBUILD_NIXPKGS"
        fi
        ;;

      (-s)
        NIXOS_REBUILD_OPERATION=switch
        ;;

      (-u)
        NIXOS_REBUILD_UPGRADE=y
        ;;

      (*)
        usage 1 "Usage: %s [-b | -d | -s] [-n <Path to nixpkgs directory>] [-u]" "$0"
        ;;

    esac

    shift
  done

  NIXOS_REBUILD_UPGRADE_OPTION="''${NIXOS_REBUILD_UPGRADE:+--upgrade}"

  echo "nixos-rebuild operation=$NIXOS_REBUILD_OPERATION"
  echo "nixos-rebuild upgrade=''${NIXOS_REBUILD_UPGRADE:-n}"
  echo "nixos-rebuild nixpkgs tweak=''${NIXOS_REBUILD_NIXPKGS:-(none)}"
}

do_upgrade()
{
  check_all_partitions

  read -p "Upgrade ? (y): "
  if [[ ! ( $REPLY == "" || $REPLY == "y" ) ]]
  then
    exit
  fi

  check_and_init

  do_real_upgrade

  duplicate_partitions
}

if [[ $EUID == 0 ]]
then
  handle_args "$@"

  do_upgrade
else
  usage 3 "sudo is needed when invoking '%s'" "''${0##*/}"
fi''
