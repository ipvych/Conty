#!/usr/bin/env bash
# shellcheck shell=bash disable=2034

# Packages to install
# You can add packages that you want and remove packages that you don't need
# Apart from packages from the official Arch repos, you can also specify
# packages from the Chaotic-AUR repo if you set ENABLE_CHAOTIC_AUR
PACKAGES=(
	# video
	lib32-mesa
	lib32-vulkan-radeon
	lib32-vulkan-intel
	vulkan-icd-loader lib32-vulkan-icd-loader
	lib32-vulkan-mesa-layers
	libva-intel-driver lib32-libva-intel-driver
	# wine & it's deps
	wine-staging winetricks wine-nine
	dosbox
	lib32-flex
	lib32-fluidsynth
	gst-libav lib32-gst-plugins-base lib32-gst-plugins-good gst-plugin-pipewire
	gst-plugins-ugly gst-plugins-bad
	gst-plugins-bad-libs
	lib32-libpng
	ocl-icd lib32-ocl-icd
	vkd3d lib32-vkd3d
	libgphoto2
	# lutris optional deps
	python-protobuf
	python-pefile
	xorg-xgamma
	umu-launcher
	innoextract
	gvfs
	vulkan-tools
	# gaming
	steam-native-runtime lutris
	# fonts
	ttf-dejavu ttf-liberation
	# tools
	nano pcmanfm gpicview featherpad lxterminal gamescope
	mesa-utils
)

# If you want to install AUR packages, specify them in this variable
AUR_PACKAGES=()

# Chaotic-AUR is a repository containing precompiled packages from AUR
# Set this variable to any value if you want to enable id
ENABLE_CHAOTIC_AUR=

# ALHP is a repository containing packages from the official Arch Linux
# repos recompiled with -O3, LTO and optimizations for modern CPUs for
# better performance
#
# When this repository is enabled, most of the packages from the official
# Arch Linux repos will be replaced with their optimized versions from ALHP
#
# Set this variable to any value if you want to enable this repository
ENABLE_ALHP_REPO=

# Feature levels for ALHP. Available feature levels are 2 and 3
# For level 2 you need a CPU with SSE4.2 instructions
# For level 3 you need a CPU with AVX2 instructions
ALHP_FEATURE_LEVEL=2

# Locales to configure in the image
LOCALES=(
	'en_US.UTF-8 UTF-8'
)

# Pacman mirrors to use before reflector is installed and used to fetch new one
# shellcheck disable=2016
DEFAULT_MIRRORS=(
	'https://geo.mirror.pkgbuild.com/$repo/os/$arch'
	'https://ftpmirror.infania.net/mirror/archlinux/$repo/os/$arch'
	'https://mirror.rackspace.com/archlinux/$repo/os/$arch'
)

# Set this to any value to use reflector when building bootstrap to fetch
# up to date mirrors. Reflector will be called with provided args and write
# mirrorlist to /etc/pacman.d/mirrorlist
USE_REFLECTOR=1
REFLECTOR_ARGS=(--verbose --latest 5 --protocol https --score 10 --sort rate)

# Enable this variable to use the system-wide mksquashfs/mkdwarfs instead
# of those provided by the Conty project
USE_SYS_UTILS=

# Supported compression algorithms: lz4, zstd, gzip, xz, lzo
# These are the algorithms supported by the integrated squashfuse
# However, your squashfs-tools (mksquashfs) may not support some of them
SQUASHFS_COMPRESSOR_ARGUMENTS=(-b 1M -comp zstd -Xcompression-level 19)

# Uncomment these variables if your mksquashfs does not support zstd or
# if you want faster compression/decompression (at the cost of compression ratio)
#SQUASHFS_COMPRESSOR_ARGUMENTS=(-b 256K -comp lz4 -Xhc)

# Set to any value to Use DwarFS instead of SquashFS
USE_DWARFS=
DWARFS_COMPRESSOR_ARGUMENTS=(
	-l7 -C zstd:level=19 --metadata-compression null
	-S 21 -B 1 --order nilsimsa
	-W 12 -w 4 --no-create-timestamp
)


# List of links to arch bootstrap archive
# Conty will try to download each one of them sequentially
BOOTSTRAP_DOWNLOAD_URLS=(
	'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://ftpmirror.infania.net/mirror/archlinux/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
	'https://mirror.rackspace.com/archlinux/iso/latest/archlinux-bootstrap-x86_64.tar.zst'
)

# sha256sums.txt file to verify downloaded bootstrap archive with
BOOTSTRAP_SHA256SUM_FILE_URL='https://archlinux.org/iso/latest/sha256sums.txt'

# Set to any value to use an existing image if it exists
# Otherwise the script will always create a new image
USE_EXISTING_IMAGE=

# When set to non-empty value existing bootstrap will always be removed
# and reextracted from downloaded archive
# Useful to set this to empty value to speed up conty build by reusing
# existing files while configuring or developing it
ALWAYS_EXTRACT_BOOTSTRAP=1
