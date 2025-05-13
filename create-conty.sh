#!/usr/bin/env bash

set -e

source settings.sh

script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
build_dir="${script_dir}/$BUILD_DIR"
utils_dir="${build_dir}/utils"
image_path="${build_dir}"/image
bootstrap="${build_dir}"/root.x86_64

if [ ! -d "${bootstrap}" ]; then
	echo "Bootstrap at $bootstrap is missing. Use the create-arch-bootstrap.sh script to create it"
	exit 1
fi

if [ ! -f "$script_dir"/conty-start.sh ]; then
	echo "conty-start.sh is required!"
	exit 1
fi

utils="$bootstrap"/opt/conty/utils.tar.xz
if [ ! -f "$utils" ]; then
	echo "Utils are missing from bootstrap.  Make sure bootstrap build script finished successfully"
	exit 1
fi
echo "Extracting $utils"
rm -rf "$utils_dir"
mkdir -p "$utils_dir"
if ! tar -C "$utils_dir" -xf "$utils"; then
	echo "Error occured while trying to extract $utils"
	exit 1
fi

launch_wrapper () {
	if [ -n "${USE_SYS_UTILS}" ]; then
		"$@"
	else
		PATH="${utils_dir}/bin:$PATH" LD_PRELOAD_PATH="${utils_dir}/lib" "$@"
	fi
}

# Create the image
echo "Creating Conty..."
if [ ! -f "${image_path}" ] || [ -z "${USE_EXISTING_IMAGE}" ]; then
	rm -f "${image_path}"
	if [ -n "$USE_DWARFS" ]; then
		launch_wrapper mkdwarfs -i "${bootstrap}" -o "${image_path}" "${DWARFS_COMPRESSOR_ARGUMENTS[@]}"
	else
		launch_wrapper mksquashfs "${bootstrap}" "${image_path}" "${SQUASHFS_COMPRESSOR_ARGUMENTS[@]}"
	fi
fi

# Write out file provided as $1, then marker that conty uses to extract files
# for the rest of provided files then the content of those files
bundle_conty() {
	cat -- "$1" && shift
	local count=1
	while :; do
		file="${!count}"
		[ -z "$file" ] && break
		printf '%s@%s@%s\n' "$(stat -c%a "$file")" "$(stat -c%s "$file")" "$(basename "$file")"
		count=$((count + 1))
	done
	printf '@CONTY_MARKER_END@\n'
	cat -- "$@"
}

bundle_conty "$utils_dir"/bin/conty_init \
			 "$script_dir"/conty-start.sh \
			 "$utils_dir"/bin/busybox \
			 "$utils" \
			 "$image_path" > "$build_dir"/conty.sh
chmod +x "$build_dir"/conty.sh
echo "Conty created and ready to use!"
