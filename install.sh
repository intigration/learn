#!bin/sh

set -e

: "${MLFM_HOME:="$HOME/.mlfm"}"

: "${CLUSTER_NAME:="default"}"
: "${NAMESPACE:="mlfm"}"
: "${EMBEDDED_K3S:=1}"
: "${DOCKER:=0}"
: "${INGRESS:=1}"

[ "x${SUDO+x}" = "xx" ] || {
  [ ${EUID:-$(id -u)} -eq 0 ] && SUDO="" || SUDO="$(command -v sudo)"
}

PATH="$PWD/bin:$PATH"
export PATH

main() {
  local D1="$1"; shift
  local D2="$1"; shift

  . "$D1/bin/scripts/util.sh"

  [ "x$DEPLOY_KEY_USERNAME" != "x" ] || fatal "Need to specify DEPLOY_KEY_USERNAME"
  [ "x$DEPLOY_KEY_PASSWORD" != "x" ] || fatal "Need to specify DEPLOY_KEY_PASSWORD"

  mkdir -p "$D2"
  chmod 755 "$D2"

  log "Installing installer base"
  cp -r "$D1/bin" "$D2"


  log "Installing components"
  cp -r "$D1/components" "$D2"


  log "Installing mlfman"
  cat << EOF | $SUDO tee "/usr/local/bin/mlfman" >/dev/null
: "\${MLFM_HOME:="$(readlink -f "$D2")"}"
export MLFM_HOME
"\$MLFM_HOME/bin/mlfman" "\$@"
EOF
  $SUDO chmod 755 "/usr/local/bin/mlfman"


  log "Writing installation env"
  cat << EOF | tee "$D2/.env" >/dev/null
CLUSTER_NAME="$CLUSTER_NAME"
NAMESPACE="$NAMESPACE"
EMBEDDED_K3S=$EMBEDDED_K3S
DOCKER=$DOCKER
INGRESS=$INGRESS
DEPLOY_KEY_USERNAME=$DEPLOY_KEY_USERNAME
DEPLOY_KEY_PASSWORD=$DEPLOY_KEY_PASSWORD
EOF

  [ $EMBEDDED_K3S -ne 0 ] || {
    echo 'KUBECONFIG="'"${KUBECONFIG:="$HOME/.kube/config"}"'"' >> "$D2/.env"
  }

  [ $DOCKER -eq 0 ] || {
    echo 'INSTALL_K3S_EXEC="--docker"' >> "$D2/.env"
  }

  "$D2/bin/sh" "$D2/bin/mlfman" start "$@"
}

main "$(dirname "$0")" "$MLFM_HOME" "$@"
