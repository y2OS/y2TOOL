#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Yusuf Evran

set -e

YPM_ROOT="/ypm"
YPM_DB="${YPM_ROOT}/db"
YPM_REPO_OWNER="y2OS"
YPM_REPO_NAME="ypm"
YPM_REPO_BASE="https://raw.githubusercontent.com/${YPM_REPO_OWNER}/${YPM_REPO_NAME}/refs/heads/main"
YPM_RELEASE_BASE="https://github.com/${YPM_REPO_OWNER}"
YPM_DEFAULT_MAX=3

err() {
    echo "ypm: error: $*" >&2
}

die() {
    err "$@"
    exit 1
}

db_init() {
    _pkg="$1"
    _dir="${YPM_DB}/${_pkg}"
    mkdir -p "${_dir}"
    for _f in active installed saved max symlinks target; do
        [ -f "${_dir}/${_f}" ] || : > "${_dir}/${_f}"
    done
}

db_read() {
    _file="${YPM_DB}/$1/$2"
    [ -f "${_file}" ] && cat "${_file}" || :
}

db_write() {
    _file="${YPM_DB}/$1/$2"
    echo "$3" > "${_file}"
}

db_append() {
    _file="${YPM_DB}/$1/$2"
    echo "$3" >> "${_file}"
}

db_has_line() {
    _file="${YPM_DB}/$1/$2"
    [ -f "${_file}" ] && grep -qxF "$3" "${_file}"
}

db_remove_line() {
    _file="${YPM_DB}/$1/$2"
    [ -f "${_file}" ] || return 0
    _tmp="${_file}.tmp"
    grep -vxF "$3" "${_file}" > "${_tmp}" 2>/dev/null || :
    mv "${_tmp}" "${_file}"
}

fetch_recipe() {
    _pkg="$1"
    _ver="$2"
    _recipe_url="${YPM_REPO_BASE}/${_pkg}/recipe.sh"
    _recipe_content="$(wget -qO- "${_recipe_url}" 2>/dev/null)" || \
        die "failed to download recipe: ${_pkg} (${_recipe_url})"
    eval "${_recipe_content}"
    [ -z "${DOWNLOAD_URL}" ] && die "DOWNLOAD_URL not found in recipe: ${_pkg}"
    [ -z "${LINK_TARGET}" ] && die "LINK_TARGET not found in recipe: ${_pkg}"
    [ -z "${VERSION}" ] && [ -z "${_ver}" ] && die "VERSION not found in recipe: ${_pkg}"
    [ -z "${_ver}" ] && _ver="${VERSION}"
    VERSION="${_ver}"
}

fetch_package() {
    _pkg="$1"
    _ver="$2"
    _url="$3"
    _dest="${YPM_ROOT}/${_pkg}/${_ver}"
    mkdir -p "${_dest}"
    if ! (wget -qO- "${_url}" 2>/dev/null | tar xz -C "${_dest}" 2>/dev/null); then
        rm -rf "${_dest}"
        die "failed to download or extract package: ${_pkg}-${_ver}"
    fi
}

link_files() {
    _pkg="$1"
    _ver="$2"
    _target="$3"
    _src_dir="${YPM_ROOT}/${_pkg}/${_ver}"
    _symlinks_file="${YPM_DB}/${_pkg}/symlinks"
    : > "${_symlinks_file}"
    find "${_src_dir}" -type f -o -type l | while IFS= read -r _file; do
        _rel="${_file#${_src_dir}}"
        
        [ "${_rel}" = "/ypm-post.sh" ] && continue
        
        _dest="${_target}${_rel}"
        _dest_dir="$(echo "${_dest}" | sed 's|/[^/]*$||')"
        mkdir -p "${_dest_dir}"
        [ -e "${_dest}" ] || [ -L "${_dest}" ] && rm -f "${_dest}"
        ln -s "${_file}" "${_dest}"
        echo "${_dest}" >> "${_symlinks_file}"
    done
}

unlink_files() {
    _pkg="$1"
    _symlinks_file="${YPM_DB}/${_pkg}/symlinks"
    [ -f "${_symlinks_file}" ] || return 0
    while IFS= read -r _link; do
        [ -n "${_link}" ] && [ -L "${_link}" ] && rm -f "${_link}"
    done < "${_symlinks_file}"
    : > "${_symlinks_file}"
}

clean_old_versions() {
    _pkg="$1"
    _max="$2"
    _installed="$(db_read "${_pkg}" installed)"
    [ -z "${_installed}" ] && return 0
    _active="$(db_read "${_pkg}" active)"
    _saved="$(db_read "${_pkg}" saved)"
    _count="$(echo "${_installed}" | grep -c . 2>/dev/null || echo 0)"
    [ "${_count}" -le "${_max}" ] && return 0
    _to_remove=$(( _count - _max ))
    echo "${_installed}" | while IFS= read -r _ver; do
        [ "${_to_remove}" -le 0 ] && break
        [ -z "${_ver}" ] && continue
        [ "${_ver}" = "${_active}" ] && continue
        if [ -n "${_saved}" ]; then
            echo "${_saved}" | grep -qxF "${_ver}" && continue
        fi
        rm -rf "${YPM_ROOT}/${_pkg}/${_ver}"
        db_remove_line "${_pkg}" installed "${_ver}"
        _to_remove=$(( _to_remove - 1 ))
    done
}

get_max() {
    _pkg="$1"
    _max="$(db_read "${_pkg}" max)"
    [ -z "${_max}" ] && _max="${YPM_DEFAULT_MAX}"
    echo "${_max}"
}

_do_add() {
    _pkg="$1"
    _ver="$2"
    db_init "${_pkg}"
    DOWNLOAD_URL=""
    LINK_TARGET=""
    VERSION=""
    fetch_recipe "${_pkg}" "${_ver}"
    _ver="${VERSION}"
    if db_has_line "${_pkg}" installed "${_ver}"; then
        return 0
    fi
    fetch_package "${_pkg}" "${_ver}" "${DOWNLOAD_URL}"
    db_write "${_pkg}" target "${LINK_TARGET}"
    db_append "${_pkg}" installed "${_ver}"
    _active="$(db_read "${_pkg}" active)"
    if [ -z "${_active}" ]; then
        cmd_use "${_pkg}" "${_ver}"
    fi
    _max="$(get_max "${_pkg}")"
    clean_old_versions "${_pkg}" "${_max}"
}

cmd_add() {
    [ $# -eq 0 ] && die "usage: ypm add <package(s)> or <package> <version(s)>"
    _pkg="$1"
    shift
    case "$1" in
        [0-9]*)
            while [ $# -gt 0 ]; do
                _ver="$1"
                shift
                _do_add "${_pkg}" "${_ver}"
            done
            ;;
        *)
            _do_add "${_pkg}" ""
            while [ $# -gt 0 ]; do
                _do_add "$1" ""
                shift
            done
            ;;
    esac
}

cmd_use() {
    _pkg="$1"
    _ver="$2"
    [ -z "${_pkg}" ] || [ -z "${_ver}" ] && die "usage: ypm use <package> <version>"
    [ -d "${YPM_ROOT}/${_pkg}/${_ver}" ] || die "version not installed: ${_pkg}-${_ver}"
    
    _file_check="$(find "${YPM_ROOT}/${_pkg}/${_ver}" -type f -o -type l | grep -v "/ypm-post.sh" | head -n 1)"
    [ -z "${_file_check}" ] && die "error: target version directory is empty: ${_pkg}-${_ver}"
    
    _target="$(db_read "${_pkg}" target)"
    [ -z "${_target}" ] && die "target information not found: ${_pkg}"
    
    unlink_files "${_pkg}"
    link_files "${_pkg}" "${_ver}" "${_target}"
    db_write "${_pkg}" active "${_ver}"

    _hook="${YPM_ROOT}/${_pkg}/${_ver}/ypm-post.sh"
    if [ -f "${_hook}" ]; then
        chmod +x "${_hook}"
        "${_hook}" "install" "${_target}"
    fi
}

_do_del_package() {
    _pkg="$1"
    unlink_files "${_pkg}"
    rm -rf "${YPM_ROOT}/${_pkg}"
    rm -rf "${YPM_DB}/${_pkg}"
}

_do_del_version() {
    _pkg="$1"
    _ver="$2"
    _active="$(db_read "${_pkg}" active)"
    
    _hook="${YPM_ROOT}/${_pkg}/${_ver}/ypm-post.sh"
    if [ -f "${_hook}" ]; then
        chmod +x "${_hook}"
        "${_hook}" "remove" "$(db_read "${_pkg}" target)"
    fi

    if [ "${_ver}" = "${_active}" ]; then
        err "removing active version: ${_pkg}-${_ver}, symlinks will be removed"
        unlink_files "${_pkg}"
        db_write "${_pkg}" active ""
    fi
    rm -rf "${YPM_ROOT}/${_pkg}/${_ver}"
    db_remove_line "${_pkg}" installed "${_ver}"
    db_remove_line "${_pkg}" saved "${_ver}"
}

cmd_del() {
    [ $# -eq 0 ] && die "usage: ypm del <package(s)> or <package> <version(s)>"
    _pkg="$1"
    shift
    case "$1" in
        [0-9]*)
            while [ $# -gt 0 ]; do
                _ver="$1"
                shift
                _do_del_version "${_pkg}" "${_ver}"
            done
            ;;
        *)
            _do_del_package "${_pkg}"
            while [ $# -gt 0 ]; do
                _do_del_package "$1"
                shift
            done
            ;;
    esac
}

cmd_sync() {
    if [ $# -gt 0 ]; then
        while [ $# -gt 0 ]; do
            _sync_one "$1"
            shift
        done
    else
        [ -d "${YPM_DB}" ] || return 0
        for _dir in "${YPM_DB}"/*/; do
            [ -d "${_dir}" ] || continue
            _p="$(basename "${_dir}")"
            _active="$(db_read "${_p}" active)"
            [ -n "${_active}" ] && _sync_one "${_p}"
        done
    fi
}

_sync_one() {
    _pkg="$1"
    _index_url="${YPM_REPO_BASE}/${_pkg}/index.txt"
    _latest="$(wget -qO- "${_index_url}" 2>/dev/null | head -1)" || {
        err "failed to fetch index: ${_pkg}"
        return 1
    }
    [ -z "${_latest}" ] && return 0
    _active="$(db_read "${_pkg}" active)"
    if [ "${_latest}" != "${_active}" ]; then
        echo "${_pkg}: ${_active} -> ${_latest}"
        cmd_add "${_pkg}" "${_latest}"
        cmd_use "${_pkg}" "${_latest}"
    fi
}

cmd_max() {
    _count="$1"
    _pkg="$2"
    [ -z "${_count}" ] && die "usage: ypm max <count> [package]"
    case "${_count}" in
        ''|*[!0-9]*) die "invalid count: ${_count}" ;;
    esac
    if [ -n "${_pkg}" ]; then
        db_init "${_pkg}"
        db_write "${_pkg}" max "${_count}"
        clean_old_versions "${_pkg}" "${_count}"
    else
        [ -d "${YPM_DB}" ] || return 0
        for _dir in "${YPM_DB}"/*/; do
            [ -d "${_dir}" ] || continue
            _p="$(basename "${_dir}")"
            db_write "${_p}" max "${_count}"
            clean_old_versions "${_p}" "${_count}"
        done
    fi
}

cmd_save() {
    _pkg="$1"
    _ver="$2"
    [ -z "${_pkg}" ] || [ -z "${_ver}" ] && die "usage: ypm save <package> <version>"
    db_init "${_pkg}"
    db_has_line "${_pkg}" installed "${_ver}" || die "version not installed: ${_pkg}-${_ver}"
    if db_has_line "${_pkg}" saved "${_ver}"; then
        return 0
    fi
    db_append "${_pkg}" saved "${_ver}"
}

main() {
    _cmd="$1"
    [ -z "${_cmd}" ] && die "usage: ypm <command> [arguments...]
Commands:
  add  <package> [version]   - Install package
  use  <package> <version>   - Switch active version
  del  <package> [version]   - Remove package or version
  sync [package]             - Check for updates
  max  <count> [package]     - Set maximum retained versions
  save <package> <version>   - Keep version from being auto-cleaned"
    shift
    case "${_cmd}" in
        add)  cmd_add "$@"  ;;
        use)  cmd_use "$@"  ;;
        del)  cmd_del "$@"  ;;
        sync) cmd_sync "$@" ;;
        max)  cmd_max "$@"  ;;
        save) cmd_save "$@" ;;
        *)    die "unknown command: ${_cmd}" ;;
    esac
}

main "$@"
