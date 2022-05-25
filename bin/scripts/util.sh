#!/bin/sh

[ "x${_UTIL_IMPORT_GUARD+x}" != "xx" ] && _UTIL_IMPORT_GUARD=1 || return 0

: "${FORCE_FETCH:=0}"
: "${FORCE_INSTALL:=0}"
: "${QUIET:=0}"
: "${VERBOSE:=0}"

[ "x${SUDO+x}" = "xx" ] || {
  [ ${EUID:-$(id -u)} -eq 0 ] && SUDO="" || SUDO="$(command -v sudo)"
}

packmans="\
apk||add;\
apt|update|install -y;\
dnf||install -y;\
pacman||-Sy --needed --noconfirm;\
yum||install -y;\
zypper||install -y;\
"

_foreach_packman() {
  if [ "x$2" != "x" ]; then
    local _i _j _PACKMAN _UPDATE _INSTALL
    _i="$1"; while [ "$_i" ]; do _j="${_i%%;*}"; _i="${_i#*;}"
      _PACKMAN="${_j%%|*}"; _j="${_j#*|}"
      _UPDATE="${_j%%|*}"; _j="${_j#*|}"
      _INSTALL="${_j%%|*}"
      ("$2" "$_PACKMAN" "$_UPDATE" "$_INSTALL") || return 0
    done
  fi
}

_foreach_command() {
  if [ "x$2" != "x" ]; then
    local _i _j _COMMAND _DEFAULT _PACKAGES
    _i="$1"; while [ "$_i" ]; do _j="${_i%%;*}"; _i="${_i#*;}"
      _COMMAND="${_j%%|*}"; _j="${_j#*|}"
      _DEFAULT="${_j%%|*}"; _j="${_j#*|}"
      _PACKAGES="${_j%%|*}"
      ("$2" "$_COMMAND" "$_DEFAULT" "$_PACKAGES") || return 0
    done
  fi
}

_foreach_package() {
  if [ "x$2" != "x" ]; then
    local _i _j _ID _PACKAGE
    _i="$1"; while [ "$_i" ]; do
      _j="${_i%%,*}"; [ "$_i" = "$_j" ] && _i="" || _i="${_i#*,}"
      _ID="${_j%%:*}"; _j="${_j#*:}"
      _PACKAGE="${_j%%:*}"
      ("$2" "$_ID" "$_PACKAGE") || return 0
    done
  fi
}

_find_packman() {(
  if [ "x$2" != "x" ]; then
    local _CB="$2"
    _filter_packmans() {
      local _PACKMAN="$(command -v "$1")"
      [ "$_PACKMAN" ] || return 0
      ("$_CB" "$_PACKMAN" "$2" "$3")
      return 1
    }
    _foreach_packman "$1" _filter_packmans
  fi
)}

_find_missing_commands() {(
  if [ "x$2" != "x" ]; then
    local _CB="$2"
    _filter_commands() { [ "$(command -v "$1")" ] || ("$_CB" "$1"); }
    _foreach_command "$1" _filter_commands
  fi
)}

_find_missing_packages() {(
  if [ "x$2" != "x" ]; then
    local _CB="$2"
    [ -r /etc/os-release ] && . /etc/os-release
    _filter_commands() {
      if [ ! "$(command -v "$1")" ]; then
        local _DEFAULT="$2"
        _filter_packages() {
          [ "$1" = "$ID" ] || return 0
          ("$_CB" "${2:-$_DEFAULT}")
          return 1
        }
        _foreach_package "$3" _filter_packages
      fi
    }
    _foreach_command "$1" _filter_commands
  fi
)}

_check() { [ "x$1" = "x" ] || _find_missing_commands "$1" echo; }
check() { _check "${1:-$(cat)}"; }

_ensure() {(
  if [ "x$2" != "x" ]; then
    local _COMMANDS="$2"
    _on_find_packman() {
      local _PACKAGES="$(_find_missing_packages "$_COMMANDS" echo)"
      if [ "x$_PACKAGES" != "x" ]; then
        log "Installing $_PACKAGES"
        [ "x$2" != "x" ] && $SUDO $1 $2 2>&1 | logv
        $SUDO $1 $3 $_PACKAGES 2>&1 | logv
      fi
    }
    _find_packman "$1" _on_find_packman
  fi
)}

ensure() { _ensure "$packmans" "${1:-$(cat)}"; }

lookup() {
  local _i _j
  _i="$1"; while [ "$_i" ]; do _j="${_i%%;*}"; _i="${_i#*;}"
    if [ "${_j%%|*}" = "$2" ]; then
      _j="${_j#*|}"; _j="${_j%%|*}"
      echo "$_j"
      return 0
    fi
  done
  return 1
}

fetsh() {
  if [ $FORCE_FETCH -ne 0 ] || [ ! -s "$1" ]; then
    log "Fetching ${1##*/}"
    curl -Lo "$1" "$2" 2>&1 | logv
  else
    log "Found ${1##*/}"
  fi
}

fetch_from_tar() {
  local MISSING="$(
    printf "$3" \
      | tr ';' '\0' \
      | xargs -0n1 sh -c \
        '[ $0 -eq 0 -a -f "$1/${2##*|}" ] || printf "$2;"' "$FORCE_FETCH" "$2"
  )"
  local MEMBERS="$(printf "$MISSING" | awk 'BEGIN{RS=";";FS="|"}{print$1}')"

  [ "x$MISSING" = "x" ] && log "Found in ${1##*/}" || {
    log "Fetching from ${1##*/}"
    echo "$1" | grep -qE ".tar$|.gz$|.xz$|.bz2$" || return 1
    local C="$(lookup "tar|;gz|z;xz|J;bz2|j;" "${1##*.}")"
    local TMPDIR="$(mktemp -d)"
    {
      curl -L "$1" | tar -x${C}f - -C "$TMPDIR" $MEMBERS
      printf "$MISSING" | tr ';' '\0' | xargs -0n1 sh -c \
        'mv "$0/${2%%|*}" "$1/${2##*|}"' "$TMPDIR" "$2"
    } 2>&1 | logv
    rm -rf "$TMPDIR"
  }
}

make_executable() {
  if [ ! -x "$1" ]; then
    log "Setting ${1##*/} permissions"
    chmod +x "$1"
  fi
}

lntree() {
  [ $# -eq 2 ] || return 1
  [ -d "$1" ] || fatal "Couldn't find $1"

  [ ! -d "$2" ] && $SUDO mkdir -p "$2"
  logv "Copying $1 to $2"
  $SUDO find "$1" -links 2 -type d \
    | sed -r "s|^$1/?||" \
    | tr '\n' '\0' \
    | $SUDO xargs -0 -I{} -P0 mkdir -p "$2/{}"

  $SUDO find "$2" -type d -exec chmod 755 "{}" +

  $SUDO find "$1" -type f \
    | sed -r "s|^$1/?||" \
    | tr '\n' '\0' \
    | $SUDO xargs -0 -I{} -P0 ln -f "$1/{}" "$2/{}"

  $SUDO find "$1" -type l \
    | sed -r "s|^$1/?||" \
    | tr '\n' '\0' \
    | $SUDO xargs -0 -I{} -P0 cp -fP "$1/{}" "$2/{}"
}

wait_on_port() {
  logv "Waiting for $1 on port $2"
  timeout "$4" sh -c 'until nc -z $0 $1; do sleep $2; done' "$1" "$2" "$3"
}

ensure_fqdn() {
  local S="[[:blank:]]"
  local NS="[^[:blank:]]"
  grep -Eqx "$1$S+$2" /etc/hosts && logv "Found $3 FQDN" || {
    logv "Installing $3 FQDN"
    $SUDO sed -ri "/^$NS+$S+$2$/d;s/($S+)$2($S|$)/\1/g" /etc/hosts
    printf '%s\t%s\n' "$1" "$2" | $SUDO tee -a /etc/hosts > /dev/null
  }
}

log() {
  if [ $QUIET -ne 0 ]; then
    [ $# -ne 0 ] || cat > /dev/null
  else
    [ $# -ne 0 ] && echo "+ $*" || sed 's|^|+ |'
  fi
}

logv() {
  if [ $QUIET -ne 0 ] || [ $VERBOSE -lt 1 ]; then
    [ $# -ne 0 ] || cat > /dev/null
  else
    [ $# -ne 0 ] && echo "++ $*" || sed 's|^|++ |'
  fi
}

logvv() {
  if [ $QUIET -ne 0 ] || [ $VERBOSE -lt 2 ]; then
    [ $# -ne 0 ] || cat > /dev/null
  else
    [ $# -ne 0 ] && echo "+++ $*" || sed 's|^|+++ |'
  fi
}

fatal() {
  if [ $QUIET -ne 0 ]; then
    [ $# -ne 0 ] || cat > /dev/null
  else
    [ $# -ne 0 ] && echo "- $*" || sed 's|^|- |'
  fi
  return 1
}
