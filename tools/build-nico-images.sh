#!/bin/bash
# Build NVIDIA Infra Controller (NICo) images from source and push the
# deployable ones to a registry. Run by the upstream-images pipeline
# (.github/workflows/upstream-images.yml), or by hand on an Ubuntu 24.04 host
# with Docker and sudo:
#
#   UPSTREAM_SRC=<infra-controller checkout at the tag> UPSTREAM_REF=v2.3.0 \
#   UPSTREAM_TAG=v2.3.0 UPSTREAM_REGISTRY=docker.io/<user> tools/build-nico-images.sh
#
# Everything is built into a throwaway registry on localhost first (NICo's
# Makefile pushes its build intermediates too); only the deployable images
# are copied to UPSTREAM_REGISTRY, under the names helm-prereqs/setup.sh
# deploys (the Core image as nvmetal-carbide). It mirrors what the
# omerfsen.nico.nico_images role does on the lab's build VM.
set -euo pipefail
: "${UPSTREAM_SRC:?checkout of NICo at the tag}" "${UPSTREAM_REF:?tag}"
: "${UPSTREAM_TAG:=$UPSTREAM_REF}" "${UPSTREAM_REGISTRY:?registry to push to}"
here=$(cd "$(dirname "$0")/.." && pwd)
local_reg=localhost:5000
L=$local_reg/nico

# Images that end up in UPSTREAM_REGISTRY: <name in the local build> <published name>.
deployables=(
  "nico nvmetal-carbide"
  "nico-rest-api nico-rest-api" "nico-rest-workflow nico-rest-workflow"
  "nico-rest-site-manager nico-rest-site-manager" "nico-rest-site-agent nico-rest-site-agent"
  "nico-rest-db nico-rest-db" "nico-rest-cert-manager nico-rest-cert-manager"
  "nico-flow nico-flow" "nico-psm nico-psm" "nico-nsm nico-nsm" "nico-mcp nico-mcp"
  "boot-artifacts-x86_64 boot-artifacts-x86_64"
)
bmc_mock_tag="$UPSTREAM_TAG-nico.1"

# Values the lab's roles pin, read from their defaults (one source of truth).
role_default() { python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[sys.argv[2]])' "$here/roles/$1/defaults/main.yml" "$2"; }
unbound_base=$(role_default nico nico_unbound_base_image)
unbound_package=$(role_default nico nico_unbound_package)
unbound_tag=$(role_default nico nico_unbound_tag)

step() { echo; echo "::group::$*"; }
endstep() { echo "::endgroup::"; }

step "Build host (NICo's manual setup; Docker is already there)"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  build-essential cpio direnv mkosi uidmap curl file fakeroot git sccache \
  protobuf-compiler libopenipmi-dev libudev-dev libboost-dev libgrpc-dev \
  libprotobuf-dev libssl-dev libtss2-dev kea-dev systemd-boot systemd-ukify \
  jq zip skopeo python3-yaml
command -v rustup >/dev/null || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
command -v cargo-make >/dev/null || cargo install --locked cargo-make
echo kernel.apparmor_restrict_unprivileged_userns=0 | sudo tee /etc/sysctl.d/99-userns.conf >/dev/null
sudo sysctl --system >/dev/null
cd "$UPSTREAM_SRC"
git submodule update --init --recursive
direnv allow .
endstep

step "Runner"
echo "CPUs: $(nproc)"; free -h; df -h /
endstep

step "Local registry for the build"
docker run -d --rm --name nico-build-registry -p 5000:5000 \
  docker.io/library/registry:3.1.2@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3 >/dev/null
for _ in $(seq 1 30); do curl -fsS http://$local_reg/v2/ >/dev/null 2>&1 && break; sleep 1; done
endstep

step "make images (Core + REST, amd64)"
direnv exec . make images IMAGE_REGISTRY=$L IMAGE_TAG="$UPSTREAM_TAG" NICO_ARCHES=amd64
endstep

# The Rust builds leave tens of GB in Docker's build cache (cargo targets,
# sccache); the images are already in the local registry. Without this the
# boot-artifacts build (mkosi) ran out of disk on a hosted runner.
step "Free the build cache"
df -h /
docker builder prune -af >/dev/null
docker image prune -af >/dev/null
docker system df
df -h /
endstep

step "make images-boot-artifacts (amd64)"
direnv exec . make images-boot-artifacts IMAGE_REGISTRY=$L IMAGE_TAG="$UPSTREAM_TAG" BOOT_ARTIFACTS_ARCHES=amd64
endstep

step "bmc-mock with the lab's patches"
patches="$here/roles/nico_images/files/patches/$UPSTREAM_REF"
wt=$(mktemp -d)/bmc-mock-src
git worktree add --detach "$wt" HEAD
for p in "$patches"/*.patch; do [ -e "$p" ] && git -C "$wt" apply --verbose "$p"; done
docker build -f "$wt/crates/bmc-mock/Dockerfile" --build-arg VERSION="$bmc_mock_tag" \
  --build-arg CI_COMMIT_SHORT_SHA="$(git rev-parse --short=8 HEAD)" -t "$L/bmc-mock:$bmc_mock_tag" "$wt"
docker push -q "$L/bmc-mock:$bmc_mock_tag"
endstep

step "unbound for NICo's unbound chart"
ub=$(mktemp -d)
printf 'FROM %s\nRUN apk add --no-cache %s && mkdir -p /etc/unbound/local.conf.d\n' "$unbound_base" "$unbound_package" > "$ub/Dockerfile"
docker build -t "$L/unbound:$unbound_tag" "$ub"
docker push -q "$L/unbound:$unbound_tag"
endstep

step "Copy the deployable images to $UPSTREAM_REGISTRY"
copy() {  # copy <local name:tag> <published name:tag>
  skopeo copy --all --quiet --src-tls-verify=false "docker://$L/$1" "docker://$UPSTREAM_REGISTRY/$2"
  echo "pushed $UPSTREAM_REGISTRY/$2"
}
for pair in "${deployables[@]}"; do
  read -r from to <<<"$pair"
  copy "$from:$UPSTREAM_TAG" "$to:$UPSTREAM_TAG"
done
copy "bmc-mock:$bmc_mock_tag" "bmc-mock:$bmc_mock_tag"
copy "unbound:$unbound_tag" "unbound:$unbound_tag"
endstep

{
  echo "### NICo $UPSTREAM_REF images in $UPSTREAM_REGISTRY"
  for pair in "${deployables[@]}"; do read -r _ to <<<"$pair"; echo "- \`$to:$UPSTREAM_TAG\`"; done
  echo "- \`bmc-mock:$bmc_mock_tag\` (patched)"
  echo "- \`unbound:$unbound_tag\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
