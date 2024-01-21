#!/bin/bash

set -e

logger() {
    local fd line severity reset color

    fd="${1}"
    severity="${2}"
    reset=
    color=

    if [ -n "${TERM}" ]; then
        reset="\e[0m"
        case "${severity}" in
            error)
                color="\e[0;91m"
                ;;
            warn)
                color="\e[0;93m"
                ;;
            debug)
                color="\e[0;96m"
                ;;
            data)
                color="\e[0;95m"
                ;;
            *)
                color="\e[0;94m"
                ;;
        esac
    fi

    while IFS= read -r line ; do
        if [ "${fd}" = "out" ]; then
            printf "${color}%-6s${reset}| %s\n" "${severity}" "${line}" >&1
        elif [ "${fd}" = "err" ]; then
            printf "${color}%-6s${reset}| %s\n" "${severity}" "${line}" >&2
        fi
    done
}

log() {
    echo "$@" | logger "out" ""
}

log_debug() {
    echo "$@" | logger "out" "debug"
}

log_info() {
    echo "$@" | logger "out" "info"
}

log_data() {
    echo "$@" | logger "out" "data"
}

log_error() {
    echo "$@" | logger "err" "error"
}

log_warn() {
    echo "$@" | logger "err" "warn"
}

overwrite() {
    local data="$(echo -n ${@})" # trim
    if [ -n "${data}" ]; then
        echo -e "\r\033[1A\033[0K${data}"
    fi
}


next_release() {
    local release=

    case "${1}" in
        wheezy)
            release="jessie"
            ;;
        jessie)
            release="stretch"
            ;;
        stretch)
            release="buster"
            ;;
        buster)
            release="bullseye"
            ;;
        bullseye)
            release="bookworm"
            ;;
    esac
    printf "${release}"
}

update_sources() {
    local previous_release=$(lsb_release --short --codename)
    local release=$(next_release "${previous_release}")

    if [ -n "${release}" ]; then
        log_info "Updating Debian sources from ${previous_release} to ${release}"
        for i in /etc/apt/sources.list /etc/apt/sources.list.d/*.list ; do
            if grep -q "${previous_release}" "${i}" ; then
                log_debug "Updating Debian sources from ${i}"
                sed -i -E "s/${previous_release}/${release}/g" "${i}"
                sed -i -E "s/archive\.debian\.org/deb.debian.org/g" "${i}"
                if [ "${i}" = '/etc/apt/sources.list' ]; then
                    if [ "${release}" = "bullseye" ] ; then
                        log_debug "Updating Debian sources for ${release} from ${i}"
                        sed -i -E "s#security ${release}/updates#security ${release}-security#" "${i}"
                    elif [ "${release}" = "bookworm" ] ; then
                        log_debug "Updating Debian sources for ${release} from ${i}"
                        sed -i -E 's/non-free$/non-free non-free-firmware/' "${i}"
                    fi
                fi
            fi
        done
    else
        log_warn "No updating Debian sources, next release does not exists"
    fi
}

update_packages() {
    log_info "Updating packages..."
    apt \
        -qq \
        -o 'Apt::Cmd::Disable-Script-Warning=true' \
        update | logger "out" "info2"
}

upgrade_packages() {
    for cmd in upgrade full-upgrade ; do
        log_info "Upgrading packages (${cmd})..."
        echo
        apt \
            -qq -y \
            -o 'Dpkg::Options::=--force-confdef' \
            -o 'Dpkg::Options::=--force-confold' \
            -o 'Apt::Cmd::Disable-Script-Warning=true' \
            -o 'Dpkg::Progress-Fancy=0' \
            -o 'Dpkg::Use-Pty=0' \
            "${cmd}" | \
                while read line ; do
                    overwrite "${line}"
                done
        if [ "${?}" != 0 ]; then
            log_error "Upgrade failed, check errors..."
            exit 1
        fi
    done
}

install_packages() {
    log_info "Installing package(s) (${@})..."
    echo
    apt \
        -qq -y \
        -o 'Apt::Cmd::Disable-Script-Warning=true' \
        -o 'Dpkg::Progress-Fancy=0' \
        -o 'Dpkg::Use-Pty=0' \
        install ${@} | \
        while read line ; do
            overwrite "${line}"
        done
}

purge_packages() {
    log_info "Purging package(s) (${@})..."
    echo
    apt \
        -qq -y \
        -o 'Apt::Cmd::Disable-Script-Warning=true' \
        -o 'Dpkg::Progress-Fancy=0' \
        -o 'Dpkg::Use-Pty=0' \
        purge ${@} | \
        while read line ; do
            overwrite "${line}"
        done
}

clean_orphaned() {
    if ! which deborphan >/dev/null ; then
        install_packages deborphan
    fi
    while true; do
        n=$(deborphan | wc -l)
        if [ "${n}" = "0" ]; then
            break
        fi
        log_info "Removing orphaned packages..."
        echo
        apt \
            -qq -y \
            -o 'Apt::Cmd::Disable-Script-Warning=true' \
            -o 'Dpkg::Progress-Fancy=0' \
            -o 'Dpkg::Use-Pty=0' \
            purge $(deborphan|xargs) | \
            while read line ; do
                overwrite "${line}"
            done
        log_info "Removing no longer used packages..."
        echo
        apt \
            -qq -y \
            -o 'Apt::Cmd::Disable-Script-Warning=true' \
            -o 'Dpkg::Progress-Fancy=0' \
            -o 'Dpkg::Use-Pty=0' \
            --purge autoremove | \
            while read line ; do
                overwrite "${line}"
            done
    done
}

cleanup() {
    local packages=
    # Old PHP5 packages
    packages="${packages} $(dpkg -l 'php5-*' 2>/dev/null | grep '^ii' | tr -s ' ' | cut -d ' ' -f2 | xargs)"
    # Not fully removed packages
    packages="${packages} $(dpkg -l 2>/dev/null | grep '^rc' | tr -s ' ' | cut -d ' ' -f2 | xargs)"

    packages="$(echo -n "${packages}" | sed -E 's/^\s+//;s/\s+$//')"
    if [ -n "${packages}" ]; then
        purge_packages ${packages}
    fi
}

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=1
#export DPKG_DEBUG=77777
#export DPKG_MAINTSCRIPT_DEBUG=1

prelease=$(lsb_release --short --codename)
nrelease=$(next_release "${prelease}")

while [ -n "${nrelease}" ]; do
    update_sources
    update_packages
    upgrade_packages

    prelease=$(lsb_release --short --codename)
    nrelease=$(next_release "${prelease}")
done

if [ -z "${next_release}" ]; then
    upgrade_packages
fi

cleanup
clean_orphaned

exit 0
