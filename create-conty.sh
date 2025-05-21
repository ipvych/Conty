#!/usr/bin/env bash

set -e

stage() {
	if [ "$NESTING_LEVEL" -gt 0 ]; then
		printf '\033[1;34m:%.0s\033[0m' $(seq "$NESTING_LEVEL")
	fi
	printf '\033[1m>'; printf ' %s' "$@"; printf '\033[0m\n'
}
info() { NESTING_LEVEL=$((NESTING_LEVEL + 1)) stage "$@"; }

check_command_available() {
	declare -a found_exe missing_exe
	mapfile -t found_exe < <(command -v "$@")
	if [ "${#found_exe[@]}" -ne "$#" ]; then
		mapfile -t missing_exe < <(comm -23 \
										<(printf '%s\n' "$@" | sort -u) \
										<(printf '%s\n' "${found_exe[@]##*/}" | sort -u))
		info "Following commands are required:" "${missing_exe[@]}"
		exit 1
	fi
}

# Script is reexecuted from within chroot with INSIDE_BOOTSTRAP set to perform bootstrap
if [ -z "$INSIDE_BOOTSTRAP" ]; then
	check_command_available cp mv rm tr comm mkdir mount tar sha256sum chroot curl unshare
	source settings.sh
	NESTING_LEVEL=0

	stage "Preparing bootstrap"
	BUILD_DIR="${BUILD_DIR:-build}"
	build_dir="$(realpath "$BUILD_DIR")"
	bootstrap="$build_dir"/root.x86_64
	conty_files='init.c create-conty.sh conty-start.sh settings.sh'
	mkdir -p "$build_dir"
	# shellcheck disable=2086 # Using normal variable because arrays cannot be exported
	cp $conty_files "$build_dir"
	if [ -f "$build_dir"/settings_override.sh ]; then
	   mv "$build_dir"/settings_override.sh "$build_dir"/settings.sh
	fi
	cd "$build_dir"

	info "Downloading Arch Linux bootstrap sha256sum from $BOOTSTRAP_SHA256SUM_FILE_URL"
	curl -LO "$BOOTSTRAP_SHA256SUM_FILE_URL"
	info "Verifying integrity of existing bootstrap archive if it exists"
	if ! sha256sum --ignore-missing -c sha256sums.txt &>/dev/null; then
		for link in "${BOOTSTRAP_DOWNLOAD_URLS[@]}"; do
			info "Downloading Arch Linux archive bootstrap from $link"
			curl -LO "$link"

			info "Verifying the integrity of the bootstrap archive"
			if sha256sum --ignore-missing -c sha256sums.txt &>/dev/null; then
				bootstrap_is_good=1
				break 1
			fi
			info "Download failed, trying again with different mirror"
		done
		if [ -z "$bootstrap_is_good" ]; then
			info "Bootstrap download failed or its checksum is incorrect"
			exit 1
		fi
	fi

	run_unshared() {
		unshare --uts --ipc --user --mount --map-auto --map-root-user --pid --fork -- "$@"
	}

	if [ ! -d "$bootstrap" ] || [ -n "$ALWAYS_EXTRACT_BOOTSTRAP" ]; then
		info "Removing previous bootstrap"
		run_unshared rm -rf "$bootstrap"
		info "Extracting bootstrap from archive"
		run_unshared tar xf archlinux-bootstrap-x86_64.tar.zst
	fi

	# shellcheck disable=2317
	prepare_bootstrap() {
		set -e
		mount --bind "$bootstrap"/ "$bootstrap"/
		mount -t proc proc "$bootstrap"/proc
		mount -o ro --rbind /dev "$bootstrap"/dev
		mount none -t devpts "$bootstrap"/dev/pts
		mount none -t tmpfs "$bootstrap"/dev/shm
		mount --bind /etc/resolv.conf "$bootstrap"/etc/resolv.conf
		if [ -d /var/cache/pacman/pkg ]; then
			mkdir -p "$bootstrap"/var/cache/pacman/host_pkg
			mount -o ro --bind /var/cache/pacman/pkg "$bootstrap"/var/cache/pacman/host_pkg
		fi
		# Default machine-id is unitialized and systemd-tmpfiles throws some warnings
		# about it so initialize it to a value here
		rm -r "$bootstrap"/etc/machine-id
		tr -d '-' < /proc/sys/kernel/random/uuid \
			| install -Dm0444 /dev/fd/0 "$bootstrap"/etc/machine-id
		mkdir -p "$bootstrap"/opt/conty
		# shellcheck disable=2086
		cp $conty_files "$bootstrap"/opt/conty
	}
	# shellcheck disable=2317
	run_bootstrap() {
		exec chroot "$bootstrap" /usr/bin/env -i \
			   USER='root' HOME='/root' NESTING_LEVEL=2 INSIDE_BOOTSTRAP=1 \
			   /opt/conty/create-conty.sh
	}

	export bootstrap conty_files
	export -f prepare_bootstrap run_bootstrap
	info "Entering bootstrap namespace"
	if ! run_unshared bash -c "prepare_bootstrap && run_bootstrap"; then
		info "Error occured while building bootstrap"
		exit 1
	fi

	info "Bootstrap finished successfully"
	run_util() {
		if [ -z "$USE_SYS_UTILS" ]; then
			set -- env PATH="$bootstrap/bin:$PATH" LD_PRELOAD_PATH="$bootstrap/lib" "$@"
		fi
		"$@"
	}

	stage "Building image from bootstrap"
	image_path="$build_dir"/image
	if [ ! -f "$image_path" ] || [ -z "$USE_EXISTING_IMAGE" ]; then
		rm -f "$image_path"
		stage "Compressing image"
		if [ -n "$USE_DWARFS" ]; then
			run_util mkdwarfs -i "$bootstrap" -o "$image_path" "${DWARFS_COMPRESSOR_ARGUMENTS[@]}"
		else
			run_util mksquashfs "$bootstrap" "$image_path" "${SQUASHFS_COMPRESSOR_ARGUMENTS[@]}"
		fi
	fi

	stage "Creating conty"
	init="$bootstrap"/opt/conty/init
	conty="$build_dir"/conty.sh
	cat "$init" "$image_path" > "$conty"
	chmod +x "$conty"
	stage "Conty created and is ready to use at $conty!"
	exit
fi

# From here on we are running inside bootstrap
# Populate PATH and LANG environment variables with defaults
source /etc/profile

# shellcheck source=settings.sh
source /opt/conty/settings.sh

install_aur_packages() {
	useradd -r -m aurbuilder || true
	echo 'aurbuilder ALL=(ALL) NOPASSWD: /usr/bin/pacman' \
		| install -Dm0440 /dev/fd/0 /etc/sudoers.d/aurbuilder

	pushd /home/aurbuilder &>/dev/null
	if ! pacman -Q yay-bin &>/dev/null; then
		if [ -n "$ENABLE_CHAOTIC_AUR" ]; then
			info "Installing base-devel and yay"
			pacman --noconfirm --needed -S base-devel yay
		else
			info "Installing base-devel"
			pacman --noconfirm --needed -S base-devel
			info "Building yay-bin"
			sudo -u aurbuilder -- curl -LO 'https://aur.archlinux.org/cgit/aur.git/snapshot/yay-bin.tar.gz'
			sudo -u aurbuilder -- tar -xf yay-bin.tar.gz
			pushd yay-bin &>/dev/null
			sudo -u aurbuilder -- makepkg --noconfirm -sri
			popd &>/dev/null
		fi
	fi
	for p in "$@"; do
		info "Building and installing $p"
		sudo -u aurbuilder -- yay --needed --removemake --noconfirm -S "$p"
	done

	info "Cleaning up"
	popd &>/dev/null
	# GPG leaves hanging processes when package with signing keys is installed
	pkill -SIGKILL -u aurbuilder || true
	userdel -r aurbuilder &>/dev/null
	rm /etc/sudoers.d/aurbuilder
}

stage "Generating locales"
printf '%s\n' "${LOCALES[@]}" > /etc/locale.gen
locale-gen

stage "Setting up default mirrorlist"
printf 'Server = %s\n' "${DEFAULT_MIRRORS[@]}" > /etc/pacman.d/mirrorlist

stage "Setting up pacman config"
if [ "${#AUR_PACKAGES[@]}" -ne 0 ]; then
	info "Disabling debug option in makepkg"
	sed -i 's/\(OPTIONS=(.*\)\(debug.*)\)/\1!\2/' /etc/makepkg.conf
fi
info "Enabling fetch of packages from host pacman cache"
sed -i 's!#CacheDir.*!CacheDir = /var/cache/pacman/pkg /var/cache/pacman/host_pkg!' /etc/pacman.conf
info "Disabling extraction of nvidia firmware and man pages"
sed -i 's!#NoExtract.*!NoExtract = usr/lib/firmware/nvidia/\* usr/share/man/\*!' /etc/pacman.conf
info "Making pacman read drop-in configuration from /etc/pacman.conf.d"
mkdir -p /etc/pacman.conf.d
grep -q 'Include = /etc/pacman.conf.d/\*.conf' /etc/pacman.conf || \
	echo 'Include = /etc/pacman.conf.d/*.conf' >> /etc/pacman.conf
# pacman complains when glob does not match anything
touch /etc/pacman.conf.d/empty.conf
info "Enabling multilib repository"
echo '
[multilib]
Include = /etc/pacman.d/mirrorlist' > /etc/pacman.conf.d/10-multilib.conf
pacman --noconfirm -Sy

stage "Setting up pacman keyring"
pacman-key --init
pacman-key --populate archlinux
pacman --noconfirm -Sy archlinux-keyring

if [ -n "$ENABLE_CHAOTIC_AUR" ]; then
	stage "Setting up Chaotic-AUR"
	chaotic_aur_key='3056513887B78AEB'
	pacman-key --recv-key "$chaotic_aur_key" --keyserver keyserver.ubuntu.com
	pacman-key --lsign-key "$chaotic_aur_key"
	pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
	echo '[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist' > /etc/pacman.conf.d/99-chaotic-aur.conf
	pacman --noconfirm -Sy
fi

if [ -n "$ENABLE_ALHP_REPO" ]; then
	stage "Setting up ALHP"
	if [ -n "$ENABLE_CHAOTIC_AUR" ]; then
		pacman --noconfirm --needed -Sy alhp-keyring alhp-mirrorlist
	else
		install_aur_packages alhp-keyring alhp-mirrorlist
	fi
	rm -f /etc/pacman.conf.d/10-multilib.conf
	sed -i "/\[core\]/,/Include/"' s/^/#/' /etc/pacman.conf
	sed -i "/\[extra\]/,/Include/"' s/^/#/' /etc/pacman.conf
	echo "[core-x86-64-v$ALHP_FEATURE_LEVEL]
Include = /etc/pacman.d/alhp-mirrorlist
[core]
Include = /etc/pacman.d/mirrorlist

[extra-x86-64-v$ALHP_FEATURE_LEVEL]
Include = /etc/pacman.d/alhp-mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist

[multilib-x86-64-v$ALHP_FEATURE_LEVEL]
Include = /etc/pacman.d/alhp-mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist" > /etc/pacman.conf.d/00-alhp.conf
	pacman --noconfirm -Sy
fi

stage "Upgrading base system"
pacman --noconfirm -Syu

stage "Installing base packages"
pacman --noconfirm --needed -S squashfs-tools

if [ -n "$USE_REFLECTOR" ]; then
	stage "Generating mirrorlist using reflector"
	info "Installing reflector"
	pacman --noconfirm --needed -S reflector
	info "Generating mirrorlist"
	reflector "${REFLECTOR_ARGS[@]}" --save /etc/pacman.d/mirrorlist
	info "Cleaning up"
	pacman --noconfirm -Rsu reflector
fi

if [ "${#PACKAGES[@]}" -ne 0 ]; then
	stage "Installing packages defined in settings.sh"
	info "Checking if packages are present in the repos"
	declare -a missing_packages
	mapfile -t missing_packages < <(comm -23 \
										 <(printf '%s\n' "${PACKAGES[@]}" | sort -u) \
										 <(pacman -Slq | sort -u))
	if [ "${#missing_packages[@]}" -ne 0 ]; then
		info "Following packages are not available in repository:" "${missing_packages[@]}"
		exit 1
	fi
	for _ in {1..10}; do
		pacman --noconfirm --needed -S "${PACKAGES[@]}"
		exit_code="$?"
		[ "$exit_code" -eq 0 ] && break
		# Received interrupt signal
		[ "$exit_code" -gt 128 ] && exit "$exit_code"
	done
fi

if [ "${#AUR_PACKAGES[@]}" -ne 0 ]; then
	stage "Installing AUR packages defined in settings.sh"
	info "Checking if packages are present in AUR"
	declare -a missing_packages
	mapfile -t missing_packages < <(comm -23 \
										 <(printf '%s\n' "${AUR_PACKAGES[@]}" | sort -u) \
										 <(curl -s 'https://aur.archlinux.org/packages.gz' \
											   | gunzip | sort -u))
	if [ "${#missing_packages[@]}" -ne 0 ]; then
		info "Following packages are not available in AUR:" "${missing_packages[@]}"
		exit 1
	fi
	install_aur_packages "${AUR_PACKAGES[@]}"
fi

# NOTE 2025-05-08: It should be possible to create PKGBUILD to build all these
# statically linked from source which will improve portability and potentially
# reduce binary size but for now just bundling things together this way works.
# When it is needed refer to create-utils.sh script for some pointers on how
# they can be built
ldd_tree() {
	declare -A processed
	declare -a libs tail
	local cur="$1"
	while :; do
		mapfile -t libs < <(ldd "$cur" 2>/dev/null | awk '{print $3}' | grep -v '^$')
		for lib in "${libs[@]}"; do
			if [ ! -f "$lib" ] || [[ -v ${processed[$lib]} ]]; then
				continue
			fi
			processed["$lib"]=0
			echo "$lib"
			tail+=("$cur")
			cur="$lib"
			continue 2
		done
		if [ "${#tail[@]}" -gt 0 ]; then
			cur="${tail[-1]}"
			unset 'tail[-1]'
			continue
		fi
		break
	done
}

stage "Creating init script"
packages=(busybox bubblewrap squashfuse squashfs-tools musl gcc)
[ -n "$USE_DWARFS" ] && packages+=(dwarfs)
declare -a needed_packages
mapfile -t needed_packages < <(comm -23 \
									<(printf '%s\n' "${packages[@]}" | sort -u) \
									<(pacman -Qq | sort -u))
info "Installing required packages"
if [ -z "$ENABLE_CHAOTIC_AUR" ]; then
	[ -n "$USE_DWARFS" ] && install_aur_packages dwarfs
fi
if [ "${#needed_packages}" -ne 0 ]; then
	pacman --needed --noconfirm -S "${needed_packages[@]}"
fi

executables=(bwrap squashfuse mksquashfs)
[ -n "$USE_DWARFS" ] && executables+=(dwarfs mkdwarfs)
mkdir -p /opt/conty/utils/bin
for e in "${executables[@]}"; do
	cp -L "$(command -v "$e")" /opt/conty/utils/bin
done

mkdir -p /opt/conty/utils/lib
for e in "${executables[@]}"; do
	ldd_tree "$(command -v "$e")";
done | sort -u | xargs -I{} cp {} /opt/conty/utils/lib

info "Creating archive with utilities"
utils='/opt/conty/utils.tar.xz'
busybox tar c -J -f "$utils" -C /opt/conty/utils .

info "Creating init program"
busybox="$(command -v busybox)"
script='/opt/conty/conty-start.sh'

init_size=0
busybox_size="$(stat -c%s "$busybox")"
utils_size="$(stat -c%s "$utils")"
script_size="$(stat -c%s "$script")"

init_out='/opt/conty/init_out'
while :; do
	musl-gcc -static -Oz \
			 -D PROGRAM_SIZE="$init_size" \
			 -D BUSYBOX_SIZE="$busybox_size" \
			 -D SCRIPT_SIZE="$script_size" \
			 -D UTILS_SIZE="$utils_size" \
			 -o "$init_out" /opt/conty/init.c
	strip -s "$init_out"
	[ "$init_size" -eq "$(stat -c%s "$init_out")" ] && break
	init_size="$(stat -c%s "$init_out")"
done
cat "$init_out" "$busybox" "$script" "$utils" > /opt/conty/init
rm "$init_out"

info "Removing unneeded packages & files"
rm -r /opt/conty/utils "$utils"
# if [ "${#needed_packages[@]}" -ne 0 ]; then
# 	pacman --noconfirm -Rsu "${needed_packages[@]}"
# fi

stage "Clearing pacman cache"
rm -rf /var/cache/pacman/pkg

stage "Enabling font hinting"
mkdir -p /etc/fonts/conf.d
rm -f /etc/fonts/conf.d/10-hinting-slight.conf
ln -sf /usr/share/fontconfig/conf.avail/10-hinting-full.conf /etc/fonts/conf.d

stage "Creating files and directories for application compatibility"
# Create some empty files and directories
# This is needed for bubblewrap to be able to bind real files/dirs to them
# later in the conty-start.sh script
mkdir -p /media /initrd
touch /etc/asound.conf
touch /etc/localtime

stage "Generating install info"
info "Writing list of all installed packages to /pkglist.x86_64.txt"
pacman -Q > /pkglist.x86_64.txt
info "Writing list of licenses for installed packages to /pkglicenses.txt"
pacman -Qi | grep -E '^Name|Licenses' | cut -d ":" -f 2 | paste -d ' ' - - > /pkglicenses.txt
info "Writing build date to /version"
date -u +"%d-%m-%Y %H:%M (DMY UTC)" > /version
