#!/bin/sh
# shellcheck disable=3043 # local keyword is supported by busybox sh

# NOTE 2025-05-16: Busybox sh as provided in arch repository runs bundled
# utilities without $PATH search which this script relies on

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

# Full path to conty is provided as first argument by init
conty="$1"; shift
script="$0"
conty_name="$(basename "$conty")"
script_name="$(basename "$script")"
program_size="$CONTY_PROGRAM_SIZE"; unset CONTY_PROGRAM_SIZE
busybox_size="$CONTY_BUSYBOX_SIZE"; unset CONTY_BUSYBOX_SIZE
script_size="$CONTY_SCRIPT_SIZE"; unset CONTY_SCRIPT_SIZE
utils_size="$CONTY_UTILS_SIZE"; unset CONTY_UTILS_SIZE
utils_offset=$((program_size + busybox_size + script_size))
image_offset=$((utils_offset + utils_size))

conty_home="${XDG_DATA_HOME:-$HOME/.local/share}/conty"
conty_variables='DISABLE_NET HOME_DIR QUIET_MODE SANDBOX SANDBOX_LEVEL USE_SYS_UTILS CUSTOM_MNT'

if [ -z "$USE_SYS_UTILS" ]; then
	utils_dir="$conty_home/utils"
	if [ ! -d "$utils_dir" ]; then
		mkdir -p "$utils_dir"
		tail -c +"$((utils_offset + 1))" "$conty" | head -c "$utils_size" \
			| tar x -J -C "$utils_dir"
	fi

	LD_LIBRARY_PATH_ORIG="$LD_LIBRARY_PATH"
	PATH_ORIG="$PATH"
	export PATH="$utils_dir/bin:$PATH" LD_LIBRARY_PATH="$utils_dir/lib"
	unset utils_dir
fi

# MD5 of the first 4 MB and the last 1 MB of the conty
script_md5="$(head -c 4000000 "$conty" | md5sum | head -c 7)"_"$(tail -c 1000000 "$conty" | md5sum | head -c 7)"
mount_point="${CUSTOM_MNT:-$conty_home/mnt_$script_md5}"
if [ "$(tail -c +"$((image_offset + 1))" "$conty" | head -c 6)" = "DWARFS" ]; then
	 dwarfs_image=1
fi

# Check if FUSE is installed
if ! command -v fusermount3 1>/dev/null && ! command -v fusermount 1>/dev/null; then
	echo "Please install fuse2 or fuse3 and run the script again."
	exit 1
fi

if command -v fusermount3 1>/dev/null; then
	fuse_version=3
fi

run_bwrap () {
	local XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
	local wayland_socket="$XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-wayland-0}"
    local bwrap_path="/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/lib/jvm/default/bin"
	local SANDBOX_LEVEL="${SANDBOX_LEVEL:-0}"
	local args_file
	args_file="$(mktemp)"
	args() {
		printf -- '%s\0' "$@" >> "$args_file"
	}

	if [ -n "$RW_ROOT"  ]; then
		args --bind "$mount_point" /
	else
		args --ro-bind "$mount_point" /
	fi

	args --dev-bind /dev /dev \
		 --ro-bind /sys /sys \
         --proc /proc \
         --ro-bind-try /etc/asound.conf /etc/asound.conf \
		 --ro-bind-try /etc/localtime /etc/localtime \
         --ro-bind-try /usr/share/steam/compatibilitytools.d /usr/share/steam/compatibilitytools.d \
		 --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
		 --ro-bind-try /etc/passwd /etc/passwd \
		 --ro-bind-try /etc/group /etc/group \
		 --ro-bind-try /etc/machine-id /etc/machine-id \
		 --setenv XDG_DATA_DIRS "/usr/local/share:/usr/share:$XDG_DATA_DIRS"

	if [ -z "$SANDBOX" ]; then
		if [ -n "$PATH_ORIG" ]; then
			bwrap_path="$bwrap_path:$PATH_ORIG"
		else
			bwrap_path="$bwrap_path:$PATH"
		fi
		args --bind-try /tmp /tmp \
			 --bind-try /home /home \
			 --bind-try /mnt /mnt \
			 --bind-try /initrd /initrd \
			 --bind-try /media /media \
			 --bind-try /run /run \
			 --bind-try /var /var \
			 --bind-try /opt /opt
    else
        args --tmpfs /home \
			 --tmpfs /mnt \
			 --tmpfs /initrd \
			 --tmpfs /media \
			 --tmpfs /var \
			 --tmpfs /run \
			 --symlink /run /var/run \
			 --tmpfs /tmp \
			 --new-session
        if [ "$SANDBOX_LEVEL" -ge 3 ]; then
            DISABLE_NET=1
        fi
        if [ "$SANDBOX_LEVEL" -ge 2 ]; then
            args --unshare-pid \
                 --unshare-user-try \
				 --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR" \
				 --ro-bind-try "$wayland_socket" "$wayland_socket" \
				 --ro-bind-try "$XDG_RUNTIME_DIR"/pulse "$XDG_RUNTIME_DIR"/pulse \
				 --ro-bind-try "$XDG_RUNTIME_DIR"/pipewire-0 "$XDG_RUNTIME_DIR"/pipewire-0 \
                 --unsetenv "DBUS_SESSION_BUS_ADDRESS"
        elif [ "$SANDBOX_LEVEL" -ge 1 ]; then
            args --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR" \
				 --bind-try "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" \
				 --bind-try /run/dbus /run/dbus
        fi
    fi

	if [ -n "$HOME_DIR" ]; then
		args --bind "$HOME_DIR" "$HOME"
	fi

	if [ -z "$DISABLE_NET" ]; then
		args --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
		     --ro-bind-try /etc/hosts /etc/hosts
	else
		args --unshare-net
	fi
	args --dir /tmp/.X11-unix
	args --bind-try /tmp/.X11-unix /tmp/.X11-unix
	if [ -n "$XAUTHORITY" ]; then
		args --ro-bind-try "$XAUTHORITY" "$XAUTHORITY"
	fi

	for v in $conty_variables; do
		args --unsetenv "$v"
	done
	if [ -n "$LD_LIBRARY_PATH_ORIG" ]; then
		args --setenv LD_LIBRARY_PATH "$LD_LIBRARY_PATH_ORIG"
	else
		args --unsetenv LD_LIBRARY_PATH
	fi
	if [ -n "$LC_ALL_ORIG" ]; then
		args --setenv LC_ALL "$LC_ALL_ORIG"
	else
		args --unsetenv LC_ALL
	fi
	args --setenv PATH "$bwrap_path"

	exec 3< "$args_file"
	bwrap --args 3 "$@"
	exec 3>&-
	rm "$args_file"
}

cmd_help() {
	cat <<EOF
$conty_name $script_version

Usage: $conty_name [ARGUMENTS] COMMAND

Arguments:
  -h    Display help and exit.
  -H    Display bubblewrap help and exit.
  -m    Mount/unmount the image
        The image will be mounted if it's not, unmounted otherwise.
  -V    Display version of the image and exit.
  --    Treat the rest of arguments as arguments to bubblewrap.

Arguments that don't match any of the above will be passed directly to
bubblewrap, so all bubblewrap arguments are supported as well.

Environment variables:
  DISABLE_NET       Disables network access.

  HOME_DIR          Sets the home directory to a custom location.
                    For example: HOME_DIR=\"$HOME/custom_home\"
                    Note: If this variable is set the home directory
                    inside the container will still appear as $HOME,
                    even though the custom directory is used.

  SANDBOX           Enables a sandbox.
                    To control which files and directories are available
                    inside the container, you can use the --bind and
                    --ro-bind launch arguments.
                    (See bubblewrap help for more info).

  SANDBOX_LEVEL     Controls the strictness of the sandbox.
                    Available levels:
                      1: Isolates all user files.
                      2: Additionally disables dbus and hides all
                         running processes.
                      3: Additionally disables network access.
                    The default is 1.

  USE_SYS_UTILS     Tells the script to use squashfuse/dwarfs and bwrap
                    installed on the system instead of the builtin ones.

  CUSTOM_MNT        Sets a custom mount point for the Conty. This allows
                    Conty to be used with already mounted filesystems.
                    Conty will not mount its image on this mount point,
                    but it will use files that are already present
                    there.

Additional notes:
System directories/files will not be available inside the container if
you set the SANDBOX variable but don't bind (mount) any items or set
HOME_DIR. A fake temporary home directory will be used instead.

If the executed script is a symlink with a different name, said name
will be used as the command name.
For instance, if the script is a symlink with the name \"wine\" it will
automatically run wine during launch.
EOF
}

cmd_mount_image() {
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

		dwarfs "$conty" "$mount_point" \
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
		squashfuse -o offset="$image_offset",ro "$conty" "$mount_point"
		return "$?"
	fi
}

cmd_show_image_version() {
	cmd_mount_image
	cat "$mount_point"/version
}

cmd_run() {
	cmd_mount_image
	run_bwrap "$@"
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

command='run'
case "$1" in
	-m) command='mount_image'; cleanup_done=1; shift;;
	-V) command='show_image_version'; shift;;
    -h|'') command='help'; shift;;
	-H) exec bwrap --help;;
    --|*) ;;
esac

if [ "$conty_name" != "$script_name" ]; then
	cmd_run "$script_name" "$@"
else
	cmd_"$command" "$@"
fi

cleanup
