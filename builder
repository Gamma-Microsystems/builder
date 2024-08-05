#! /bin/sh

# Copyright (C) 2022-2024 mintsuki
# Copyright (C) 2024 Gamma Microsystems

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

set -e

builder_major_ver="Unstable"
builder_minor_ver="0"

builder_version="${builder_major_ver}.${builder_minor_ver}"

archlinux_snapshot_date="2024.08.01"
archlinux_snapshot_b2sum=5ef11678ec6745ae61d74ed3223d1f69cc4413e9975a7bbd9c8e8c52acef1f1c20618db8a6786fe7cb7b3fc2b6471c279fa02f39430e087ea13abb0fb5d75bb0
archlinux_snapshot_repo_date="2024/08/03"

XSTOW_VERSION=1.1.1

IFS=" ""	"'
'

LC_COLLATE=C
export LC_COLLATE

umask 0022

die() {
    echo "$1"
    exit 1
}

if ! [ "$(uname -s)" = "Linux" ]; then
    die "$0: Builder only supports running on Linux hosts."
fi

make_dir() {
    for d in "$@"; do
        mkdir -p "$d"
        dn="$(cd "$d" && pwd -P)"
        while true; do
            if [ "$dn" = "$base_dir" ] || [ "$dn" = "$build_dir" ] || [ "$dn" = "/" ]; then
                break
            fi
            chmod 755 "$dn"
            dn="$(dirname "$dn")"
        done
    done
}

case "$1" in
    install|sysroot)
        ;;
    *)
        if [ "$(id -u)" = "0" ]; then
            die "$0: builder does not support running as root."
        fi
        ;;
esac

if [ -z "$builder_PARALLELISM" ]; then
    max_threads_by_mem="$(( ((($(free | awk '/^Mem:/{print $2}') + 1048575) / 1048576) + 1) / 2 ))"
    parallelism="$(nproc 2>/dev/null || echo 1)"
    parallelism="$(( $parallelism < $max_threads_by_mem ? $parallelism : $max_threads_by_mem ))"
else
    parallelism="$builder_PARALLELISM"
fi

build_dir="$(pwd -P)"

if [ -z "$builder_SOURCE_DIR" ]; then
    base_dir="$build_dir"
else
    base_dir="$(cd "$builder_SOURCE_DIR" && pwd -P)"
fi

script_name="$(basename "$0")"
script_dir="$(dirname "$0")"
if [ "$script_dir" = "." ] || [ -z "$script_dir" ]; then
    if echo "$0" | grep "/" >/dev/null 2>&1; then
        script_dir=.
    else
        script_dir="$(dirname $(which "${script_name}"))"
    fi
fi
script_dir="$(cd "${script_dir}" && pwd -P)"
script="${script_dir}/${script_name}"

if [ -z "$builder_CONFIG_FILE" ]; then
    builder_CONFIG_FILE="${base_dir}/builder-config"
fi
if ! [ -d "$(dirname "$builder_CONFIG_FILE")" ]; then
    die "$0: cannot access config file directory"
fi
builder_CONFIG_FILE="$(cd "$(dirname "$builder_CONFIG_FILE")" && pwd -P)"/"$(basename "$builder_CONFIG_FILE")"

if [ -z "$builder_CACHE_DIR" ]; then
    builder_CACHE_DIR="${build_dir}/.builder-cache"
fi
if ! [ -d "$(dirname "$builder_CACHE_DIR")" ]; then
    die "$0: cannot access cache directory parent"
fi
make_dir "$builder_CACHE_DIR"
builder_CACHE_DIR="$(cd "$builder_CACHE_DIR" && pwd -P)"

in_container=false
if [ "$script" = "//builder" ]; then
    in_container=true
fi

if [ "$in_container" = "false" ]; then
    make_dir "${base_dir}/sources" "${build_dir}/host-builds" "${build_dir}/host-pkgs" "${build_dir}/builds" "${build_dir}/pkgs"
fi

pacman_cache="$builder_CACHE_DIR/pacman"

temp_collect=""
trap 'rm -rf $temp_collect; trap - EXIT; exit' EXIT INT TERM QUIT HUP

make_temp() {
    tmp="$(mktemp "$builder_CACHE_DIR/tmp.XXXXXXXX")"
    temp_collect="${temp_collect} ${tmp}"
    if [ "$1" = "-d" ]; then
        rm -f "${tmp}"
        make_dir "${tmp}"
    fi
}

build_hostdeps() {
    for hostdep in ${hostdeps} ${hostrundeps}; do
        [ -f "${base_dir}"/host-recipes/${hostdep} ] || die "missing host dependency '${hostdep}' for recipe '${name}'"

        [ -f "${build_dir}"/host-builds/${hostdep}.packaged ] && continue

        "${script}" host-build ${hostdep}
    done
}

build_deps() {
    for dep in ${deps} ${builddeps}; do
        [ -f "${base_dir}"/recipes/${dep} ] || die "missing dependency '${dep}' for recipe '${name}'"

        [ -f "${build_dir}"/builds/${dep}.packaged ] && continue

        "${script}" build ${dep}
    done
}

get_hostdeps_file_run() {
    deps_to_do=""

    for hostdep in ${hostrundeps}; do
        grep " ${hostdep} " "${hostdeps_file}" >/dev/null 2>&1 || deps_to_do="${deps_to_do} ${hostdep}"
        grep " ${hostdep} " "${hostdeps_file}" >/dev/null 2>&1 || printf " ${hostdep} " >> "${hostdeps_file}"
    done

    for hostdep in ${deps_to_do}; do
        "${script}" internal-get-hostdeps-file-run ${hostdep} "${hostdeps_file}"
    done
}

get_hostdeps_file() {
    deps_to_do=""

    for hostdep in ${hostdeps} ${hostrundeps}; do
        grep " ${hostdep} " "${hostdeps_file}" >/dev/null 2>&1 || deps_to_do="${deps_to_do} ${hostdep}"
        grep " ${hostdep} " "${hostdeps_file}" >/dev/null 2>&1 || printf " ${hostdep} " >> "${hostdeps_file}"
    done

    for hostdep in ${deps_to_do}; do
        "${script}" internal-get-hostdeps-file-run ${hostdep} "${hostdeps_file}"
    done
}

get_builddeps_file() {
    deps_to_do=""

    for dep in ${deps} ${builddeps}; do
        grep " ${dep} " "${deps_file}" >/dev/null 2>&1 || deps_to_do="${deps_to_do} ${dep}"
        grep " ${dep} " "${deps_file}" >/dev/null 2>&1 || printf " ${dep} " >> "${deps_file}"
    done

    for dep in ${deps_to_do}; do
        "${script}" internal-get-deps-file ${dep} "${deps_file}"
    done
}

get_deps_file() {
    deps_to_do=""

    for dep in ${deps}; do
        grep " ${dep} " "${deps_file}" >/dev/null 2>&1 || deps_to_do="${deps_to_do} ${dep}"
        grep " ${dep} " "${deps_file}" >/dev/null 2>&1 || printf " ${dep} " >> "${deps_file}"
    done

    for dep in ${deps_to_do}; do
        "${script}" internal-get-deps-file ${dep} "${deps_file}"
    done
}

run_in_container1() {
    if ! [ -z "$TERM" ]; then
        run_in_cont1_term="--env TERM=\"$TERM\""
    fi

    if ! [ -z "$COLORTERM" ]; then
        run_in_cont1_colorterm="--env COLORTERM=\"$COLORTERM\""
    fi

    run_in_cont1_root="$1"
    shift 1

    "$builder_CACHE_DIR/rbrt" \
        --root "$run_in_cont1_root" rw \
        --uid 0 \
        --gid 0 \
        --env HOME=/root \
        --env LANG=en_US.UTF-8 \
        --env LC_COLLATE=C \
        --env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl \
        --env LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib:/usr/lib64:/usr/lib \
        ${run_in_cont1_term} \
        ${run_in_cont1_colorterm} \
        -m"${pacman_cache}":/var/cache/pacman/pkg \
        -- \
        "$@"
}

check_duplicates() {
    for elem in $(cd "$1" && find .); do
        if [ -f "$2"/${elem} ] || [ -L "$2"/${elem} ]; then
            return 1
        fi
    done
}

prepare_container() {
    cd "${build_dir}"

    make_temp
    hostdeps_file="${tmp}"
    make_temp
    deps_file="${tmp}"

    build_hostdeps
    build_deps

    get_hostdeps_file
    get_builddeps_file

    make_temp -d
    container_pkgs="${tmp}"
    make_temp -d
    sysroot_dir="${tmp}"

    rm -rf "$builder_CACHE_DIR"/saved-info-dir
    for dep in $(cat "${deps_file}"); do
        if [ -f "${build_dir}"/pkgs/${dep}/usr/share/info/dir ]; then
            mv "${build_dir}"/pkgs/${dep}/usr/share/info/dir "$builder_CACHE_DIR"/saved-info-dir
        fi
        copy_failed=0
        check_duplicates "${build_dir}"/pkgs/${dep} "${sysroot_dir}" || copy_failed=1
        cp -Pplr "${build_dir}"/pkgs/${dep}/. "${sysroot_dir}"/
        if [ -f "$builder_CACHE_DIR"/saved-info-dir ]; then
            mv "$builder_CACHE_DIR"/saved-info-dir "${build_dir}"/pkgs/${dep}/usr/share/info/dir
        fi
        if [ "$copy_failed" = 1 ]; then
            die "builder: error: Dependency '${dep}' contains file confilcts"
        fi
    done

    if [ "$builder_NATIVE_MODE" = "yes" ] && [ -z "$cross_compile" ]; then
        imgroot="${sysroot_dir}"
    else
        for hostdep in $(cat "${hostdeps_file}"); do
            if [ -f "${build_dir}"/host-pkgs/${hostdep}/usr/local/share/info/dir ]; then
                mv "${build_dir}"/host-pkgs/${hostdep}/usr/local/share/info/dir "$builder_CACHE_DIR"/saved-info-dir
            fi
            copy_failed=0
            check_duplicates "${build_dir}"/host-pkgs/${hostdep}/usr/local "${container_pkgs}" || copy_failed=1
            cp -Pplr "${build_dir}"/host-pkgs/${hostdep}/usr/local/. "${container_pkgs}"/
            if [ -f "$builder_CACHE_DIR"/saved-info-dir ]; then
                mv "$builder_CACHE_DIR"/saved-info-dir "${build_dir}"/host-pkgs/${hostdep}/usr/local/share/info/dir
            fi
            if [ "$copy_failed" = 1 ]; then
                die "builder: error: Dependency '${hostdep}' contains file confilcts"
            fi
        done

        imagedeps="$(echo "${imagedeps}" | xargs -n1 | sort -u | xargs)"

        pkgset=""
        for pkg in ${imagedeps}; do
            pkgset="${pkgset}${pkg}/"

            if [ -f "$builder_CACHE_DIR/sets/${pkgset}.image/.builder-set-valid" ]; then
                continue
            fi

            make_dir "$builder_CACHE_DIR/sets/${pkgset}"

            cp -Pplrf "$builder_CACHE_DIR/sets/${pkgset}../.image" "$builder_CACHE_DIR/sets/${pkgset}.image"

            rm -f "$builder_CACHE_DIR/sets/${pkgset}.image/.builder-set-valid"

            if ! run_in_container1 "$builder_CACHE_DIR/sets/${pkgset}.image" pacman --needed --noconfirm -S "${pkg}"; then
                die 'builder error: Installing an imagedep failed.'
            fi

            # Fix permissions of files
            for f in $(find "$builder_CACHE_DIR/sets/${pkgset}.image" -perm 000 2>/dev/null); do
                chmod 755 "$f"
            done

            touch "$builder_CACHE_DIR/sets/${pkgset}.image/.builder-set-valid"
        done

        imgroot="$builder_CACHE_DIR/sets/${pkgset}.image"
    fi
}

run_in_container() {
    if [ "${allow_network}" = "yes" ]; then
        unshare_net_flag=""
    else
        unshare_net_flag="-n"
    fi

    if [ ! -z "$TERM" ]; then
        run_in_cont_term="--env TERM=\"$TERM\""
    fi

    if ! [ -z "$COLORTERM" ]; then
        run_in_cont_colorterm="--env COLORTERM=\"$COLORTERM\""
    fi

    touch "${imgroot}/builder"
    chmod +x "${imgroot}/builder"
    touch "${imgroot}/builder-config"
    make_dir "${imgroot}/base_dir" "${imgroot}/sources" "${imgroot}/build_dir"

    native_mode_mounts=""
    if ( [ "$builder_NATIVE_MODE" = "yes" ] && [ "$cross_compile" = "yes" ] ) || ( ! [ "$builder_NATIVE_MODE" = "yes" ] ); then
        make_dir "${imgroot}/sysroot"

        native_mode_mounts=y

        run_in_cont_lang=en_US.UTF-8
    else
        if ! [ -z "$builder_NATIVE_LANG" ]; then
            run_in_cont_lang="$builder_NATIVE_LANG"
        else
            run_in_cont_lang=C
        fi
    fi

    run_in_cont_argvar=""
    for arg in "$@"; do
        run_in_cont_argvar="$run_in_cont_argvar \"$arg\""
    done

    shadow_git_dir_build=""
    if [ -d "${build_dir}"/.git ]; then
        make_temp -d
        shadow_git_dir_build="-m${tmp}:/build_dir/.git"
    fi

    shadow_git_dir_base=""
    if [ -d "${base_dir}"/.git ]; then
        make_temp -d
        shadow_git_dir_base="-m${tmp}:/base_dir/.git"
    fi

    if [ -z "${native_mode_mounts}" ]; then
        "$builder_CACHE_DIR/rbrt" \
            --root "${imgroot}" \
            --uid $(id -u) \
            --gid $(id -g) \
            --env HOME=/root \
            --env LANG=${run_in_cont_lang} \
            --env LC_COLLATE=C \
            --env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl \
            --env LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib:/usr/lib64:/usr/lib \
            ${run_in_cont_term} \
            ${run_in_cont_colorterm} \
            --env builder_PARALLELISM="$parallelism" \
            --env builder_CONFIG_FILE=/builder-config \
            --env builder_SOURCE_DIR=/base_dir \
            -m"${script}":/builder:ro \
            -m"${builder_CONFIG_FILE}":/builder-config:ro \
            -m"${base_dir}":/base_dir${container_base_dir_ro} \
            "${shadow_git_dir_base}" \
            -m"${base_dir}"/sources:/base_dir/sources${container_sources_ro} \
            -m"${build_dir}":/build_dir \
            "${shadow_git_dir_build}" \
            ${unshare_net_flag} \
            --workdir / \
            -- \
            /bin/sh -c "cd /build_dir && /builder $run_in_cont_argvar"
    else
        "$builder_CACHE_DIR/rbrt" \
            --root "${imgroot}" \
            --uid $(id -u) \
            --gid $(id -g) \
            --env HOME=/root \
            --env LANG=${run_in_cont_lang} \
            --env LC_COLLATE=C \
            --env PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl \
            --env LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib:/usr/lib64:/usr/lib \
            ${run_in_cont_term} \
            ${run_in_cont_colorterm} \
            --env builder_PARALLELISM="$parallelism" \
            --env builder_CONFIG_FILE=/builder-config \
            --env builder_SOURCE_DIR=/base_dir \
            -m"${container_pkgs}":/usr/local:ro \
            -m"${sysroot_dir}":/sysroot:ro \
            -m"${script}":/builder:ro \
            -m"${builder_CONFIG_FILE}":/builder-config:ro \
            -m"${base_dir}":/base_dir${container_base_dir_ro} \
            "${shadow_git_dir_base}" \
            -m"${base_dir}"/sources:/base_dir/sources${container_sources_ro} \
            -m"${build_dir}":/build_dir \
            "${shadow_git_dir_build}" \
            ${unshare_net_flag} \
            --workdir / \
            -- \
            /bin/sh -c "cd /build_dir && /builder $run_in_cont_argvar"
    fi

    rm -rf "${imgroot}/sysroot" "${imgroot}/builder" "${imgroot}/builder-config" "${imgroot}/base_dir" "${imgroot}/sources" "${imgroot}/build_dir"
}

destroy_container() {
    rm -rf "${container_pkgs}" "${sysroot_dir}"
}

do_fetch() {
    make_dir "${base_dir}"/sources

    [ -d "${source_dir}" ] && return

    tarball_path="${base_dir}"/sources/"$(basename "${tarball_url}")"

    if ! [ -f "$tarball_path" ]; then
        make_temp
        download_path="${tmp}"

        curl -L -o "${download_path}" "${tarball_url}"
        mv "${download_path}" "${tarball_path}"
    fi

    checksum_verified=no

    if ! [ -z "${tarball_sha256}" ]; then
        actual_sha256="$(sha256sum "${tarball_path}" | awk '{print $1;}')"
        if ! [ ${actual_sha256} = ${tarball_sha256} ]; then
            die "* error: Failed to verify SHA256 for ${name}.
  Expected '${tarball_sha256}';
  got '${actual_sha256}'."
        fi
        checksum_verified=yes
    fi
    if ! [ -z "${tarball_sha512}" ]; then
        actual_sha512="$(sha512sum "${tarball_path}" | awk '{print $1;}')"
        if ! [ ${actual_sha512} = ${tarball_sha512} ]; then
            die "* error: Failed to verify SHA512 for ${name}.
  Expected '${tarball_sha512}';
  got '${actual_sha512}'."
        fi
        checksum_verified=yes
    fi
    if ! [ -z "${tarball_blake2b}" ]; then
        actual_blake2b="$("$builder_CACHE_DIR/b2sum" "${tarball_path}" | awk '{print $1;}')"
        if ! [ ${actual_blake2b} = ${tarball_blake2b} ]; then
            die "* error: Failed to verify BLAKE2B for ${name}.
  Expected '${tarball_blake2b}';
  got '${actual_blake2b}'."
        fi
        checksum_verified=yes
    fi

    if [ "${checksum_verified}" = "no" ]; then
        die "* error: No checksum method specified for ${name}"
    fi

    make_temp -d
    extract_dir="${tmp}"

    ( cd "${extract_dir}" && tar -xf "${tarball_path}" )

    mv "${extract_dir}"/* "${base_dir}"/sources/${name} >/dev/null 2>&1 || (
        make_dir "${base_dir}"/sources/${name}
        mv "${extract_dir}"/* "${base_dir}"/sources/${name}/
    )

    rm -rf "${extract_dir}" "${tarball_path}"
}

get_real_source_dir() {
    if [ -z "${source_dir}" ]; then
        source_dir="${base_dir}"/sources/${name}
    else
        source_dir="${base_dir}"/"${source_dir}"
        is_local_package=true
    fi
}

default_recipe_steps() {
    regenerate() {
        true
    }

    build() {
        true
    }

    package() {
        true
    }
}

source_source_recipe() {
    if [ -f "${base_dir}"/source-recipes/$1 ]; then
        . "${base_dir}"/source-recipes/$1
    elif [ -f "${base_dir}"/recipes/$1 ]; then
        . "${base_dir}"/recipes/$1

        unset deps
        unset builddeps
        unset hostrundeps
        imagedeps="${source_imagedeps}"
        hostdeps="${source_hostdeps}"
        deps="${source_deps}"
        allow_network="${source_allow_network}"
    else
        die "* could not find source recipe '$1'"
    fi
}

cont_patch() {
    source_source_recipe $1

    get_real_source_dir

    make_temp
    patch_trash="${tmp}"

    cd "${source_dir}"

    if [ -d "${base_dir}"/patches/${name} ]; then
        for patch in "${base_dir}"/patches/${name}/*; do
            [ "${patch}" = "${base_dir}/patches/${name}/*" ] && break
            [ "${patch}" = "${base_dir}"/patches/${name}/*.patch ] && continue
            patch --no-backup-if-mismatch -p1 -r "${patch_trash}" < "${patch}"
        done
    fi

    cp -rp "${source_dir}" "${base_dir}"/sources/${name}-clean

    if [ -f "${base_dir}"/patches/${name}/*.patch ]; then
        patch --no-backup-if-mismatch -p1 -r "${patch_trash}" < "${base_dir}"/patches/${name}/*.patch
    fi

    cp -rp "${source_dir}" "${base_dir}"/sources/${name}-workdir

    cd "${base_dir}"

    touch "${base_dir}"/sources/${name}.patched
}

do_regenerate() {
    default_recipe_steps

    source_source_recipe $1

    get_real_source_dir

    [ -f "${base_dir}"/sources/${name}.regenerated ] && return

    sysroot_dir="/sysroot"

    cd "${source_dir}"
    [ "${is_local_package}" = true ] || container_base_dir_ro=":ro"
    regenerate
    container_base_dir_ro=""
    cd "${base_dir}"

    touch "${base_dir}"/sources/${name}.regenerated
}

do_build_host() {
    default_recipe_steps

    unset from_source
    . "${base_dir}"/host-recipes/$1

    [ -f "${build_dir}"/host-builds/${name}.built ] && return

    make_dir "${build_dir}"/host-builds/${name}

    if ! [ -z "${from_source}" ]; then
        version=$(unset version && source_source_recipe ${from_source} && echo "$version")
        source_dir="$(unset source_dir && source_source_recipe ${from_source} && echo "$source_dir")"

        if [ -z "${source_dir}" ]; then
            source_dir="${base_dir}"/sources/${from_source}
        else
            source_dir="${base_dir}"/"${source_dir}"
        fi
    fi

    prefix="/usr/local"
    sysroot_dir="/sysroot"

    cd "${build_dir}"/host-builds/${name}
    build
    cd "${base_dir}"

    touch "${build_dir}"/host-builds/${name}.built
}

do_package_host() {
    default_recipe_steps

    unset from_source
    . "${base_dir}"/host-recipes/$1

    [ -f "${build_dir}"/host-builds/${name}.packaged ] && return

    dest_dir="${build_dir}"/host-pkgs/${name}

    rm -rf "${dest_dir}"
    make_dir "${dest_dir}"

    if ! [ -z "${from_source}" ]; then
        version=$(unset version && source_source_recipe ${from_source} && echo "$version")
        source_dir="$(unset source_dir && source_source_recipe ${from_source} && echo "$source_dir")"

        if [ -z "${source_dir}" ]; then
            source_dir="${base_dir}"/sources/${from_source}
        else
            source_dir="${base_dir}"/"${source_dir}"
        fi
    fi

    prefix="/usr/local"
    sysroot_dir="/sysroot"

    make_dir "${dest_dir}${prefix}"

    cd "${build_dir}"/host-builds/${name}
    package
    cd "${base_dir}"

    # Remove libtool files
    for i in $(find "${dest_dir}${prefix}" -name "*.la"); do
        rm -rvf $i
    done

    touch "${build_dir}"/host-builds/${name}.packaged
}

do_build() {
    default_recipe_steps

    unset from_source
    . "${base_dir}"/recipes/$1

    [ -f "${build_dir}"/builds/${name}.built ] && return

    make_dir "${build_dir}"/builds/${name}

    if ! [ -z "${from_source}" ] || ! [ -z "${tarball_url}" ] || ! [ -z "${source_dir}" ]; then
        if ! [ -z "${from_source}" ]; then
            version=$(unset version && source_source_recipe ${from_source} && echo "$version")
            source_dir="$(unset source_dir && source_source_recipe ${from_source} && echo "$source_dir")"
        else
            from_source=${name}
        fi

        if [ -z "${source_dir}" ]; then
            source_dir="${base_dir}"/sources/${from_source}
        else
            source_dir="${base_dir}"/"${source_dir}"
        fi
    fi

    prefix="/usr"
    sysroot_dir="/sysroot"

    cd "${build_dir}"/builds/${name}
    build
    cd "${base_dir}"

    touch "${build_dir}"/builds/${name}.built
}

do_package() {
    default_recipe_steps

    unset from_source
    . "${base_dir}"/recipes/$1

    [ -f "${build_dir}"/builds/${name}.packaged ] && return

    dest_dir="${build_dir}"/pkgs/${name}

    rm -rf "${dest_dir}"
    make_dir "${dest_dir}"

    if ! [ -z "${from_source}" ] || ! [ -z "${tarball_url}" ] || ! [ -z "${source_dir}" ]; then
        if ! [ -z "${from_source}" ]; then
            version=$(unset version && source_source_recipe ${from_source} && echo "$version")
            source_dir="$(unset source_dir && source_source_recipe ${from_source} && echo "$source_dir")"
        else
            from_source=${name}
        fi

        if [ -z "${source_dir}" ]; then
            source_dir="${base_dir}"/sources/${from_source}
        else
            source_dir="${base_dir}"/"${source_dir}"
        fi
    fi

    prefix="/usr"
    sysroot_dir="/sysroot"

    make_dir "${dest_dir}${prefix}"

    cd "${build_dir}"/builds/${name}
    package
    cd "${base_dir}"

    # Remove libtool files
    for i in $(find "${dest_dir}${prefix}" -name "*.la"); do
        rm -rvf $i
    done

    touch "${build_dir}"/builds/${name}.packaged
}

precont_patch() {
    [ -f "${base_dir}"/sources/$1.patched ] && return

    cross_compile=yes
    prepare_container
    run_in_container internal-cont-patch $1
    destroy_container
}

do_source() {
    source_source_recipe $1

    get_real_source_dir

    do_fetch

    "${script}" internal-precont-patch $1

    cross_compile=yes
    prepare_container
    run_in_container internal-regenerate $1
    destroy_container
}

do_cmd_rebuild() {
    rm -rf "${build_dir}"/builds/"$1"
    rm -rf "${build_dir}"/builds/"$1".*
    rm -rf "${build_dir}"/pkgs/"$1"
    rm -rf "${build_dir}"/pkgs/"$1".*

    do_pkg "$1"
}

do_cmd_host_rebuild() {
    rm -rf "${build_dir}"/host-builds/"$1"
    rm -rf "${build_dir}"/host-builds/"$1".*
    rm -rf "${build_dir}"/host-pkgs/"$1"
    rm -rf "${build_dir}"/host-pkgs/"$1".*

    do_host_pkg "$1"
}

do_cmd_regenerate() {
    source_source_recipe $1

    [ -f "${base_dir}"/sources/$1.patched ] || die "cannot regenerate non-built package"

    get_real_source_dir

    make_temp
    patch_file="${tmp}"

    if ! [ "${is_local_package}" = true ]; then
        cd "${base_dir}"/sources

        git diff --no-index --no-prefix $1-clean $1-workdir >"${patch_file}" || true

        if [ -s "${patch_file}" ]; then
            make_dir "${base_dir}"/patches/$1
            mv "${patch_file}" "${base_dir}"/patches/$1/*.patch
        fi

        cd "${base_dir}"

        rm -rf "${source_dir}"
        cp -rp "${base_dir}"/sources/$1-workdir "${source_dir}"
    fi

    rm -rf "${base_dir}"/sources/$1.regenerated

    cross_compile=yes
    prepare_container
    run_in_container internal-regenerate $1
    destroy_container
}

do_host_pkg() {
    unset from_source
    . "${base_dir}"/host-recipes/$1

    [ -f "${build_dir}"/host-builds/${name}.packaged ] && return

    echo "* building host package: $name"

    if ! [ -z "${from_source}" ]; then
        from_source="$(. "${base_dir}"/host-recipes/$1 && echo "$from_source")"
        [ -f "${base_dir}"/sources/${from_source}.regenerated ] || \
            "${script}" internal-source "${from_source}"
    fi

    cross_compile=yes
    prepare_container

    container_sources_ro=":ro"
    run_in_container internal-build-host $1
    run_in_container internal-package-host $1
    unset container_sources_ro

    destroy_container
}

do_pkg() {
    unset from_source
    . "${base_dir}"/recipes/$1

    [ -f "${build_dir}"/builds/${name}.packaged ] && return

    echo "* building package: $name"

    if ! [ -z "${from_source}" ]; then
        from_source="$(. "${base_dir}"/recipes/$1 && echo "$from_source")"
        [ -f "${base_dir}"/sources/${from_source}.regenerated ] || \
            "${script}" internal-source "${from_source}"
    fi

    if ! [ -z "${tarball_url}" ] || ! [ -z "${source_dir}" ]; then
        "${script}" internal-source "${name}"
    fi

    prepare_container

    container_sources_ro=":ro"
    run_in_container internal-build $1
    run_in_container internal-package $1
    unset container_sources_ro

    destroy_container
}

cmd_build_all() {
    for pkg in "${base_dir}"/recipes/*; do
        "${script}" internal-do-pkg $(basename "${pkg}")
    done
}

cmd_host_build() {
    for i in "$@"; do
        "${script}" internal-do-host-pkg "$i"
    done
}

cmd_build() {
    for i in "$@"; do
        "${script}" internal-do-pkg "$i"
    done
}

cmd_regenerate() {
    for i in "$@"; do
        "${script}" internal-do-regenerate "$i"
    done
}

cmd_host_rebuild() {
    for i in "$@"; do
        "${script}" internal-do-host-rebuild "$i"
    done
}

cmd_rebuild() {
    for i in "$@"; do
        "${script}" internal-do-rebuild "$i"
    done
}

cmd_clean() {
    rm -rf "${build_dir}"/builds
    rm -rf "${build_dir}"/host-builds
    rm -rf "${build_dir}"/pkgs
    rm -rf "${build_dir}"/host-pkgs
    rm -rf "${base_dir}"/sources
    rm -rf "${build_dir}"/sysroot
}

cmd_install() {
    sysroot="$1"
    shift 1
    mkdir -m 755 -p "${sysroot}"

    pkgs_to_install=""
    if [ "$1" = '*' ]; then
        for pkg in "${build_dir}"/pkgs/*; do
            pkgs_to_install="${pkgs_to_install} $(basename "${pkg}")"
        done
    else
        for ppkg in "$@"; do
            for pkg in $(eval echo pkgs/"${ppkg}"); do
                deps="${deps} $(basename "${pkg}")"
            done
        done

        make_temp
        deps_file="${tmp}"

        echo "* resolving dependencies..."

        get_deps_file

        pkgs_to_install="$(cat "${deps_file}")"
    fi

    make_temp
    all_files="${tmp}"

    pkg_dirs_to_install=""
    for pkg in ${pkgs_to_install}; do
        echo "* installing ${pkg}..."
        ( cd "${build_dir}"/pkgs/${pkg} && find . >>"${all_files}" )

        pkg_dirs_to_install="${pkg_dirs_to_install} ${pkg}/."
    done

    echo "* checking for conflicts..."

    make_temp
    all_files_sorted="${tmp}"

    make_temp
    all_files_uniq="${tmp}"

    sort <"${all_files}" >"${all_files_sorted}"
    uniq <"${all_files_sorted}" >"${all_files_uniq}"

    dup_elements="$(comm -23 "${all_files_sorted}" "${all_files_uniq}" | uniq)"

    rm -f "$builder_CACHE_DIR/merged-info-dir"

    for pkg in ${pkgs_to_install}; do
        for elem in ${dup_elements}; do
            if [ -f "${build_dir}"/pkgs/${pkg}/${elem} ] || [ -L "${build_dir}"/pkgs/${pkg}/${elem} ]; then
                if [ "${elem}" = "./usr/share/info/dir" ]; then
                    # Coalesce info directory
                    if ! [ -f "$builder_CACHE_DIR/merged-info-dir" ]; then
                        cp "${build_dir}"/pkgs/${pkg}/${elem} "$builder_CACHE_DIR/merged-info-dir"
                    else
                        "$builder_CACHE_DIR/merge-info" -o "$builder_CACHE_DIR/merged-info-dir" "${build_dir}"/pkgs/${pkg}/${elem} "$builder_CACHE_DIR/merged-info-dir"
                    fi
                    continue
                fi
                die "* error: duplicate files were found in package '${pkg}': ${elem}"
            fi
        done
    done

    echo "* synchronising package files to sysroot '${sysroot}'..."
    sysroot_abs="$(cd "${sysroot}" && pwd -P)"
    ( cd "${build_dir}/pkgs" && rsync -urlptD ${pkg_dirs_to_install} "${sysroot_abs}"/ )

    # inject the merged info dir into sysroot
    if [ -f "${sysroot}"/usr/share/info/dir ] && [ -f "$builder_CACHE_DIR/merged-info-dir" ]; then
        "$builder_CACHE_DIR/merge-info" -o "${sysroot}"/usr/share/info/dir "$builder_CACHE_DIR/merged-info-dir" "${sysroot}"/usr/share/info/dir
    else
        if [ -f "$builder_CACHE_DIR/merged-info-dir" ]; then
            cp "$builder_CACHE_DIR/merged-info-dir" "${sysroot}"/usr/share/info/dir
        fi
    fi
}

rebuild_b2sum() {
    cat <<'EOF' >"$builder_CACHE_DIR/b2sum.c"
// This blake2b implementation comes from the GNU coreutils project.
// https://github.com/coreutils/coreutils/blob/master/src/blake2/blake2b-ref.c

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLAKE2B_OUT_BYTES 64
#define BLAKE2B_BLOCK_BYTES 128
#define BLAKE2B_KEY_BYTES 64
#define BLAKE2B_SALT_BYTES 16
#define BLAKE2B_PERSONAL_BYTES 16

static const uint64_t blake2b_iv[8] = {
    0x6a09e667f3bcc908,
    0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b,
    0xa54ff53a5f1d36f1,
    0x510e527fade682d1,
    0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b,
    0x5be0cd19137e2179,
};

static const uint8_t blake2b_sigma[12][16] = {
    {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
    { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
    { 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 },
    {  7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 },
    {  9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 },
    {  2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 },
    { 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 },
    { 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 },
    {  6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 },
    { 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0 },
    {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
    { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
};

struct blake2b_state {
    uint64_t h[8];
    uint64_t t[2];
    uint64_t f[2];
    uint8_t buf[BLAKE2B_BLOCK_BYTES];
    size_t buf_len;
    uint8_t last_node;
};

struct blake2b_param {
    uint8_t digest_length;
    uint8_t key_length;
    uint8_t fan_out;
    uint8_t depth;
    uint32_t leaf_length;
    uint32_t node_offset;
    uint32_t xof_length;
    uint8_t node_depth;
    uint8_t inner_length;
    uint8_t reserved[14];
    uint8_t salt[BLAKE2B_SALT_BYTES];
    uint8_t personal[BLAKE2B_PERSONAL_BYTES];
} __attribute__((packed));

static void blake2b_increment_counter(struct blake2b_state *state, uint64_t inc) {
    state->t[0] += inc;
    state->t[1] += state->t[0] < inc;
}

static inline uint64_t rotr64(uint64_t w, unsigned c) {
    return (w >> c) | (w << (64 - c));
}

#define G(r, i, a, b, c, d) do { \
        a = a + b + m[blake2b_sigma[r][2 * i + 0]]; \
        d = rotr64(d ^ a, 32); \
        c = c + d; \
        b = rotr64(b ^ c, 24); \
        a = a + b + m[blake2b_sigma[r][2 * i + 1]]; \
        d = rotr64(d ^ a, 16); \
        c = c + d; \
        b = rotr64(b ^ c, 63); \
    } while (0)

#define ROUND(r) do { \
        G(r, 0, v[0], v[4], v[8], v[12]); \
        G(r, 1, v[1], v[5], v[9], v[13]); \
        G(r, 2, v[2], v[6], v[10], v[14]); \
        G(r, 3, v[3], v[7], v[11], v[15]); \
        G(r, 4, v[0], v[5], v[10], v[15]); \
        G(r, 5, v[1], v[6], v[11], v[12]); \
        G(r, 6, v[2], v[7], v[8], v[13]); \
        G(r, 7, v[3], v[4], v[9], v[14]); \
    } while (0)

static void blake2b_compress(struct blake2b_state *state, const uint8_t block[static BLAKE2B_BLOCK_BYTES]) {
    uint64_t m[16];
    uint64_t v[16];

    for (int i = 0; i < 16; i++) {
        m[i] = *(uint64_t *)(block + i * sizeof(m[i]));
    }

    for (int i = 0; i < 8; i++) {
        v[i] = state->h[i];
    }

    v[8] = blake2b_iv[0];
    v[9] = blake2b_iv[1];
    v[10] = blake2b_iv[2];
    v[11] = blake2b_iv[3];
    v[12] = blake2b_iv[4] ^ state->t[0];
    v[13] = blake2b_iv[5] ^ state->t[1];
    v[14] = blake2b_iv[6] ^ state->f[0];
    v[15] = blake2b_iv[7] ^ state->f[1];

    ROUND(0);
    ROUND(1);
    ROUND(2);
    ROUND(3);
    ROUND(4);
    ROUND(5);
    ROUND(6);
    ROUND(7);
    ROUND(8);
    ROUND(9);
    ROUND(10);
    ROUND(11);

    for (int i = 0; i < 8; i++) {
        state->h[i] = state->h[i] ^ v[i] ^ v[i + 8];
    }
}

#undef G
#undef ROUND

static void blake2b_init(struct blake2b_state *state) {
    struct blake2b_param param;
    memset(&param, 0, sizeof(struct blake2b_param));

    param.digest_length = BLAKE2B_OUT_BYTES;
    param.fan_out = 1;
    param.depth = 1;

    memset(state, 0, sizeof(struct blake2b_state));

    for (int i = 0; i < 8; i++) {
        state->h[i] = blake2b_iv[i];
    }

    for (int i = 0; i < 8; i++) {
        state->h[i] ^= *(uint64_t *)((void *)&param + sizeof(state->h[i]) * i);
    }
}

static void blake2b_update(struct blake2b_state *state, const void *in, size_t in_len) {
    if (in_len == 0) {
        return;
    }

    size_t left = state->buf_len;
    size_t fill = BLAKE2B_BLOCK_BYTES - left;

    if (in_len > fill) {
        state->buf_len = 0;

        memcpy(state->buf + left, in, fill);
        blake2b_increment_counter(state, BLAKE2B_BLOCK_BYTES);
        blake2b_compress(state, state->buf);

        in += fill;
        in_len -= fill;

        while (in_len > BLAKE2B_BLOCK_BYTES) {
            blake2b_increment_counter(state, BLAKE2B_BLOCK_BYTES);
            blake2b_compress(state, in);

            in += fill;
            in_len -= fill;
        }
    }

    memcpy(state->buf + state->buf_len, in, in_len);
    state->buf_len += in_len;
}

static void blake2b_final(struct blake2b_state *state, void *out) {
    uint8_t buffer[BLAKE2B_OUT_BYTES] = {0};

    blake2b_increment_counter(state, state->buf_len);
    state->f[0] = (uint64_t)-1;
    memset(state->buf + state->buf_len, 0, BLAKE2B_BLOCK_BYTES - state->buf_len);
    blake2b_compress(state, state->buf);

    for (int i = 0; i < 8; i++) {
        *(uint64_t *)(buffer + sizeof(state->h[i]) * i) = state->h[i];
    }

    memcpy(out, buffer, BLAKE2B_OUT_BYTES);
    memset(buffer, 0, sizeof(buffer));
}

static void blake2b(void *out, const void *in, size_t in_len) {
    struct blake2b_state state = {0};

    blake2b_init(&state);
    blake2b_update(&state, in, in_len);
    blake2b_final(&state, out);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        return EXIT_FAILURE;
    }

    FILE *f = fopen(argv[1], "r");
    if (f == NULL) {
        return EXIT_FAILURE;
    }

    fseek(f, 0, SEEK_END);
    size_t f_size = ftell(f);
    rewind(f);

    void *mem = malloc(f_size);
    if (mem == NULL) {
        return EXIT_FAILURE;
    }

    if (fread(mem, f_size, 1, f) != 1) {
        return EXIT_FAILURE;
    }

    uint8_t out_buf[BLAKE2B_OUT_BYTES];
    blake2b(out_buf, mem, f_size);

    for (size_t i = 0; i < BLAKE2B_OUT_BYTES; i++) {
        printf("%02x", out_buf[i]);
    }

    printf("  %s\n", argv[1]);
}
EOF
    cc -O2 -pipe -fno-strict-aliasing -Wall -Wextra "$builder_CACHE_DIR/b2sum.c" -o "$builder_CACHE_DIR/b2sum"
}

rebuild_rbrt() {
    cat <<'EOF' >"$builder_CACHE_DIR/rbrt.c"
// Written by 48cf (iretq@riseup.net)
// Inspired heavily by https://github.com/managarm/cbuildrt/

#define _GNU_SOURCE

#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/wait.h>

#define STRINGIFY(x) #x
#define TOSTRING(x) STRINGIFY(x)

int main(int argc, char *argv[]) {
    int ok = 1;
    const char *err_msg = "";

    char *rootfs = NULL;
    char **mounts = NULL;
    char **envs = NULL;
    char **process_args = NULL;

    int mount_count = 0;
    int mounts_size = 0;

    int env_count = 0;
    int envs_size = 0;

    bool rw_root = false;
    bool unshare_net = false;

    int uid = -1, gid = -1;
    int euid = geteuid();
    int egid = getegid();

    int setgroups_fd = -1;
    int uid_map_fd = -1;
    int gid_map_fd = -1;

    char *workdir = "/";

    for (int i = 1; i < argc; ) {
        if (strcmp(argv[i], "--workdir") == 0) {
            workdir = argv[i + 1];
            i += 2;
        } else if (strcmp(argv[i], "-r") == 0 || strcmp(argv[i], "--root") == 0) {
            if (i == argc - 1) {
                fprintf(stderr, "%s: '%s' requires a value\n", argv[0], argv[i]);
                goto cleanup;
            }

            rootfs = argv[i + 1];
            i += 2;

            if (i < argc - 1 && strcmp(argv[i], "rw") == 0) {
                rw_root = true;
                i++;
            }
        } else if (strcmp(argv[i], "-u") == 0 || strcmp(argv[i], "--uid") == 0) {
            if (i == argc - 1) {
                fprintf(stderr, "%s: '%s' requires a value\n", argv[0], argv[i]);
                goto cleanup;
            }

            if (sscanf(argv[i + 1], "%d", &uid) != 1) {
                fprintf(stderr, "%s: '%s' is not a valid user ID\n", argv[0], argv[i + 1]);
                goto cleanup;
            }

            i += 2;
        } else if (strcmp(argv[i], "-g") == 0 || strcmp(argv[i], "--gid") == 0) {
            if (i == argc - 1) {
                fprintf(stderr, "%s: '%s' requires a value\n", argv[0], argv[i]);
                goto cleanup;
            }

            if (sscanf(argv[i + 1], "%d", &gid) != 1) {
                fprintf(stderr, "%s: '%s' is not a valid group ID\n", argv[0], argv[i + 1]);
                goto cleanup;
            }

            i += 2;
        } else if (strncmp(argv[i], "-m", 2) == 0) {
            if (mount_count == mounts_size) {
                mounts_size = mounts_size == 0 ? 16 : mounts_size * 2;
                char **tmp_mounts = realloc(mounts, sizeof(char *) * mounts_size);
                if (tmp_mounts == NULL) {
                    fprintf(stderr, "%s: failed to allocate mounts array\n", argv[0]);
                    goto cleanup;
                }
                mounts = tmp_mounts;
            }

            char *target = argv[i] + 2;
            while (*target && *target != ':') {
                target++;
            }

            if (!*target) {
                fprintf(stderr, "%s: mount points need to be provided in the 'source:target' format\n", argv[0]);
                goto cleanup;
            }

            mounts[mount_count++] = argv[i] + 2;
            i += 1;
        } else if (strcmp(argv[i], "-e") == 0 || strcmp(argv[i], "--env") == 0) {
            if (i == argc - 1) {
                fprintf(stderr, "%s: '%s' requires a value\n", argv[0], argv[i]);
                goto cleanup;
            }

            if (env_count == envs_size) {
                envs_size = envs_size == 0 ? 16 : envs_size * 2;
                char **tmp_envs = realloc(envs, sizeof(char *) * envs_size);
                if (tmp_envs == NULL) {
                    fprintf(stderr, "%s: failed to allocate environment variables array\n", argv[0]);
                    goto cleanup;
                }
                envs = tmp_envs;
            }

            char *value = argv[i + 1];
            while (*value && *value != '=') {
                value++;
            }

            if (!*value) {
                fprintf(stderr, "%s: environment variables need to be provided in the 'key=value' format\n", argv[0]);
                goto cleanup;
            }

            envs[env_count++] = argv[i + 1];
            i += 2;
        } else if (strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--net") == 0) {
            unshare_net = true;
            i += 1;
        } else if (strcmp(argv[i], "--") == 0) {
            if (i == argc - 1) {
                fprintf(stderr, "%s: at least one trailing argument is required\n", argv[0]);
                goto cleanup;
            }

            process_args = &argv[i + 1];
            break;
        } else {
            fprintf(stderr, "%s: unrecognized option '%s'\n", argv[0], argv[i]);
            goto cleanup;
        }
    }

    if (rootfs == NULL) {
        fprintf(stderr, "%s: root file system path is required\n", argv[0]);
        goto cleanup;
    }

    if (process_args == NULL) {
        fprintf(stderr, "%s: process arguments are requires\n", argv[0]);
        goto cleanup;
    }

    if (uid == -1 || gid == -1) {
        fprintf(stderr, "%s: user and group IDs are both required\n", argv[0]);
        goto cleanup;
    }

    if (unshare(CLONE_NEWUSER | CLONE_NEWPID) < 0) {
        err_msg = "unshare() failure at line " TOSTRING(__LINE__);
        goto errno_error;
    }

    char uid_map[64], gid_map[64];

    int uid_map_len = snprintf(uid_map, 64, "%d %d 1", uid, euid);
    int gid_map_len = snprintf(gid_map, 64, "%d %d 1", gid, egid);

    setgroups_fd = open("/proc/self/setgroups", O_RDWR);
    if (setgroups_fd < 0 || write(setgroups_fd, "deny", 4) < 0) {
        err_msg = "failed to open or write to /proc/self/setgroups at line " TOSTRING(__LINE__);
        goto errno_error;
    }
    close(setgroups_fd);
    setgroups_fd = -1;

    uid_map_fd = open("/proc/self/uid_map", O_RDWR);
    if (uid_map_fd < 0 || write(uid_map_fd, uid_map, uid_map_len) < 0) {
        err_msg = "failed to open or write to /proc/self/uid_map at line " TOSTRING(__LINE__);
        goto errno_error;
    }
    close(uid_map_fd);
    uid_map_fd = -1;

    gid_map_fd = open("/proc/self/gid_map", O_RDWR);
    if (gid_map_fd < 0 || write(gid_map_fd, gid_map, gid_map_len) < 0) {
        err_msg = "failed to open or write to /proc/self/gid_map at line " TOSTRING(__LINE__);
        goto errno_error;
    }
    close(gid_map_fd);
    gid_map_fd = -1;

    if (setuid(uid) < 0 || setgid(gid) < 0) {
        err_msg = "setuid()/setgid() failure at line " TOSTRING(__LINE__);
        goto errno_error;
    }

    int child_pid = fork();
    if (child_pid == 0) {
        if (unshare(CLONE_NEWNS) < 0) {
            err_msg = "unshare() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        if (mount(rootfs, rootfs, NULL, MS_BIND, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        int root_flags = MS_REMOUNT | MS_BIND | MS_NOSUID | MS_NODEV;

        if (!rw_root) {
            root_flags |= MS_RDONLY;
        }

        if (mount(rootfs, rootfs, NULL, root_flags, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        char target_path[PATH_MAX];

        snprintf(target_path, PATH_MAX, "%s/etc/resolv.conf", rootfs);
        if (mount("/etc/resolv.conf", target_path, NULL, MS_BIND, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/dev", rootfs);
        if (mount("/dev", target_path, NULL, MS_REC | MS_BIND | MS_SLAVE, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/sys", rootfs);
        if (mount("/sys", target_path, NULL, MS_REC | MS_BIND | MS_SLAVE, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/run", rootfs);
        if (mount(NULL, target_path, "tmpfs", 0, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/tmp", rootfs);
        if (mount(NULL, target_path, "tmpfs", 0, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/var/tmp", rootfs);
        if (mount(NULL, target_path, "tmpfs", 0, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        snprintf(target_path, PATH_MAX, "%s/proc", rootfs);
        if (mount(NULL, target_path, "proc", 0, NULL) < 0) {
            err_msg = "mount() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        for (int i = 0; i < mount_count; i++) {
            char *source = mounts[i];
            char *target = source;

            while (*target && *target != ':') {
                target++;
            }

            *target++ = 0;

            char *read_only = target;

            while (*read_only && *read_only != ':') {
                read_only++;
            }

            bool ro = false;
            if (*read_only == ':') {
                *read_only++ = 0;
                ro = strcmp(read_only, "ro") == 0;
            }

            snprintf(target_path, PATH_MAX, "%s%s", rootfs, target);
            if (mount(source, target_path, NULL, MS_BIND | (ro ? MS_RDONLY : 0), NULL) < 0) {
                err_msg = "mount() failure at line " TOSTRING(__LINE__);
                goto errno_error;
            }
            if (ro) {
                if (mount(source, target_path, NULL, MS_REMOUNT | MS_BIND | MS_RDONLY, NULL) < 0) {
                    err_msg = "mount() failure at line " TOSTRING(__LINE__);
                    goto errno_error;
                }
            }
        }

        if (unshare_net && unshare(CLONE_NEWNET) < 0) {
            err_msg = "unshare() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        if (chroot(rootfs) < 0) {
            err_msg = "chroot() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        if (chdir(workdir) < 0) {
            err_msg = "chdir() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        int child = fork();
        if (child == 0) {
            clearenv();

            setenv("HOME", "/root", 1);
            setenv("LANG", "C", 1);
            setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);

            for (int i = 0; i < env_count; i++) {
                char *key = envs[i];
                char *value = key;

                while (*value && *value != '=') {
                    value++;
                }

                *value++ = 0;
                setenv(key, value, 1);
            }

            if (execvp(process_args[0], process_args) < 0) {
                err_msg = "execvp() failure at line " TOSTRING(__LINE__);
                goto errno_error;
            }

            __builtin_unreachable();
        } else {
            int exit_code = -1;
            if (waitpid(child, &exit_code, 0) < 0) {
                err_msg = "waitpid() failure at line " TOSTRING(__LINE__);
                goto errno_error;
            }

            ok = WEXITSTATUS(exit_code);
            goto cleanup;
        }

        __builtin_unreachable();
    } else {
        int exit_code = -1;
        if (waitpid(child_pid, &exit_code, 0) < 0) {
            err_msg = "waitpid() failure at line " TOSTRING(__LINE__);
            goto errno_error;
        }

        ok = WEXITSTATUS(exit_code);
        goto cleanup;
    }

errno_error:
    fprintf(stderr, "%s: %s: %s\n", argv[0], err_msg, strerror(errno));

cleanup:
    if (mounts != NULL) {
        free(mounts);
    }
    if (envs != NULL) {
        free(envs);
    }
    if (setgroups_fd >= 0) {
        close(setgroups_fd);
    }
    if (uid_map_fd >= 0) {
        close(uid_map_fd);
    }
    if (gid_map_fd >= 0) {
        close(gid_map_fd);
    }

    return ok;
}
EOF
    cc -O2 -pipe -Wall -Wextra "$builder_CACHE_DIR/rbrt.c" -o "$builder_CACHE_DIR/rbrt"
}

reinit_container() {
    chmod -R 777 "$builder_CACHE_DIR/sets" 2>/dev/null || true
    chmod -R 777 "$builder_CACHE_DIR/pacman" 2>/dev/null || true
    rm -rf "$builder_CACHE_DIR/arch-root.tar.zst" "$builder_CACHE_DIR/sets" "$builder_CACHE_DIR/pacman"

    make_dir "${pacman_cache}"

    curl -L -o "$builder_CACHE_DIR/arch-root.tar.zst" https://archive.archlinux.org/iso/${archlinux_snapshot_date}/archlinux-bootstrap-x86_64.tar.zst
    if ! "$builder_CACHE_DIR/b2sum" "$builder_CACHE_DIR/arch-root.tar.zst" | grep "${archlinux_snapshot_b2sum}" >/dev/null 2>&1; then
        die "builder: Failed to verify Arch Linux bootstrap tarball"
    fi
    ( cd "$builder_CACHE_DIR" && zstdcat arch-root.tar.zst | bsdtar -xf - )
    rm "$builder_CACHE_DIR/arch-root.tar.zst"
    make_dir "$builder_CACHE_DIR/sets"
    mv "$builder_CACHE_DIR/root.x86_64" "$builder_CACHE_DIR/sets/.image"

    echo "Server = https://archive.archlinux.org/repos/${archlinux_snapshot_repo_date}/\$repo/os/\$arch" > "$builder_CACHE_DIR/sets/.image/etc/pacman.d/mirrorlist"
    echo 'en_US.UTF-8 UTF-8' > "$builder_CACHE_DIR/sets/.image/etc/locale.gen"
    make_dir "$builder_CACHE_DIR/sets/.image/etc/pacman.d/gnupg"
    run_in_container1 "$builder_CACHE_DIR/sets/.image" locale-gen
    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman-key --init
    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman-key --populate archlinux
    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman --noconfirm -Sy archlinux-keyring
    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman --noconfirm -S pacman pacman-mirrorlist
    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman --noconfirm -Syu
    run_in_container1 "$builder_CACHE_DIR/sets/.image" sed -i "s/ check / !check /g" /etc/makepkg.conf
    run_in_container1 "$builder_CACHE_DIR/sets/.image" sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j${parallelism}\"/g" /etc/makepkg.conf

    # Fix permissions of files
    for f in $(find "$builder_CACHE_DIR/sets/.image" -perm 000 2>/dev/null); do
        chmod 755 "$f"
    done

    run_in_container1 "$builder_CACHE_DIR/sets/.image" pacman --needed --noconfirm -S bison diffutils docbook-xsl flex gettext inetutils libtool libxslt m4 make patch perl python texinfo w3m which xmlto

    # Build xstow
    XSTOW_BUILDENV="$builder_CACHE_DIR/xstow_buildenv"
    cp -Pprf "$builder_CACHE_DIR/sets/.image/." "${XSTOW_BUILDENV}/"
    curl -Lo "${XSTOW_BUILDENV}/xstow-${XSTOW_VERSION}.tar.gz" https://github.com/majorkingleo/xstow/releases/download/${XSTOW_VERSION}/xstow-${XSTOW_VERSION}.tar.gz
    ( cd "${XSTOW_BUILDENV}" && gunzip < xstow-${XSTOW_VERSION}.tar.gz | tar -xf - )
    run_in_container1 "${XSTOW_BUILDENV}" pacman --needed --noconfirm -S base-devel
    run_in_container1 "${XSTOW_BUILDENV}" sh -c "cd /xstow-${XSTOW_VERSION} && ./configure LDFLAGS='-static' --enable-static --enable-merge-info --without-curses && make -j${parallelism}"
    mv "${XSTOW_BUILDENV}/xstow-${XSTOW_VERSION}/src/merge-info" "$builder_CACHE_DIR/"
    chmod -R 777 "$XSTOW_BUILDENV"
    rm -rf "$XSTOW_BUILDENV"
}

first_use() {
    echo "* preparing builder cache..."

    make_dir "$builder_CACHE_DIR"

    rebuild_b2sum
    rebuild_rbrt

    reinit_container

    echo "$builder_version" > "$builder_CACHE_DIR/version"

    echo "* done"
}

redo_first_use() {
    echo "* purging old builder cache..."
    chmod -R 777 "$builder_CACHE_DIR" || true
    rm -rf "$builder_CACHE_DIR"
    first_use
}

case "$1" in
    version|--version)
        echo "builder version $builder_version"
        exit 0
        ;;
esac

if ! [ -f "$builder_CONFIG_FILE" ]; then
    die "$0: missing builder config file '$builder_CONFIG_FILE'"
fi

. "${builder_CONFIG_FILE}"

if [ -z "$builder_MAJOR_VER" ]; then
    die "$0: required config variable \$builder_MAJOR_VER missing"
fi

if ! [ "$builder_MAJOR_VER" = "$builder_major_ver" ]; then
    die "$0: needed major version ($builder_MAJOR_VER) differs from builder-provided major version ($builder_major_ver)"
fi

if ! [ -d "$builder_CACHE_DIR" ]; then
    first_use
fi

if ! [ -f "$builder_CACHE_DIR/version" ] || ! [ "$(cat "$builder_CACHE_DIR/version")" = "$builder_version" ]; then
    redo_first_use
fi

case "$1" in
    internal-regenerate)
        do_regenerate "$2"
        ;;
    internal-precont-patch)
        precont_patch "$2"
        ;;
    internal-cont-patch)
        cont_patch "$2"
        ;;
    internal-build-host)
        do_build_host "$2"
        ;;
    internal-package-host)
        do_package_host "$2"
        ;;
    internal-build)
        do_build "$2"
        ;;
    internal-package)
        do_package "$2"
        ;;
    internal-get-deps-file)
        . "${base_dir}"/recipes/$2
        deps_file="$3"
        get_deps_file
        ;;
    internal-get-hostdeps-file-run)
        . "${base_dir}"/host-recipes/$2
        hostdeps_file="$3"
        get_hostdeps_file_run
        ;;
    internal-source)
        do_source "$2"
        ;;
    internal-do-host-pkg)
        do_host_pkg "$2"
        ;;
    internal-do-pkg)
        do_pkg "$2"
        ;;
    internal-do-regenerate)
        do_cmd_regenerate "$2"
        ;;
    internal-do-host-rebuild)
        do_cmd_host_rebuild "$2"
        ;;
    internal-do-rebuild)
        do_cmd_rebuild "$2"
        ;;
    host-build)
        shift 1
        cmd_host_build "$@"
        ;;
    build)
        shift 1
        cmd_build "$@"
        ;;
    build-all)
        cmd_build_all
        ;;
    regenerate)
        shift 1
        cmd_regenerate "$@"
        ;;
    host-rebuild)
        shift 1
        cmd_host_rebuild "$@"
        ;;
    rebuild)
        shift 1
        cmd_rebuild "$@"
        ;;
    install)
        shift 1
        cmd_install "$@"
        ;;
    sysroot)
        cmd_install sysroot '*'
        ;;
    clean)
        cmd_clean
        ;;
    rbrt)
        rebuild_rbrt
        ;;
    rebuild-cache)
        redo_first_use
        ;;
    *)
        if [ -z "$1" ]; then
            die "$0: no command specified."
        else
            die "$0: unknown command: $1"
        fi
        ;;
esac
