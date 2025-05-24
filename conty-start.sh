#!/bin/sh
# shellcheck disable=3043 # local keyword is supported by busybox sh

# NOTE 2025-05-16: Busybox sh as provided in arch repository runs bundled
# utilities without $PATH search which this script relies on

set -e

LC_ALL_ORIG="$LC_ALL"
export LC_ALL=C

# Refuse to run as root unless environment variable is set
if [ -n "$ALLOW_ROOT" ] && [ "$(id -u)" -eq 0 ]; then
	echo 'Do not run this script as root!'
	echo
	echo 'If you really need to run it as root and know what you are doing, set'
	echo 'the ALLOW_ROOT environment variable.'
    exit 1
fi

# Conty version
script_version="1.28"

# Environment variables used by conty to unset before running bwrap
conty_variables='CONTY_PROGRAM_SIZE CONTY_BUSYBOX_SIZE CONTY_SCRIPT_SIZE CONTY_UTILS_SIZE
USE_SYS_UTILS HOME_DIR CUSTOM_MNT DISABLE_NET SANDBOX ENABLE_DBUS KEEP_ENV PERSIST_HOME'

# Full path to conty is provided as first argument by init
conty="$1"; shift
script="$0"
conty_name="$(basename "$conty")"
script_name="$(basename "$script")"
program_size="$CONTY_PROGRAM_SIZE"
busybox_size="$CONTY_BUSYBOX_SIZE"
script_size="$CONTY_SCRIPT_SIZE"
utils_size="$CONTY_UTILS_SIZE"
utils_offset=$((program_size + busybox_size + script_size))
image_offset=$((utils_offset + utils_size))
if [ "$(tail -c +"$((image_offset + 1))" "$conty" | head -c 6)" = "DWARFS" ]; then
	 dwarfs_image=1
fi
# MD5 of the first 4 MB and the last 1 MB of the conty
script_md5="$(head -c 4000000 "$conty" | md5sum | head -c 7)"_"$(tail -c 1000000 "$conty" | md5sum | head -c 7)"

conty_config_home="${XDG_CONFIG_HOME:-$HOME/.config}/conty"
conty_data_home="${XDG_DATA_HOME:-$HOME/.local/share}/conty"
persist_home_dir="${HOME_DIR:-$conty_data_home/home}"
mount_point="${CUSTOM_MNT:-$conty_data_home/mnt_$script_md5}"

utils_dir="$conty_data_home/utils"
if [ -z "$USE_SYS_UTILS" ]; then
	if [ ! -d "$utils_dir" ]; then
		mkdir -p "$utils_dir"
		tail -c +"$((utils_offset + 1))" "$conty" | head -c "$utils_size" \
			| tar x -J -C "$utils_dir"
	fi
fi

# Check if FUSE is installed
if ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; then
	echo "Please install fuse2 or fuse3 and run the script again."
	exit 1
fi

if command -v fusermount3 1>/dev/null; then
	fuse_version=3
fi

run_util() {
	exe="$1"; shift
	if [ -z "$USE_SYS_UTILS" ]; then
		"$utils_dir"/lib/ld-linux-x86-64.so.2 --library-path "$utils_dir"/lib "$utils_dir/bin/$exe" "$@"
	else
		"$exe" "$@"
	fi
}

run_bwrap () {
	local args_file cwd XDG_RUNTIME_DIR
	args_file="$(mktemp)"
	cwd="$(pwd)"
	XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
	args() {
		printf -- '%s\0' "$@" >> "$args_file"
	}

	args --ro-bind "$mount_point" / \
		 --dev-bind /dev /dev \
		 --ro-bind /sys /sys \
         --proc /proc \
         --ro-bind-try /etc/asound.conf /etc/asound.conf \
		 --ro-bind-try /etc/localtime /etc/localtime \
		 --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
		 --ro-bind-try /etc/passwd /etc/passwd \
		 --ro-bind-try /etc/group /etc/group

	if [ -z "$SANDBOX" ]; then
		for dir in /home /tmp /run /mnt /media /opt /initrd; do
			args --bind-try "$dir" "$dir"
		done
    else
		[ -z "$KEEP_ENV" ] && args --clearenv
		local runtime_dir
		runtime_dir="/run/user/$(id -u)"
        args --tmpfs /tmp \
			 --tmpfs /var \
			 --tmpfs /run \
			 --symlink /run /var/run \
			 --perms 755 --dir "$runtime_dir" \
			 --setenv XDG_RUNTIME_DIR "$runtime_dir" \
			 --ro-bind-try "$XDG_RUNTIME_DIR"/pulse "$runtime_dir"/pulse \
			 --ro-bind-try "$XDG_RUNTIME_DIR"/pipewire-0 "$runtime_dir"/pipewire-0 \
			 --unshare-pid --unshare-user --unshare-uts \
			 --unsetenv PATH \
			 --new-session

		if [ -n "$PERSIST_HOME" ]; then
			mkdir -p "$persist_home_dir"
			args --bind "persist_home_dir" /home
			# If we are inside home dir then adjust working directory so that
			# programs provided as relative path can be ran
			case "$cwd" in
				"$persist_home_dir"*) args --chdir /home/"${cwd#"$persist_home_dir"}" ;;
			esac
		else
			args --tmpfs /home
		fi
		args --setenv HOME /home
		# Same as home dir check above but for mount point location
		case "$cwd" in
			"$mount_point"*) args --chdir /"${cwd#"$mount_point"}" ;;
		esac

		if [ -n "$WAYLAND_DISPLAY" ]; then
			args --ro-bind-try "$XDG_RUNTIME_DIR"/"$WAYLAND_DISPLAY" "$runtime_dir"/"$WAYLAND_DISPLAY" \
				 --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"
		fi

		if [ -n "$DISPLAY" ]; then
			args --dir /tmp/.X11-unix
			args --bind-try /tmp/.X11-unix/X"${DISPLAY##:}" /tmp/.X11-unix/X"${DISPLAY##:}" \
				 --setenv DISPLAY "$DISPLAY"
		fi
		if [ -n "$XAUTHORITY" ]; then
			args --ro-bind "$XAUTHORITY" /home/.Xauthority \
				 --setenv XAUTHORITY /home/.Xauthority
		fi

		if [ -z "$ENABLE_DBUS" ]; then
			args --unsetenv DBUS_SESSION_BUS_ADDRESS
		else
			args --bind-try "$runtime_dir"/bus "$runtime_dir"/bus \
				 --bind-try /run/dbus /run/dbus \
				 --setenv DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS"
		fi
    fi

	if [ -z "$DISABLE_NET" ]; then
		args --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
		     --ro-bind-try /etc/hosts /etc/hosts
	else
		args --unshare-net
	fi

	# Source environment variables from within bootstrap
	bwrap --ro-bind "$mount_point" / --dev-bind /dev /dev \
		  /bin/env -i /bin/bash -c 'source /etc/profile; env' \
		  | while read -r line; do
		key="$(echo "$line" | cut -d= -f1)"
		value="$(echo "$line" | cut -d= -f2-)"
		case "$key" in
			PWD|SHLVL|_) ;;
			PATH)
				if [ -z "$SANDBOX" ]; then
					args --setenv PATH "$value:$PATH"
				else
					args --setenv PATH "$value"
				fi
				;;
			*) args --setenv "$key" "$value" ;;
		esac
	done

	# This is set by run_util so need to set it to system value explicitly
	if [ -n "$LD_LIBRARY_PATH" ]; then
		args --setenv LD_LIBRARY_PATH "$LD_LIBRARY_PATH"
	else
		args --unsetenv LD_LIBRARY_PATH
	fi
	if [ -n "$LC_ALL_ORIG" ]; then
		args --setenv LC_ALL "$LC_ALL_ORIG"
	else
		args --unsetenv LC_ALL
	fi

	# shellcheck disable=2086
	unset $conty_variables
	exec 3< "$args_file"
	run_util bwrap --args 3 "$@"
	exec 3>&-
	rm "$args_file"
}

show_help() {
	cat <<EOF
$conty_name $script_version

Usage: $conty_name [OPTION]... COMMAND

Sandboxing:
  -n    Disable network access.
  -s    Enable a sandbox which, by default does following things:
        - Hides user & system files by mounting everything as tmpfs.
        - Mounts X11 socket pointed to by \$DISPLAY environment variable and
          Xauthority file pointed by \$XAUTHORITY environment variable if they
          are set.
        - Mounts wayland socket pointed to by \$WAYLAND_DISPLAY environment
          variable if it is set.
        - Clears environment variables.
        You can make sandbox less or more strict by using some arguments below
        or by passing any arguents supported by bubblewrap.
  -d    Allow dbus access when sandbox is enabled.
  -e    Do not clear environment variables when sandbox is enabled.
  -p    Persist home directory when sandbox is enabled.
        By default home is persisted at $persist_home_dir.
        You can customize it by setting \$HOME_DIR environment variable.

Rebuild:
  -u    Rebuild conty container and exit.
        This will copy files used to build conty that are included in the image
        into build directory and produce new conty executable using them. Build
        settings, if needed can be customized by creating
        ~/.config/conty/settings.sh file which will replace setings file from
        the image.
        Rebuild command uses host system utilities to work and will error out
        if some of them are not available with list of required dependencies.
  -c    Remove rebuild directory if rebuild was finished successfully

Miscellaneous:
  -m    Mount/unmount the image
        The image will be mounted if it's not, unmounted otherwise.
  -h    Display this help message and exit.
  -H    Display bubblewrap help and exit.
  -V    Display version of the image and exit.
  --    Treat the rest of arguments as COMMAND.

COMMAND is passed directly to bubblewrap, so all bubblewrap arguments are
supported.

Environment variables:
  DISABLE_NET       Same as providing -n flag.
  SANDBOX           Same as providing -s flag.
  ENABLE_DBUS       Same as providing -d flag.
  KEEP_ENV          Same as providing -e flag.
  PERSIST_HOME      Same as providing -p flag.
  REBUILD_CLEAR     Same as providing -c flag.
  HOME_DIR          Sets the directory where home directory will be persisted
                    when sandbox is enabled and -p flag is provided.
  BUILD_DIR         Sets the directory where conty rebuild will be done.
                    Can be either relative or full path.
                    Note that currently setting this path to tmpfs will break
                    rebuild if there are any AUR packages set to be installed
                    in settings.
  USE_SYS_UTILS     Tells the script to use squashfuse/dwarfs and bwrap
                    installed on the system instead of the builtin ones.
  CUSTOM_MNT        Sets a custom mount point for the Conty. This allows
                    Conty to be used with already mounted filesystems.
                    Conty will not mount its image on this mount point,
                    but it will use files that are already present
                    there.

If the executed script is a symlink with a different name, said name
will be used as the command name.
For instance, if the script is a symlink with the name \"wine\" it will
automatically run wine during launch.
EOF
}

mount_image() {
	[ -n "$CUSTOM_MNT" ] && cleanup_done=1 && return
	mountpoint "$mount_point" >/dev/null 2>&1 && return
	mkdir -p "$mount_point"

	if [ "$dwarfs_image" = 1 ]; then
		# Set the dwarfs block cache size depending on how much RAM is available
		# Also set the number of workers depending on the number of CPU cores
		local cachesize workers memory_size
		workers="$(nproc)"
		[ "$workers" -ge 8 ] && workers=8
		memory_size="$(free -m | grep '^Mem:' | awk '{print $2}')"
		if [ "$memory_size" -ge 45000 ]; then
			cachesize="4096M"
		elif [ "$memory_size" -ge 23000 ]; then
			cachesize="2048M"
		elif [ "$memory_size" -ge 15000 ]; then
			cachesize="1024M"
		elif [ "$memory_size" -ge 7000 ]; then
			cachesize="512M"
		elif [ "$memory_size" -ge 3000 ]; then
			cachesize="256M"
		elif [ "$memory_size" -ge 1500 ]; then
			cachesize="128M"
		else
			cachesize="64M"
		fi

		run_util dwarfs "$conty" "$mount_point" \
				 -o offset="$image_offset" \
				 -o debuglevel=error \
				 -o workers="$workers" \
				 -o mlock=try \
				 -o no_cache_image \
				 -o cache_files \
				 -o cachesize="$cachesize" \
				 -o decratio=0.6 \
				 -o tidy_strategy=swap \
				 -o tidy_interval=5m
		return "$?"
	else
		run_util squashfuse -o offset="$image_offset",ro "$conty" "$mount_point"
		return "$?"
	fi
}

rebuild() {
	local BUILD_DIR
	BUILD_DIR="${BUILD_DIR:-$(pwd)/conty_build}"
	mkdir -p "$BUILD_DIR"
	if [ -f "$conty_config_home"/settings.sh ]; then
		cp "$conty_config_home"/settings.sh "$BUILD_DIR"/settings_override.sh
	fi
	BUILD_DIR="$BUILD_DIR" "$mount_point"/opt/conty/create-conty.sh
	mv "$BUILD_DIR"/conty.sh "$(pwd)"
	if [ -n "$REBUILD_CLEAR" ]; then
		unshare --user --map-auto --map-root-user rm -rf "$BUILD_DIR"
	fi
}

cleanup_done=
cleanup() {
	[ -n "$cleanup_done" ] && return
	fusermount"$fuse_version" -uz "$mount_point" 2>/dev/null || \
		umount --lazy "$mount_point" 2>/dev/null

    if [ -z "$(ls "$mount_point" 2>/dev/null)" ]; then
        rm -rf "$mount_point"
    fi
	cleanup_done=1
}
trap 'cleanup &' EXIT

cmd='run_bwrap'
if [ "$conty_name" != "$script_name" ]; then
	set -- -- "$script_name" "$@"
elif [ "$#" -eq 0 ]; then
	show_help
	exit 1
else
	while getopts 'nsdepucmhHV-' opt; do
		case "$opt" in
			n) DISABLE_NET=1;;
			s) SANDBOX=1;;
			d) ENABLE_DBUS=1;;
			e) KEEP_ENV=1;;
			p) PERSIST_HOME=1;;
			u) cmd='rebuild' ;;
			c) REBUILD_CLEAR=1 ;;
			m) mount_image; cleanup_done=1; exit ;;
			h) show_help; exit ;;
			H) exec bwrap --help ;;
			V) set -- -- cat "$mount_point"/version; break ;;
			# Handling '-' is redundant, but let's be explicit
			-|*) break ;;
		esac
	done
	shift $((OPTIND-1))
fi

mount_image
"$cmd" "$@"
cleanup
