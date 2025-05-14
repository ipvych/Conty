#!/bin/sh
# shellcheck disable=3043 # local keyword is supported by busybox sh

LD_PRELOAD_ORIG="$LD_PRELOAD"
LD_LIBRARY_PATH_ORIG="$LD_LIBRARY_PATH"
unset LD_PRELOAD LD_LIBRARY_PATH

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

# Full path to the script
if [ -n "${BASH_SOURCE[0]}" ]; then
	script_literal="${BASH_SOURCE[0]}"
else
	script_literal="${0}"

	if [ "${script_literal}" = "$(basename "${script_literal}")" ]; then
		script_literal="$(command -v "${0}")"
	fi
fi
script_name="$(basename "$script_literal")"
script="$(readlink -f "$script_literal")"
script_id="$$"
# MD5 of the first 4 MB and the last 1 MB of the script
script_md5="$(head -c 4000000 "$script" | md5sum | head -c 7)"_"$(tail -c 1000000 "$script" | md5sum | head -c 7)"
conty_home="${XDG_DATA_HOME:-$HOME/.local/share}/conty"
image="$conty_home/content/image"
working_dir="$conty_home/run_$script_md5"
mkdir -p "$working_dir"

conty_variables='DISABLE_NET DISABLE_X11 HOME_DIR QUIET_MODE SANDBOX SANDBOX_LEVEL USE_SYS_UTILS XEPHYR_SIZE CUSTOM_MNT'

# Detect if the image is compressed with DwarFS or SquashFS
[ "$(head -c 6 "$image")" = "DWARFS" ] && dwarfs_image=1
mount_point="${CUSTOM_MNT:-$working_dir/mnt}"

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
		bwrap_path="$bwrap_path:$PATH"
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

	if [ -n "$DISABLE_X11" ]; then
		args --unsetenv "DISPLAY" --unsetenv "XAUTHORITY"
	else
		args --tmpfs /tmp/.X11-unix
		if [ "$SANDBOX_LEVEL" -ge 3 ]; then
			args --ro-bind-try /tmp/.X11-unix/X"$xephyr_display" /tmp/.X11-unix/X"$xephyr_display" \
				 --setenv "DISPLAY" :"$xephyr_display"
		else
			local XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"
			if [ -n "$XAUTHORITY" ]; then
				args --ro-bind-try "$XAUTHORITY" "$XAUTHORITY"
			fi

			for s in find /tmp/.X11-unix; do
				args --bind-try "$s" "$s"
			done
		fi
	fi

	for v in $conty_variables; do
		args --unsetenv "$v"
	done
	[ -n "$LD_PRELOAD_ORIG" ] && args --setenv LD_PRELOAD "$LD_PRELOAD_ORIG"
	[ -n "$LD_LIBRARY_PATH_ORIG" ] && args --setenv LD_LIBRARY_PATH "$LD_LIBRARY_PATH_ORIG"
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

run_xephyr() {
	XEPHYR_SIZE="${XEPHYR_SIZE:-800x600}"
	local xephyr_display="$((script_id+2))"

	if [ -S /tmp/.X11-unix/X"$xephyr_display" ]; then
		xephyr_display="$((script_id+10))"
	fi

	QUIET_MODE=1 DISABLE_NET=1 SANDBOX_LEVEL=2 run_bwrap \
				 --bind-try /tmp/.X11-unix /tmp/.X11-unix \
				 Xephyr -noreset -ac -br -screen "$XEPHYR_SIZE" :"$xephyr_display" 1>/dev/null 2>&1 &
	echo "$!"
	QUIET_MODE=1 run_bwrap openbox &
}

cmd_help() {
	echo "Usage: $script_name [COMMAND] [ARGUMENTS]


Arguments:
  -e    Extract the image

  -h    Display this text

  -H    Display bubblewrap help

  -l    Show a list of all installed packages

  -d    Export desktop files from Conty into the application menu of
        your desktop environment.
        Note that not all applications have desktop files, and also that
        desktop files are tied to the current location of Conty, so if
        you move or rename it, you will need to re-export them.
        To remove the exported files, use this argument again.

  -m    Mount/unmount the image
        The image will be mounted if it's not, unmounted otherwise.

  -v    Display version of this script

  -V    Display version of the image

  --    Treat the rest of arguments as arguments to bubblewrap

Arguments that don't match any of the above will be passed directly to
bubblewrap, so all bubblewrap arguments are supported as well.

Environment variables:
  DISABLE_NET       Disables network access.

  DISABLE_X11       Disables access to X server.

                    Note: Even with this variable enabled applications
                    can still access your X server if it doesn't use
                    XAUTHORITY and listens to the abstract socket. This
                    can be solved by enabling XAUTHORITY, disabling the
                    abstract socket or by disabling network access.

  HOME_DIR          Sets the home directory to a custom location.
                    For example: HOME_DIR=\"$HOME/custom_home\"
                    Note: If this variable is set the home directory
                    inside the container will still appear as $HOME,
                    even though the custom directory is used.

  QUIET_MODE        Disables all non-error Conty messages.
                    Doesn't affect the output of applications.

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
                      3: Additionally disables network access and
                         isolates X11 server with Xephyr.
                    The default is 1.

  USE_SYS_UTILS     Tells the script to use squashfuse/dwarfs and bwrap
                    installed on the system instead of the builtin ones.

  XEPHYR_SIZE       Sets the size of the Xephyr window. The default is
                    800x600.

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
automatically run wine during launch."
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

		dwarfs "$image" "$mount_point" \
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
		squashfuse -o ro "$image" "$mount_point"
		return "$?"
	fi
}

cmd_show_image_version() {
	cmd_mount_image
	cat "$mount_point"/version
}

cmd_export_desktop_files() {
	cmd_mount_image
	local applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications/Conty"

	if [ -d "$applications_dir" ]; then
		rm -rf "$applications_dir"
		echo "Desktop files have been removed"
		return
	fi
	mkdir -p "$applications_dir"
	local mount_application_dir="$mount_point"/usr/share/applications
	local value variables
	for v in $conty_variables; do
		value="$(env | grep "$v" | cut -d= -f2)"
		if [ -n "${value}" ]; then
			variables="$v='$value' $variables"
		fi
	done

	if [ -n "$variables" ]; then
		variables="/usr/bin/env $variables "
	fi

	echo "Exporting..."
	for f in find "$mount_application_dir" -type f -name '*.desktop'; do
		while read -r line; do
			local key value
			key="$(echo "$line" | cut -d= -f1)"
			value="$(echo "$line" | tail -d= -f2-)"
			if [ "$key" = "Name" ]; then
				echo "Name=$value (Conty)"
			elif [ "$key" = "Exec" ]; then
				echo "Exec=${variables}\"${script}\" $value"
			fi
		done < "$f" > "$applications_dir"/"${f%.desktop}"-conty.desktop
	done

	echo "Desktop files have been exported"
}

cmd_list_packages() {
	cmd_mount_image
	run_bwrap --ro-bind "$mount_point"/var /var pacman -Q
}

cmd_extract_image() {
	files_dir="$(basename "$script")_files"
	echo "Extracting to $files_dir..."
	mkdir "$files_dir"

	if [ "$dwarfs_image" = 1 ]; then
		exec dwarfsextract -i "$image" -o "$(basename "$script")"_files
	else
		exec unsquashfs -user-xattrs -d "$(basename "$script")"_files "$image"
	fi
}

cmd_run() {
	cmd_mount_image
	if [ "$SANDBOX" = 1 ] && [ "$SANDBOX_LEVEL" -ge 3 ]; then
		xephyr_pid="$(run_xephyr)"
	fi
	run_bwrap "$@"
	[ -n "$xephyr_pid" ] && wait "$xephyr_pid"
}

cleanup_done=
cleanup() {
	[ -n "$cleanup_done" ] && return
	fusermount"$fuse_version" -uz "$mount_point" 2>/dev/null || \
		umount --lazy "$mount_point" 2>/dev/null

    if [ -z "$(ls "$mount_point" 2>/dev/null)" ]; then
        rm -rf "$working_dir"
    fi
	cleanup_done=1
}
trap 'cleanup &' EXIT

command='run'
case "$1" in
	-l) command='list_packages'; shift;;
	-d) command='export_desktop_files'; shift;;
	-m) command='mount_image'; cleanup_done=1; shift;;
	-e) command='extract_image'; shift;;
	-V) command='show_image_version'; shift;;
    -h|'') command='help'; shift;;
	-H) exec bwrap --help;;
	-v) exec echo "$script_version";;
    --|*) ;;
esac

if [ -L "$script_literal" ]; then
	cmd_run "$script_name" "$@"
else
	cmd_"$command" "$@"
fi

cleanup
