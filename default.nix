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
  boot-devices ? [],
  boot-partition-number ? null,
  uefi-partition-number ? null
} :


assert builtins.isString update-nixos-name;
assert builtins.isList boot-devices;
assert builtins.length boot-devices > 0;
assert builtins.all builtins.isString boot-devices;
assert builtins.isInt boot-partition-number;
assert builtins.isInt uefi-partition-number;


writeShellScriptBin
update-nixos-name
''
set \
  -o errexit \
  -o nounset \
  -o pipefail
shopt -s shift_verbose


BOOT_DEVICES=(
${
  lib.strings.concatMapStrings (device: " \"" + device + "\"") boot-devices
}
)
BOOT_PARTITION_NUMBER=${builtins.toString boot-partition-number}
BOOT_ZFS_NAME="NixOS-boot"
BOOT_ROOT=/boot
UEFI_PARTITION_NUMBER=${builtins.toString uefi-partition-number}
UEFI_ROOT=$BOOT_ROOT/efi

UEFI_DM_NAME=uefi
UEFI_DM_DEVICE="/dev/mapper/$UEFI_DM_NAME"
BOOT_DM_NAME=boot
BOOT_DM_DEVICE="/dev/mapper/$BOOT_DM_NAME"
OPENED_BOOT_NAME=opened_boot
UEFI_PARTITION_SIZE_IN_SECTORS=
BOOT_PARTITION_SIZE_IN_SECTORS=
KIBI=$(( 2 ** 10 ))
MIBI=$(( $KIBI ** 2 ))
PARTITIONS_IDENTICAL=y

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

part_dev()
{
  echo "$1-part$2"
}

check_partition()
{
  local partition_number_variable="$2_PARTITION_NUMBER"
  local partition_number=''${!partition_number_variable}
  local partition_size_variable="$2_PARTITION_SIZE_IN_SECTORS"
  local partition=$(part_dev $1 ''${partition_number})

  if [[ ! -b $partition ]]
  then
    usage 1 "Partition '%s' does not exist, or is not a block device\n" "$partition"
  fi

  local partition_size=$(${util-linux}/bin/blockdev --getsz "$partition")

  printf "\tChecking partition number %d($2): %s; Size: %d sectors(512 byte)\n" $partition_number $partition $partition_size

  if [[ $partition_size -ne ''${!partition_size_variable:=$partition_size} ]]
  then
    usage 2 "Partition size(%d) for partition '%s' is not the same as the size hitherto seen %d\n" $partition_size "$partition" ''${!partition_size_variable}
  fi
}

check_device()
{
  echo Checking device $1...
  check_partition $1 UEFI
  check_partition $1 BOOT
}

check_existance_and_equal_size()
{
  local all_devices_exist=y

  if [[ -z "''${BOOT_DEVICES[@]}" ]]
  then
    usage 2 "Array BOOT_DEVICES is empty"
  fi

  for d in "''${BOOT_DEVICES[@]}"
  do
    if [[ -b $d ]]
    then
      check_device $d
    else
      echo Block device $d does not exist
      all_devices_exist=
    fi
  done

  [[ $all_devices_exist ]]

  echo All devices have UEFI partition size $UEFI_PARTITION_SIZE_IN_SECTORS sectors \
    and boot partition size $BOOT_PARTITION_SIZE_IN_SECTORS sectors
}

check_all_devices()
{
  check_existance_and_equal_size

  check_for_all_identical_devices
}

check_for_identical_partition()
{
  local partition_number_variable=$3_PARTITION_NUMBER
  local partition_number=''${!partition_number_variable}
  local first_partition=$(part_dev $1 $partition_number)
  local second_partition=$(part_dev $2 $partition_number)
  local text=identical

  if ${coreutils}/bin/cmp -s $first_partition $second_partition
  then
    :
  else
    text="NOT IDENTICAL(cmp returned $?)"
    PARTITIONS_IDENTICAL=
  fi

  echo "Partitions $first_partition and $second_partition are $text"
}

check_for_identical_device()
{
  printf "Comparing device %s with %s...\n" $1 $2
  check_for_identical_partition $1 $2 UEFI
  check_for_identical_partition $1 $2 BOOT
}

check_for_all_identical_devices()
{
  for (( s=0; $s < (''${#BOOT_DEVICES[@]} - 1); s++ ))
  do
    local first_device=''${BOOT_DEVICES[$s]}
    local second_device=''${BOOT_DEVICES[$(($s + 1))]}

    check_for_identical_device $first_device $second_device
  done

  [[ $PARTITIONS_IDENTICAL ]]
}

setup_all_mirror_devices()
{
  setup_mirror_device UEFI
  setup_mirror_device BOOT
}

setup_mirror_device()
{
  local partition_number_variable="$1_PARTITION_NUMBER"
  local partition_size_variable="$1_PARTITION_SIZE_IN_SECTORS"
  local mirror_name_variable="$1_DM_NAME"
  local device_variable="$1_DM_DEVICE"
  local -n device="$device_variable"

  if [[ ''${#BOOT_DEVICES[@]} == 1 ]]
  then
    device="$(part_dev ''${BOOT_DEVICES[0]} ''${!partition_number_variable})"
  else
    {
      echo -n "0 ''${!partition_size_variable} mirror  core 2 $(( ( 1 * $MIBI ) / 512 )) nosync  ''${#BOOT_DEVICES[@]}"
      for d in "''${BOOT_DEVICES[@]}"
      do
        echo -n " $(part_dev $d ''${!partition_number_variable}) 0"
      done
      echo "  1 handle_errors"
    } | ${lvm2}/bin/dmsetup create ''${!mirror_name_variable}
    device="/dev/mapper/''${!mirror_name_variable}"
  fi
}

remove_all_mirror_devices()
{
  remove_mirror_device UEFI
  remove_mirror_device BOOT
}

remove_mirror_device()
{
  local mirror_name_variable="$1_DM_NAME"

  if ${lvm2}/bin/dmsetup info ''${!mirror_name_variable} >& /dev/null
  then
    ${lvm2}/bin/dmsetup remove ''${!mirror_name_variable}
  fi
}

umount_with_check()
{
  if ${coreutils}/bin/cut -d ' ' -f 2 /proc/mounts | ${gnugrep}/bin/grep -q "^$1$"
  then
    ${umount}/bin/umount $1
  fi
}

close_and_remove_devices()
{
  umount_with_check $UEFI_ROOT
  umount_with_check $BOOT_ROOT

  if ${zfs}/bin/zpool list "$BOOT_ZFS_NAME" >& /dev/null
  then
    ${zfs}/bin/zpool export "$BOOT_ZFS_NAME"
  fi

  if ${cryptsetup}/bin/cryptsetup status $OPENED_BOOT_NAME >& /dev/null
  then
    ${cryptsetup}/bin/cryptsetup close $OPENED_BOOT_NAME
  fi

  remove_all_mirror_devices
}

setup_and_open_devices()
{
  setup_all_mirror_devices

  echo "Open boot device (LUKS UUID: $(${cryptsetup}/bin/cryptsetup luksUUID $BOOT_DM_DEVICE)):"
  ${cryptsetup}/bin/cryptsetup open $BOOT_DM_DEVICE $OPENED_BOOT_NAME

  ${zfs}/bin/zpool import "$BOOT_ZFS_NAME"

  ${mount}/bin/mount -t zfs "$BOOT_ZFS_NAME" $BOOT_ROOT
  ${mount}/bin/mount $UEFI_DM_DEVICE $UEFI_ROOT
}

exit_and_check()
{
  ignore_kill

  close_and_remove_devices
  check_for_all_identical_devices
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
      --install-bootloader

    ${coreutils}/bin/cat  <<-  END
	###
	### After nixos-rebuild $NIXOS_REBUILD_OPERATION $NIXOS_REBUILD_UPGRADE_OPTION --install-bootloader
	###

	END

    diagnostive_checks "Diagnostive checks after nixos-rebuild..."
  } &> "$NIXOS_REBUILD_LOG"
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
  check_all_devices

  read -p "Upgrade ? (y): "
  if [[ ! ( $REPLY == "" || $REPLY == "y" ) ]]
  then
    exit
  fi

  check_and_init

  do_real_upgrade
}

if [[ $EUID == 0 ]]
then
  handle_args "$@"

  do_upgrade
else
  usage 3 "sudo is needed when invoking '%s'" "''${0##*/}"
fi''
