#!/bin/sh

set -e

: "${K3S_VERSION:=1.23.6+k3s1}"
: "${KUBECTL_VERSION:=1.23.6}"
: "${KUBEFLOW_PIPELINE_VERSION:=1.8.1}"
: "${HELM_VERSION:=3.8.2}"
: "${CRANE_VERSION:=0.8.0}"
: "${JQ_VERSION:=1.6}"
: "${YQ_VERSION:=4.24.5}"

: "${MAKESELF_VERSION:=2.4.5}"
: "${FETCH_VERSION:=0.4.4}"

: "${PACK:=0}"
: "${PACKAGE_COMPRESS:=xz}"
: "${PACKAGE_COMPRESS_LEVEL:=9}"

BUSYBOX_URL="https://github.com/docker-library/busybox/raw/dist-amd64/stable/musl/busybox.tar.xz"
K3S_URL="https://github.com/k3s-io/k3s/releases/download"
KUBECTL_URL="https://dl.k8s.io/release"
KUBEFLOW_PIPELINE_URL="https://github.com/kubeflow/pipelines"
HELM_URL="https://get.helm.sh"
CRANE_URL="https://github.com/google/go-containerregistry/releases/download"
JQ_URL="https://github.com/stedolan/jq/releases/download"
YQ_URL="https://github.com/mikefarah/yq/releases/download"

MLFM_REPO_URL="https://code.siemens.com/api/v4/projects/204619/packages/helm/stable/mlfm"

MAKESELF_URL="https://github.com/megastep/makeself/releases/download"
FETCH_URL="https://github.com/gruntwork-io/fetch/releases/download"

BUILDTMPDIR="$HOME/.cache/mlfm/build"

BINDIR="bin"
MANDIR="manifests"
CHARTDIR="charts"

ARCH=$(uname -m)
OS=$(uname -s)

[ ${EUID:-$(id -u)} -eq 0 ] && SUDO="" || SUDO="$(command -v sudo)"

ensure_makeself() {(
  BINDIR="$1/bin"
  MKSELFDIR="$1/mkself"

  mkdir -p "$BINDIR"
  fetsh \
    "$BINDIR/makeself" \
    "$MAKESELF_URL/release-$MAKESELF_VERSION/makeself-$MAKESELF_VERSION.run"
  make_executable "$BINDIR/makeself"

  [ -d "$MKSELFDIR" ] || {
    mkdir -p "$MKSELFDIR"
    "$BINDIR/makeself" --target "$MKSELFDIR" > /dev/null 2>&1
  }
)}

ensure_fetch() {(
  BINDIR="$1/bin"

  mkdir -p "$BINDIR"
  fetsh "$BINDIR/fetch" "$FETCH_URL/v$FETCH_VERSION/fetch_linux_amd64"
  make_executable "$BINDIR/fetch"
)}

ensure_essentials() {(
  COMMANDS="\
busybox|busybox|alpine:,arch:,centos:,debian:,fedora:,ubuntu:;\
curl|curl|alpine:,arch:,centos:,debian:,fedora:,ubuntu:;\
"
  ensure "$COMMANDS"
  MISSING="$(check "$COMMANDS")"
  [ -z "$MISSING" ] || fatal "Missing $MISSING"
)}

fetch_busybox() {(
  if [ "$FORCE_FETCH" != "0" ] || [ ! -s "$1" ]; then
    log "Fetching busybox"
    BBTMPDIR="$(mktemp -d)"
    curl -Lo "$BBTMPDIR/busybox.tar.xz" "$BUSYBOX_URL" 2>&1 | logv
    tar -xJf "$BBTMPDIR/busybox.tar.xz" -C "$BBTMPDIR" ./bin
    cp "$BBTMPDIR/bin/busybox" "$1"
    rm -rf "$BBTMPDIR"
  else
    log "Found busybox"
  fi
)}

fetch_chart() {(
  CHART="$1/${2##*/}.tgz"
  [ -n "$4" ] && CRED="--username ${4%%:*} --password ${4#*:}"
  if [ "$FORCE_FETCH" != "0" ] || [ ! -s "$CHART" ]; then
    log "Fetching $3 chart"
    mkdir -p "$1"
    TMPDIR="$(mktemp -d)"
    helm pull $CRED -d "$TMPDIR" --repo "${2%/*}" "${2##*/}"
    mv "$TMPDIR/"* "$CHART"
    rm -rf "$TMPDIR"
  else
    log "Found $3 chart"
  fi
)}

setup_base() {(
  BINDIR="$1/bin"
  mkdir -p "$BINDIR"

  # BUSYBOX Binary
  fetch_busybox "$BINDIR/busybox"
  make_executable "$BINDIR/busybox"
  log "Symlinking busybox applets"
  for i in $("$BINDIR/busybox" --list); do ln -sf busybox "$BINDIR/$i"; done

  # K3S Binary
  K3S_ARCH_MAP="x86_64|;arm|-armhf;arm64|-arm64;"
  K3S_ARCH="$(lookup "$K3S_ARCH_MAP" "$ARCH")"
  fetsh "$BINDIR/k3s" "$K3S_URL/v$K3S_VERSION/k3s$K3S_ARCH"
  make_executable "$BINDIR/k3s"

  # K3S Script
  fetsh "$BINDIR/k3s-install.sh" "https://get.k3s.io"
  make_executable "$BINDIR/k3s-install.sh"

  # Kubectl Binary
  fetsh "$BINDIR/kubectl" "$KUBECTL_URL/v$KUBECTL_VERSION/bin/linux/amd64/kubectl"
  make_executable "$BINDIR/kubectl"

  # Helm Binary
  HELM_ARCH_MAP="x86_64|amd64;arm|arm;arm64|arm64;"
  HELM_ARCH="$(lookup "$HELM_ARCH_MAP" "$ARCH")"
  fetch_from_tar \
    "$HELM_URL/helm-v$HELM_VERSION-linux-$HELM_ARCH.tar.gz" \
    "$BINDIR" \
    "linux-$HELM_ARCH/helm|helm;"
  make_executable "$BINDIR/helm"

  # Crane Binary
  CRANE_ARCH_MAP="x86_64|x86_64;"
  CRANE_ARCH="$(lookup "$CRANE_ARCH_MAP" "$ARCH")"
  fetch_from_tar \
    "$CRANE_URL/v$CRANE_VERSION/go-containerregistry_Linux_$CRANE_ARCH.tar.gz" \
    "$BINDIR" \
    "crane;"
  make_executable "$BINDIR/crane"

  # JQ Binary
  JQ_ARCH_MAP="x86_64|64;"
  JQ_ARCH="$(lookup "$JQ_ARCH_MAP" "$ARCH")"
  fetsh "$BINDIR/jq" "$JQ_URL/jq-$JQ_VERSION/jq-linux$JQ_ARCH"
  make_executable "$BINDIR/jq"

  # YQ Binary
  fetsh "$BINDIR/yq" "$YQ_URL/v$YQ_VERSION/yq_linux_amd64"
  make_executable "$BINDIR/yq"
)}

setup_kubeflow() {(
  MANDIR="$1/$MANDIR"

  # Kubeflow Manifests
  if [ "$FORCE_FETCH" != "0" ] || [ ! -d "$MANDIR" ]; then
    ensure_fetch "$BUILDTMPDIR"
    log "Fetching kubeflow manifests"
    mkdir -p "$MANDIR"
    fetch \
      --repo "$KUBEFLOW_PIPELINE_URL" \
      --tag "$KUBEFLOW_PIPELINE_VERSION" \
      --source-path "manifests/kustomize" \
      --progress \
      "$MANDIR" 2>&1 | logv
      [ -d "$MANDIR/base" ] \
        && [ -d "$MANDIR/env/platform-agnostic" ] \
        && [ -d "$MANDIR/env/platform-agnostic-emissary" ] \
        || fatal "Failed to fetch kubeflow manifests"
  else
    log "Found kubeflow manifests"
  fi
)}

setup_mlfm() {(
  CHARTDIR="$1/$CHARTDIR"

  [ -n "$MLFM_REPO_TOKEN" ] || fatal "Need to specify MLFM_REPO_TOKEN"
  fetch_chart "$CHARTDIR" "$MLFM_REPO_URL" "MLFM" "$MLFM_REPO_TOKEN"
)}

pack() {(
  DEST="$1"; shift
  ENTRY="$1"; shift
  MKSELF="$BUILDTMPDIR/mkself/makeself.sh"

  if [ $# -ne 0 ]; then
    ensure "||alpine:tar;||alpine:xz;find||fedora:findutils;"
    ensure_makeself "$BUILDTMPDIR"

    # TODO: Improve cptree or maybe use lntree here
    log "Constructing packing context"
    MIGRATION="$(mktemp -d)"
    find "$@" -type f -exec sh -c 'mkdir -p $(dirname $0)' "$MIGRATION/{}" \;
    find "$@" -type l -exec sh -c 'mkdir -p $(dirname $0)' "$MIGRATION/{}" \;
    find "$@" -type f -exec cp -f --reflink=auto "{}" "$MIGRATION/{}" \;
    find "$@" -type l -exec cp -fP "{}" "$MIGRATION/{}" \;

    if [ "${PACKAGE_PASSWD+x}" = "x" ]; then
      ensure "openssl|openssl|alpine:,arch:,centos:,debian:,fedora:,ubuntu:;"
      log "Packing an encrypted installer"
      "$MKSELF" \
        --ssl-encrypt \
        --ssl-pass-src 'env:PACKAGE_PASSWD' \
        --"$PACKAGE_COMPRESS" \
        --complevel "$PACKAGE_COMPRESS_LEVEL" \
        --threads 0 \
        "$MIGRATION" "$DEST" MLFM "$ENTRY" 2>&1 \
          | logv
    else
      log "Packing an unencrypted installer"
      "$MKSELF" \
        --"$PACKAGE_COMPRESS" \
        --complevel "$PACKAGE_COMPRESS_LEVEL" \
        --threads 0 \
        "$MIGRATION" "$DEST" MLFM "$ENTRY" 2>&1 \
          | logv
    fi

    [ -s "$DEST" ] \
      && log "Packing succeeded of size $(du -h "$DEST" | awk '{print $1}')" \
      || fatal "Packing failed"
    rm -rf "$MIGRATION"
  fi
)}

main() {
  local D1="$1"; shift

  PATH="$BUILDTMPDIR/bin:$PATH:$D1/bin"
  export PATH

  while [ -n "$1" ]; do
    case "$1" in
      -f) shift; FORCE_FETCH=1;;
      -q) shift; QUIET=1; VERBOSE=0;;
      -v) shift; VERBOSE=1; QUIET=0;;
      -vv) shift; VERBOSE=2; QUIET=0;;
      --pack) shift; PACK=1;;
      *) echo "Unrecognized option: $1"; exit 1;;
    esac
  done

  . "$D1/bin/scripts/util.sh"

  ensure_essentials

  setup_base "$D1"
  setup_kubeflow "$D1/components/kubeflow"
  setup_mlfm "$D1/components/mlfm"

  # TODO: Parameterized paths
  [ $PACK -eq 0 ] \
    || pack "./installer" "./install.sh" "bin/" "components/" "install.sh"
}

main "$(dirname "$0")" "$@"
