#!/bin/bash
#
# Copyright 2026 The Rook Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# DRBD Setup Script for Two-Node OpenShift Cluster, Safe to re-run.
#
# CLI overrides env for: --resource-name, --drbd-device, --port, --force-mkfs, --image-registry-storage-class.
# Use -s/--show-config to print effective settings without changing the cluster (optional backing paths for full preview).
#
# Prerequisites:
#   - Nodes can pull ${DRBD_IMAGE}; ${DRBD_PORT}/tcp open between nodes.
#   - For durable in-cluster builds: set IMAGE_REGISTRY_STORAGE_CLASS or pass --image-registry-storage-class.
#
set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }
msg() { echo "DRBD: $*"; }

IMAGE_REGISTRY_STORAGE_CLASS="${IMAGE_REGISTRY_STORAGE_CLASS:-}"         # StorageClass for image-registry PVC; unset means emptyDir is used
IMAGE_REGISTRY_PVC_SIZE="${IMAGE_REGISTRY_PVC_SIZE:-20Gi}"               # PVC request size when using StorageClass

# TODO: bump default image tag when a new one is published.
DRBD_IMAGE="${DRBD_IMAGE:-quay.io/rhceph-dev/odf4-odf-drbd-rhel9:v4.22}" # ODF DRBD image (drbdadm + sources)
# TODO: bump when tarball inside the image changes.
DRBD_VERSION="${DRBD_VERSION:-9.2.15}"                                   # Must match DRBD source version in DRBD_IMAGE

DRBD_RESOURCE_NAME="${DRBD_RESOURCE_NAME:-r0}"                   # DRBD resource name (e.g. r0)
DRBD_DEVICE="${DRBD_DEVICE:-/dev/drbd0}"                         # DRBD block device path on nodes (e.g. /dev/drbd0)
DRBD_PORT="${DRBD_PORT:-7794}"                                   # DRBD replication TCP port (e.g. 7794)

AUTOSTART_DAEMONSET_NAME="${AUTOSTART_DAEMONSET_NAME:-drbd-autostart}" # DRBD auto-start DaemonSet name
AUTOSTART_DAEMONSET_NS="${AUTOSTART_DAEMONSET_NS:-openshift-kmm}"      # DRBD auto-start DaemonSet namespace

OUTPUT_CM_NS="${OUTPUT_CM_NS:-openshift-storage}"                # Namespace for setup summary ConfigMap
OUTPUT_CM_NAME="${OUTPUT_CM_NAME:-drbd-configure}"               # Name of setup summary ConfigMap

FORCE_MKFS="${FORCE_MKFS:-0}"                                    # 1 = mkfs.xfs -f even if blkid sees a signature (destructive)

# Approximate wait ceilings in this script: KMM operator ~5m (60×5s); DRBD modules ~10m (60×10s);
# initial sync ~60m (120×30s); autostart DaemonSet ~5m (60×5s).

# User input: backing paths (e.g. /dev/sdb). --drbd-backing-path = same on both nodes; else --drbd-backing-path-node0/1.
BACKING_PATH=""
BACKING_PATH_NODE0=""
BACKING_PATH_NODE1=""
DISK_RESOLVED_NODE0=""
DISK_RESOLVED_NODE1=""

LIST_DEVICES_ONLY=0
SHOW_CONFIG_ONLY=0

# Node info (populated by detect_nodes)
NODE_0=""
NODE_1=""
NODE_0_IP=""
NODE_1_IP=""

#--- Functions ---#

usage() {
    cat <<USAGE
Usage:
  $0 --drbd-backing-path <path> [options]    (short: -d <path>)
  $0 --drbd-backing-path-node0 <p0> --drbd-backing-path-node1 <p1> [options]    (short: -d0 <p0> -d1 <p1>)
  $0 --list-devices    (short: -l)
  $0 --show-config [options]    (short: -s; omit backing paths for defaults only)

Backing path (e.g. /dev/sdb; use lsblk PATH from --list-devices; ROTA must be 0 / SSD-class):
  -d, --drbd-backing-path PATH        Same size & path on both nodes (e.g. /dev/sdb)
  -d0, --drbd-backing-path-node0 PATH   Path on the first sorted node.
  -d1, --drbd-backing-path-node1 PATH   Path on the second sorted node. Must match size of the first node's backing path.

Discovery:
  -l, --list-devices         List block devices on each node (NAME, PATH, SIZE, ROTA, TYPE, FSTYPE). Use PATH with the flags above.
  -s, --show-config          Print effective settings only; does not change the cluster. Without backing paths: defaults from
                             env/CLI. With -d / --drbd-backing-path (or per-node paths): requires oc login; shows nodes, disk checks,
                             /dev/disk/by-id resolution, and install-related settings.

Options:
  --resource-name NAME       DRBD resource name (default ${DRBD_RESOURCE_NAME}; env DRBD_RESOURCE_NAME).
  --drbd-device PATH         DRBD block device node path (default ${DRBD_DEVICE}; env DRBD_DEVICE).
  --port N                   DRBD TCP replication port (default ${DRBD_PORT}; env DRBD_PORT).
  --image-registry-storage-class NAME
                             Use this StorageClass for the OpenShift image registry PVC (size ${IMAGE_REGISTRY_PVC_SIZE};
                             override with env IMAGE_REGISTRY_PVC_SIZE). If omitted, registry uses emptyDir unless
                             IMAGE_REGISTRY_STORAGE_CLASS is set in the environment.
  --force-mkfs               Run mkfs.xfs -f on the DRBD device even if blkid sees a signature (destructive).

General:
  -h, --help                 Show this help and exit.

Environment:
  Defaults are documented on each assignment near the top of this script (after set -euo pipefail).
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d0|--drbd-backing-path-node0)
                [[ -n "${2:-}" ]] || die "-d0/--drbd-backing-path-node0 requires a path (e.g. /dev/sdb)"
                BACKING_PATH_NODE0="$2"
                shift 2
                ;;
            -d1|--drbd-backing-path-node1)
                [[ -n "${2:-}" ]] || die "-d1/--drbd-backing-path-node1 requires a path (e.g. /dev/sdb)"
                BACKING_PATH_NODE1="$2"
                shift 2
                ;;
            -d|--drbd-backing-path)
                [[ -n "${2:-}" ]] || die "-d/--drbd-backing-path requires a path (e.g. /dev/sdb)"
                BACKING_PATH="$2"
                shift 2
                ;;
            -l|--list-devices)
                LIST_DEVICES_ONLY=1
                shift
                ;;
            -s|--show-config)
                SHOW_CONFIG_ONLY=1
                shift
                ;;
            --resource-name)
                [[ -n "${2:-}" ]] || die "--resource-name requires a value"
                DRBD_RESOURCE_NAME="$2"
                shift 2
                ;;
            --drbd-device)
                [[ -n "${2:-}" ]] || die "--drbd-device requires a value"
                DRBD_DEVICE="$2"
                shift 2
                ;;
            --port)
                [[ -n "${2:-}" ]] || die "--port requires a value"
                DRBD_PORT="$2"
                shift 2
                ;;
            --image-registry-storage-class)
                [[ -n "${2:-}" ]] || die "--image-registry-storage-class requires a value"
                IMAGE_REGISTRY_STORAGE_CLASS="$2"
                shift 2
                ;;
            --force-mkfs)
                FORCE_MKFS=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
    done

    if [[ "$LIST_DEVICES_ONLY" -eq 1 && "$SHOW_CONFIG_ONLY" -eq 1 ]]; then
        die "Use either -l/--list-devices or -s/--show-config, not both"
    fi

    if [[ "$LIST_DEVICES_ONLY" -eq 1 ]]; then
        return 0
    fi

    if [[ "$SHOW_CONFIG_ONLY" -eq 1 ]]; then
        if [[ -n "$BACKING_PATH" && ( -n "$BACKING_PATH_NODE0" || -n "$BACKING_PATH_NODE1" ) ]]; then
            die "Use either -d/--drbd-backing-path or both -d0/-d1 (node0/node1 paths), not both"
        fi
        if [[ -n "$BACKING_PATH_NODE0" || -n "$BACKING_PATH_NODE1" ]]; then
            [[ -n "$BACKING_PATH_NODE0" && -n "$BACKING_PATH_NODE1" ]] || die "Both -d0/--drbd-backing-path-node0 and -d1/--drbd-backing-path-node1 are required"
        fi
        return 0
    fi

    if [[ -n "$BACKING_PATH" && ( -n "$BACKING_PATH_NODE0" || -n "$BACKING_PATH_NODE1" ) ]]; then
        die "Use either -d/--drbd-backing-path or both -d0/-d1 (node0/node1 paths), not both"
    fi
    if [[ -n "$BACKING_PATH_NODE0" || -n "$BACKING_PATH_NODE1" ]]; then
        [[ -n "$BACKING_PATH_NODE0" && -n "$BACKING_PATH_NODE1" ]] || die "Both -d0/--drbd-backing-path-node0 and -d1/--drbd-backing-path-node1 are required"
    fi
    if [[ -z "$BACKING_PATH" && -z "$BACKING_PATH_NODE0" ]]; then
        die "Specify backing path(s): -d/--drbd-backing-path, or -d0/-d1 (node0/node1), or -l/--list-devices (see --help)"
    fi
}

# OpenShift login, two-node cluster, and TNF control-plane topology (DualReplica).
check_prerequisites() {
    oc whoami &>/dev/null || die "not logged into OpenShift (oc whoami)"

    local node_count topology
    node_count=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "$node_count" -eq 2 ]] || die "expected 2 nodes for TNF, found $node_count"

    topology=$(oc get infrastructure cluster -o jsonpath='{.status.controlPlaneTopology}' 2>/dev/null || true)
    [[ -n "$topology" ]] || die "could not read infrastructure CR"
    [[ "$topology" == "DualReplica" ]] || die "expected status.controlPlaneTopology DualReplica (two-node control plane), got '${topology}'"
}

detect_nodes() {
    local nodes_sorted
    nodes_sorted=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
    NODE_0=$(printf '%s\n' "$nodes_sorted" | head -n 1)
    NODE_1=$(printf '%s\n' "$nodes_sorted" | head -n 2 | tail -n 1)
    [[ -n "$NODE_0" && -n "$NODE_1" ]] || die "could not resolve two node names"

    NODE_0_IP=$(oc get node "$NODE_0" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    NODE_1_IP=$(oc get node "$NODE_1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    [[ -n "$NODE_0_IP" && -n "$NODE_1_IP" ]] || die "could not read InternalIP (NODE_0=$NODE_0 NODE_1=$NODE_1)"
}

list_devices() {
    echo "=== Block devices (node0=$NODE_0, node1=$NODE_1) ==="
    echo "Use the PATH column (e.g. -d /dev/sdb or -d0 / -d1 per-node paths)."
    echo ""
    for n in "$NODE_0" "$NODE_1"; do
        echo "--- $n ---"
        if ! oc --request-timeout=120s debug -q "node/$n" -- chroot /host lsblk -o NAME,PATH,SIZE,ROTA,TYPE,FSTYPE; then
            echo "  Could not list block devices on $n (oc debug failed). Check cluster access, then re-run: $0 -l" >&2
        fi
        echo ""
    done
    echo "Same path on both nodes: -d <path>  (or --drbd-backing-path)"
    echo "Different paths (same size): -d0 <path> -d1 <path>"
}

# Map user device path -> stable disk by-id symlink for DRBD config on that node.
resolve_disk_path_on_node() {
    local node="$1" device_path="$2"
    oc debug -q "node/$node" -- chroot /host env "DRBD_BLOCK_DEV=${device_path}" bash -c '
CANON=$(readlink -f "$DRBD_BLOCK_DEV" 2>/dev/null || echo "$DRBD_BLOCK_DEV")
for id in /dev/disk/by-id/*; do
  [[ -e "$id" ]] || continue
  if [[ "$(readlink -f "$id" 2>/dev/null)" == "$CANON" ]]; then echo "$id"; fi
done | sort -u | head -n 1
' 2>/dev/null | tail -n 1
}

print_config() {
    echo ""
    msg "Configuration"
    local _lw=18
    printf '  %-*s %s\n' "$_lw" "Nodes:" "$NODE_0 ($NODE_0_IP), $NODE_1 ($NODE_1_IP)"
    if [[ -n "$BACKING_PATH" ]]; then
        printf '  %-*s %s (same path on both nodes)\n' "$_lw" "Backing device:" "$BACKING_PATH"
    else
        printf '  %-*s %s\n' "$_lw" "Backing devices:" "per-node paths"
        printf '  %-*s %s: %s\n' "$_lw" "" "$NODE_0" "$BACKING_PATH_NODE0"
        printf '  %-*s %s: %s\n' "$_lw" "" "$NODE_1" "$BACKING_PATH_NODE1"
    fi
    printf '  %-*s %s\n' "$_lw" "DRBD Resource:" "$DRBD_RESOURCE_NAME"
    printf '  %-*s %s\n' "$_lw" "DRBD Device:" "$DRBD_DEVICE"
    printf '  %-*s %s\n' "$_lw" "DRBD Port:" "$DRBD_PORT"
    echo ""
}

show_config_defaults_only() {
    echo ""
    msg "Configuration preview (defaults / env / CLI only — cluster not consulted)"
    local w=38 reg_hint
    if [[ -n "$IMAGE_REGISTRY_STORAGE_CLASS" ]]; then
        reg_hint="PVC (${IMAGE_REGISTRY_STORAGE_CLASS}, ${IMAGE_REGISTRY_PVC_SIZE})"
    else
        reg_hint="emptyDir (set --image-registry-storage-class for PVC)"
    fi
    printf '  %-*s %s\n' "$w" "DRBD_RESOURCE_NAME" "$DRBD_RESOURCE_NAME"
    printf '  %-*s %s\n' "$w" "DRBD_DEVICE" "$DRBD_DEVICE"
    printf '  %-*s %s\n' "$w" "DRBD_PORT" "$DRBD_PORT"
    printf '  %-*s %s\n' "$w" "DRBD_VERSION" "$DRBD_VERSION"
    printf '  %-*s %s\n' "$w" "DRBD_IMAGE" "$DRBD_IMAGE"
    printf '  %-*s %s\n' "$w" "FORCE_MKFS" "$FORCE_MKFS (1 = mkfs.xfs -f)"
    printf '  %-*s %s\n' "$w" "Image registry storage" "$reg_hint"
    printf '  %-*s %s\n' "$w" "KMM / Module namespace" "openshift-kmm (operator Subscription + Module drbd-kmod)"
    printf '  %-*s %s\n' "$w" "DRBD Auto-start DaemonSet" "${AUTOSTART_DAEMONSET_NAME} in ${AUTOSTART_DAEMONSET_NS}"
    printf '  %-*s %s\n' "$w" "Setup summary ConfigMap" "${OUTPUT_CM_NAME} in ${OUTPUT_CM_NS}"
    if [[ -n "$BACKING_PATH" ]]; then
        printf '  %-*s %s\n' "$w" "Backing (both nodes)" "$BACKING_PATH"
    elif [[ -n "$BACKING_PATH_NODE0" ]]; then
        printf '  %-*s %s\n' "$w" "Backing node0 / node1" "$BACKING_PATH_NODE0 / $BACKING_PATH_NODE1"
    else
        printf '  %-*s %s\n' "$w" "Backing paths" "(not set — add -d/--drbd-backing-path for a full preview)"
    fi
    echo ""
    echo "  Full cluster preview:  oc login ... && $0 -s -d <path>   (or --show-config --drbd-backing-path)"
    echo ""
}

# After detect_nodes + validate_and_resolve_disks (same checks as setup; no mutations beyond host reads).
show_config_cluster_preview() {
    echo ""
    msg "Configuration preview (no cluster changes will be applied)"
    print_config
    validate_and_resolve_disks
    echo ""
    msg "Installation / Kubernetes settings"
    local w=38 reg_hint
    if [[ -n "$IMAGE_REGISTRY_STORAGE_CLASS" ]]; then
        reg_hint="new registry PVC: class=${IMAGE_REGISTRY_STORAGE_CLASS}, size=${IMAGE_REGISTRY_PVC_SIZE}"
    else
        reg_hint="registry: emptyDir if this script configures it (or set IMAGE_REGISTRY_STORAGE_CLASS)"
    fi
    printf '  %-*s %s\n' "$w" "DRBD_IMAGE (KMM build + drbdctl)" "$DRBD_IMAGE"
    printf '  %-*s %s\n' "$w" "DRBD_VERSION (source tarball)" "$DRBD_VERSION"
    printf '  %-*s %s\n' "$w" "Image registry" "$reg_hint"
    printf '  %-*s %s\n' "$w" "Trusted registry CA ConfigMap" "drbd-setup-internal-registry-ca (openshift-config) if needed for pushes"
    printf '  %-*s %s\n' "$w" "KMM Module" "drbd-kmod in openshift-kmm"
    printf '  %-*s %s\n' "$w" "Autostart DaemonSet" "${AUTOSTART_DAEMONSET_NAME} in ${AUTOSTART_DAEMONSET_NS}"
    printf '  %-*s %s\n' "$w" "Summary ConfigMap" "${OUTPUT_CM_NAME} in ${OUTPUT_CM_NS}"
    printf '  %-*s %s\n' "$w" "FORCE_MKFS" "$FORCE_MKFS"
    echo ""
    msg "Next: run without -s/--show-config to apply."
    echo ""
}

_lsblk_one_line() {
    local node="$1" device_path="$2"
    oc debug -q "node/$node" -- chroot /host lsblk -ndo SIZE,RO,ROTA "$device_path" 2>/dev/null | tr -s ' ' | head -1
}

validate_and_resolve_disks() {
    local p0 p1 row0 row1 size0 ro0 rota0 size1 ro1 rota1
    if [[ -n "$BACKING_PATH" ]]; then
        p0="$BACKING_PATH"
        p1="$BACKING_PATH"
    else
        p0="$BACKING_PATH_NODE0"
        p1="$BACKING_PATH_NODE1"
    fi

    msg "Checking backing device paths..."
    row0=$(_lsblk_one_line "$NODE_0" "$p0")
    row1=$(_lsblk_one_line "$NODE_1" "$p1")
    [[ -n "$row0" ]] || die "device path $p0 not found on $NODE_0"
    [[ -n "$row1" ]] || die "device path $p1 not found on $NODE_1"

    read -r size0 ro0 rota0 <<<"$row0"
    read -r size1 ro1 rota1 <<<"$row1"
    [[ "$ro0" == "0" ]] || die "device path $p0 on $NODE_0 is read-only"
    [[ "$ro1" == "0" ]] || die "device path $p1 on $NODE_1 is read-only"
    [[ "$rota0" == "0" ]] || die "device path $p0 on $NODE_0 must be non-rotational (SSD/NVMe; lsblk ROTA 0), not rotational HDD (ROTA=${rota0:-?})"
    [[ "$rota1" == "0" ]] || die "device path $p1 on $NODE_1 must be non-rotational (SSD/NVMe; lsblk ROTA 0), not rotational HDD (ROTA=${rota1:-?})"
    [[ "$size0" == "$size1" ]] || die "backing device path size mismatch: $NODE_0 $size0 vs $NODE_1 $size1"

    echo "  $NODE_0: $p0  $size0"
    echo "  $NODE_1: $p1  $size1"
    msg "Backing device paths OK."

    msg "Resolving device paths to /dev/disk/by-id for DRBD config"
    DISK_RESOLVED_NODE0=$(resolve_disk_path_on_node "$NODE_0" "$p0")
    DISK_RESOLVED_NODE1=$(resolve_disk_path_on_node "$NODE_1" "$p1")
    [[ -n "$DISK_RESOLVED_NODE0" ]] || die "no /dev/disk/by-id symlink for device path $p0 on $NODE_0"
    [[ -n "$DISK_RESOLVED_NODE1" ]] || die "no /dev/disk/by-id symlink for device path $p1 on $NODE_1"
    echo "  $NODE_0: $p0  ->  $DISK_RESOLVED_NODE0"
    echo "  $NODE_1: $p1  ->  $DISK_RESOLVED_NODE1"
}

setup_kmm_operator() {
    if oc get csv -n openshift-kmm 2>/dev/null | grep -q Succeeded; then
        msg "KMM (Kernel Module Management) operator is already installed."
        return 0
    fi

    msg "Installing KMM (Kernel Module Management) operator..."
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kmm
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kernel-module-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    msg "Waiting for KMM operator to become ready (up to ~5 min)..."
    local i
    for i in $(seq 1 60); do
        if oc get csv -n openshift-kmm 2>/dev/null | grep -q Succeeded; then
            msg "KMM operator is ready."
            return 0
        fi
        [[ "$i" -eq 60 ]] && die "KMM operator not ready after 5 minutes"
        sleep 5
    done
}

# Pushes use HTTPS; without additionalTrustedCA, oc registry login/push fails (unknown CA). We store
# openshift-service-ca.crt in a ConfigMap and reference it from image.config (only if no other CM is set).
ensure_internal_registry_trusted_ca() {
    local cm_name=drbd-setup-internal-registry-ca
    local regkey='image-registry.openshift-image-registry.svc..5000'
    local cafile curfile existing changed=0

    cafile=$(mktemp)
    curfile=$(mktemp)
    trap 'rm -f "$cafile" "$curfile"' EXIT

    if ! oc get configmap openshift-service-ca.crt -n openshift-config \
        -o go-template='{{index .data "service-ca.crt"}}' >"$cafile"; then
        die "could not read openshift-service-ca.crt ConfigMap"
    fi
    grep -q "BEGIN CERTIFICATE" "$cafile" || die "invalid service CA in openshift-service-ca.crt"

    existing=$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.additionalTrustedCA.name}' 2>/dev/null || true)
    [[ -n "$existing" && "$existing" != "$cm_name" ]] &&
        die "additionalTrustedCA is '${existing}'; this script only manages '${cm_name}'. Add key ${regkey} there or use ${cm_name}."

    if oc get configmap "$cm_name" -n openshift-config -o name &>/dev/null; then
        oc get configmap "$cm_name" -n openshift-config \
            -o go-template="{{index .data \"${regkey}\"}}" >"$curfile" 2>/dev/null || : >"$curfile"
        if diff -q "$cafile" "$curfile" &>/dev/null; then
            trap - EXIT
            rm -f "$cafile" "$curfile"
            return 0
        fi
        changed=1
    else
        changed=1
    fi

    if ! oc create configmap "$cm_name" -n openshift-config \
        --from-file="${regkey}=${cafile}" \
        --dry-run=client -o yaml | oc apply -f -; then
        die "apply ConfigMap ${cm_name} failed"
    fi

    if [[ -z "$existing" ]]; then
        if ! oc patch image.config.openshift.io cluster --type merge \
            -p "{\"spec\":{\"additionalTrustedCA\":{\"name\":\"${cm_name}\"}}}"; then
            die "patch image.config.openshift.io cluster failed"
        fi
    fi

    [[ "$changed" -eq 1 ]] && sleep 15

    trap - EXIT
    rm -f "$cafile" "$curfile"
}

# True when the internal image-registry Deployment exists and has at least one ready replica.
image_registry_deployment_ready() {
    local ready
    oc get deployment image-registry -n openshift-image-registry &>/dev/null || return 1
    ready=$(oc get deployment image-registry -n openshift-image-registry -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || return 1
    [[ -n "$ready" && "$ready" -ge 1 ]]
}

setup_image_registry() {
    local patch_yaml

    if image_registry_deployment_ready; then
        msg "OpenShift image registry is already running."
    else
        if [[ -n "$IMAGE_REGISTRY_STORAGE_CLASS" ]]; then
            msg "Configuring image registry with persistent volume (class=$IMAGE_REGISTRY_STORAGE_CLASS, size=$IMAGE_REGISTRY_PVC_SIZE)..."
            patch_yaml=$(cat <<PATCH
spec:
  managementState: Managed
  storage:
    pvc:
      claim:
        storageClassName: ${IMAGE_REGISTRY_STORAGE_CLASS}
        size: ${IMAGE_REGISTRY_PVC_SIZE}
PATCH
)
        else
            msg "Configuring image registry with ephemeral storage."
            patch_yaml=$(cat <<'PATCH'
spec:
  managementState: Managed
  storage:
    emptyDir: {}
PATCH
)
        fi
        oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch "$patch_yaml" >/dev/null ||
            die "failed to patch image registry config"
        msg "Waiting for image registry deployment (up to 15m)..."
        oc wait --for=condition=available --timeout=900s deployment/image-registry -n openshift-image-registry >/dev/null ||
            die "image registry deployment not available after 15 minutes"
        msg "Image registry is ready."
    fi

    ensure_internal_registry_trusted_ca
}

create_drbd_module() {
    if oc get module drbd-kmod -n openshift-kmm &>/dev/null; then
        msg "KMM Module drbd-kmod already exists."
        if node_has_drbd_kmods "$NODE_0" && node_has_drbd_kmods "$NODE_1"; then
            return 0
        fi
        wait_for_kmm_drbd_build_success
        return 0
    fi

    msg "Creating KMM Module drbd-kmod"

    local kmm_dockerfile
    kmm_dockerfile=$(cat <<'DOCKERFILE_TEMPLATE'
    ARG DTK_AUTO
    ARG KERNEL_FULL_VERSION
    ARG DRBD_VERSION=__DRBD_VERSION__

    FROM __DRBD_IMAGE__ AS drbd-src

    FROM ${DTK_AUTO} AS builder
    ARG KERNEL_FULL_VERSION
    ARG DRBD_VERSION

    WORKDIR /tmp/drbd_build

    COPY --from=drbd-src /drbd-drbd-${DRBD_VERSION}.tar.gz .
    RUN tar -xvzf drbd-drbd-${DRBD_VERSION}.tar.gz

    WORKDIR /tmp/drbd_build/drbd-drbd-${DRBD_VERSION}
    RUN make KVER=${KERNEL_FULL_VERSION} -j$(nproc)
    RUN mkdir -p /install/lib/modules/${KERNEL_FULL_VERSION}/extra
    RUN cp drbd/build-current/drbd.ko drbd/build-current/drbd_transport_tcp.ko /install/lib/modules/${KERNEL_FULL_VERSION}/extra/
    RUN depmod -b /install ${KERNEL_FULL_VERSION}
    FROM registry.redhat.io/ubi9/ubi-minimal
    ARG KERNEL_FULL_VERSION
    COPY --from=builder /install/lib/modules/ /opt/lib/modules/
DOCKERFILE_TEMPLATE
)
    kmm_dockerfile="${kmm_dockerfile//__DRBD_VERSION__/${DRBD_VERSION}}"
    kmm_dockerfile="${kmm_dockerfile//__DRBD_IMAGE__/${DRBD_IMAGE}}"

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: drbd-kmod-dockerfile
  namespace: openshift-kmm
data:
  dockerfile: |
$(printf '%s\n' "$kmm_dockerfile" | awk '{print "    " $0}')
EOF

    oc apply -f - >/dev/null <<'MODULE_SPEC'
apiVersion: kmm.sigs.x-k8s.io/v1beta1
kind: Module
metadata:
  name: drbd-kmod
  namespace: openshift-kmm
spec:
  moduleLoader:
    container:
      modprobe:
        moduleName: drbd_transport_tcp
        dirName: /opt
      kernelMappings:
        - regexp: '^.*\.x86_64$'
          containerImage: 'image-registry.openshift-image-registry.svc:5000/openshift-kmm/drbd_compat_kmod:${KERNEL_FULL_VERSION}'
          build:
            dockerfileConfigMap:
              name: drbd-kmod-dockerfile
  selector: {}
MODULE_SPEC
    msg "KMM Module and ConfigMap applied."
}

node_has_drbd_kmods() {
    local node="$1"
    local out
    out=$(oc debug -q "node/$node" -- chroot /host cat /proc/modules 2>/dev/null) || return 1
    echo "$out" | grep -qE '^drbd[[:space:]]' || return 1
    echo "$out" | grep -qE '^drbd_transport_tcp[[:space:]]' || return 1
    return 0
}

wait_for_modules() {
    if node_has_drbd_kmods "$NODE_0" && node_has_drbd_kmods "$NODE_1"; then
        return 0
    fi

    msg "Waiting for DRBD kernel modules to load on both nodes..."
    local i
    for i in $(seq 1 60); do
        if node_has_drbd_kmods "$NODE_0" && node_has_drbd_kmods "$NODE_1"; then
            msg "DRBD kernel modules are loaded on both nodes."
            return 0
        fi
        [[ "$i" -eq 60 ]] && die "DRBD modules failed to load after 10 minutes. Check: oc get module,pods -n openshift-kmm; oc debug -q node/${NODE_0} -- chroot /host cat /proc/modules | grep -E '^drbd|drbd_transport'"
        sleep 10
    done
}

drbdctl() {
    local node="$1"
    shift
    oc debug -q "node/$node" -- chroot /host \
        sudo podman run --rm --privileged \
        -v /dev:/dev \
        -v /etc/drbd.conf:/etc/drbd.conf \
        -v /etc/drbd.d:/etc/drbd.d \
        --hostname "$node" \
        --net host \
        "${DRBD_IMAGE}" \
        drbdadm "$@" || {
            echo "DRBD command failed on node $node: drbdadm $*" >&2
            return 1
        }
}

# create-md prompts when it finds a filesystem signature in the data area; -i attaches stdin so piped "yes" reaches drbdadm.
drbdctl_create_md() {
    local node="$1"
    local rc
    set +o pipefail
    yes 2>/dev/null | oc debug -q "node/$node" -- chroot /host \
        sudo podman run -i --rm --privileged \
        -v /dev:/dev \
        -v /etc/drbd.conf:/etc/drbd.conf \
        -v /etc/drbd.d:/etc/drbd.d \
        --hostname "$node" \
        --net host \
        "${DRBD_IMAGE}" \
        drbdadm create-md "${DRBD_RESOURCE_NAME}" --force
    rc="${PIPESTATUS[1]}"
    set -o pipefail
    [[ "$rc" -eq 0 ]] || die "drbdadm create-md failed on $node (exit $rc)"
}

configure_drbd() {
    if drbdctl "$NODE_0" status "${DRBD_RESOURCE_NAME}" 2>/dev/null | grep -q "role:" && \
       drbdctl "$NODE_1" status "${DRBD_RESOURCE_NAME}" 2>/dev/null | grep -q "role:"; then
        msg "DRBD resource is already up on both nodes."
        return 0
    fi

    local DRBD_CONFIG DRBD_CONF_B64
    DRBD_CONFIG="global { usage-count no; }
common {
    net { protocol C; after-sb-0pri discard-zero-changes; after-sb-1pri discard-secondary; }
    disk { on-io-error pass_on; }
    options { on-no-data-accessible suspend-io; }
}
resource ${DRBD_RESOURCE_NAME} {
    on ${NODE_0} {
        device ${DRBD_DEVICE};
        disk ${DISK_RESOLVED_NODE0};
        address ${NODE_0_IP}:${DRBD_PORT};
        node-id 0;
        meta-disk internal;
    }
    on ${NODE_1} {
        device ${DRBD_DEVICE};
        disk ${DISK_RESOLVED_NODE1};
        address ${NODE_1_IP}:${DRBD_PORT};
        node-id 1;
        meta-disk internal;
    }
}"

    if DRBD_CONF_B64=$(echo "$DRBD_CONFIG" | base64 -w0 2>/dev/null); then
        :
    else
        DRBD_CONF_B64=$(echo "$DRBD_CONFIG" | base64 | tr -d '\n')
    fi

    local node
    for node in "$NODE_0" "$NODE_1"; do
        oc debug -q "node/$node" -- chroot /host bash -c "
mkdir -p /etc/drbd.d /var/lib/drbd
echo '${DRBD_CONF_B64}' | base64 -d > /etc/drbd.d/${DRBD_RESOURCE_NAME}.res
echo 'include \"/etc/drbd.d/*.res\";' > /etc/drbd.conf
" || die "failed to write DRBD config on $node"

        if ! drbdctl "$node" status "${DRBD_RESOURCE_NAME}" &>/dev/null; then
            drbdctl_create_md "$node"
            drbdctl "$node" up "${DRBD_RESOURCE_NAME}" || die "drbdadm up failed on $node"
        fi
    done
    msg "DRBD resource is configured and the replication link is up."
}

drbd_resource_fully_replicated() {
    local n st
    for n in "$NODE_0" "$NODE_1"; do
        st=$(drbdctl "$n" status "${DRBD_RESOURCE_NAME}" 2>/dev/null) || return 1
        echo "$st" | grep -q "disk:UpToDate" || return 1
        echo "$st" | grep -q "peer-disk:UpToDate" || return 1
    done
    return 0
}

sync_drbd() {
    # Transient Primary on NODE_0 for sync; then demote to Secondary on both nodes.
    local PRIMARY_NODE="$NODE_0"
    DRBD_PROMOTED_MASTER0_THIS_RUN=0

    if drbd_resource_fully_replicated; then
        msg "DRBD data is already fully replicated (UpToDate on both nodes); skipping primary/sync wait."
        return 0
    fi

    msg "Promoting $PRIMARY_NODE to Primary to run initial replication..."
    drbdctl "$PRIMARY_NODE" primary --force "$DRBD_RESOURCE_NAME" || die "drbdadm primary failed on $PRIMARY_NODE"
    DRBD_PROMOTED_MASTER0_THIS_RUN=1

    msg "Waiting for full sync (reported every 30s if still in progress)..."
    local i STATUS PROGRESS
    for i in $(seq 1 120); do
        STATUS=$(drbdctl "$PRIMARY_NODE" status "$DRBD_RESOURCE_NAME" 2>/dev/null)
        if echo "$STATUS" | grep -q "peer-disk:UpToDate"; then
            msg "Initial replication finished; both nodes report UpToDate."
            return 0
        fi
        PROGRESS=$(echo "$STATUS" | grep -o 'done:[0-9.]*' | head -1 | cut -d: -f2)
        [[ -n "$PROGRESS" ]] && msg "Replication progress: ${PROGRESS}%"
        [[ "$i" -eq 120 ]] && die "DRBD sync timed out after 60m. Status: $STATUS"
        sleep 30
    done
}

create_filesystem_over_drbd() {
    local PRIMARY_NODE="$NODE_0"

    if [[ "$FORCE_MKFS" -eq 1 ]]; then
        msg "Formatting ${DRBD_DEVICE} with XFS (-f overwrites any existing signature)..."
        oc debug -q "node/$PRIMARY_NODE" -- chroot /host sudo mkfs.xfs -f "${DRBD_DEVICE}"
        msg "XFS (forced) created on ${DRBD_DEVICE}."
        return 0
    fi

    if oc debug -q "node/$PRIMARY_NODE" -- chroot /host sudo blkid "${DRBD_DEVICE}" &>/dev/null; then
        msg "File system on ${DRBD_DEVICE} already present; not running mkfs. Use --force-mkfs to overwrite."
        return 0
    fi

    msg "Creating XFS on ${DRBD_DEVICE} (one-time)..."
    oc debug -q "node/$PRIMARY_NODE" -- chroot /host sudo mkfs.xfs "${DRBD_DEVICE}"
    msg "XFS created on ${DRBD_DEVICE}."
}

make_both_node_secondary() {
    [[ "${DRBD_PROMOTED_MASTER0_THIS_RUN:-0}" -eq 1 ]] || return 0

    local PRIMARY_NODE="$NODE_0"
    local i ROLE

    ROLE=$(drbdctl "$PRIMARY_NODE" role "${DRBD_RESOURCE_NAME}" 2>/dev/null | cut -d/ -f1)
    [[ "$ROLE" == "Secondary" ]] && return 0

    msg "Demoting $PRIMARY_NODE to Secondary."
    drbdctl "$PRIMARY_NODE" secondary "$DRBD_RESOURCE_NAME" || die "drbdadm secondary failed on $PRIMARY_NODE"

    for i in $(seq 1 20); do
        ROLE=$(drbdctl "$PRIMARY_NODE" role "$DRBD_RESOURCE_NAME" 2>/dev/null | cut -d/ -f1)
        [[ "$ROLE" == "Secondary" ]] && msg "$PRIMARY_NODE is Secondary." && return 0
        sleep 2
    done
    die "Node $PRIMARY_NODE did not become Secondary"
}

setup_drbd_autostart() {
    if oc get daemonset "${AUTOSTART_DAEMONSET_NAME}" -n "${AUTOSTART_DAEMONSET_NS}" &>/dev/null; then
        msg "DRBD auto-start DaemonSet already exists."
        return 0
    fi

    msg "Creating DRBD auto-start DaemonSet in namespace ${AUTOSTART_DAEMONSET_NS}..."
    oc create namespace "${AUTOSTART_DAEMONSET_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
    oc create serviceaccount drbd-autostart -n "${AUTOSTART_DAEMONSET_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1
    oc adm policy add-scc-to-user privileged -z drbd-autostart -n "${AUTOSTART_DAEMONSET_NS}" >/dev/null

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: drbd-autostart-script
  namespace: ${AUTOSTART_DAEMONSET_NS}
data:
  start.sh: |
    #!/bin/bash
    while true; do
        if drbdadm status ${DRBD_RESOURCE_NAME} &>/dev/null; then
            echo "DRBD resource ${DRBD_RESOURCE_NAME} is already up"
        else
            echo "Starting DRBD resource ${DRBD_RESOURCE_NAME}..."
            drbdadm up ${DRBD_RESOURCE_NAME} || echo "Warning: drbdadm up failed, will retry"
        fi
        drbdadm status ${DRBD_RESOURCE_NAME} || true
        sleep 60
    done
EOF

    oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${AUTOSTART_DAEMONSET_NAME}
  namespace: ${AUTOSTART_DAEMONSET_NS}
  labels:
    app: ${AUTOSTART_DAEMONSET_NAME}
spec:
  selector:
    matchLabels:
      app: ${AUTOSTART_DAEMONSET_NAME}
  template:
    metadata:
      labels:
        app: ${AUTOSTART_DAEMONSET_NAME}
    spec:
      serviceAccountName: drbd-autostart
      hostNetwork: true
      hostPID: true
      containers:
      - name: drbd-starter
        image: ${DRBD_IMAGE}
        command: ["/bin/bash", "/scripts/start.sh"]
        securityContext:
          privileged: true
          capabilities:
            add:
            - SYS_ADMIN
            - SYS_MODULE
            - NET_ADMIN
        volumeMounts:
        - name: host-root
          mountPath: /host
          readOnly: false
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: drbd-conf
          mountPath: /etc/drbd.conf
        - name: drbd-dir
          mountPath: /etc/drbd.d
        - name: dev
          mountPath: /dev
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
      volumes:
      - name: host-root
        hostPath:
          path: /
          type: Directory
      - name: scripts
        configMap:
          name: drbd-autostart-script
          defaultMode: 0755
      - name: drbd-conf
        hostPath:
          path: /etc/drbd.conf
          type: File
      - name: drbd-dir
        hostPath:
          path: /etc/drbd.d
          type: Directory
      - name: dev
        hostPath:
          path: /dev
          type: Directory
      tolerations:
      - operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
EOF

    msg "Waiting for DRBD auto-start DaemonSet pods on both nodes..."
    local i READY_COUNT
    for i in $(seq 1 60); do
        READY_COUNT=$(oc get daemonset "${AUTOSTART_DAEMONSET_NAME}" -n "${AUTOSTART_DAEMONSET_NS}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        [[ -z "$READY_COUNT" ]] && READY_COUNT=0
        READY_COUNT=$((0 + READY_COUNT))
        [[ "$READY_COUNT" -eq 2 ]] && msg "DRBD auto-start DaemonSet is running on both nodes." && return 0
        [[ "$i" -eq 60 ]] && die "DaemonSet not ready (oc get ds,pods -n ${AUTOSTART_DAEMONSET_NS})"
        sleep 5
    done
}

create_success_configmap() {
    msg "Saving setup summary to ConfigMap ${OUTPUT_CM_NS}/${OUTPUT_CM_NAME}"
    oc create namespace "${OUTPUT_CM_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true

    local bd0 bd1
    if [[ -n "$BACKING_PATH" ]]; then
        bd0="$BACKING_PATH"
        bd1="$BACKING_PATH"
    else
        bd0="$BACKING_PATH_NODE0"
        bd1="$BACKING_PATH_NODE1"
    fi

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${OUTPUT_CM_NAME}
  namespace: ${OUTPUT_CM_NS}
  labels:
    app.kubernetes.io/name: drbd-setup
    app.kubernetes.io/component: storage
data:
  NODE_0_NAME: "${NODE_0}"
  NODE_1_NAME: "${NODE_1}"
  NODE_0_IP: "${NODE_0_IP}"
  NODE_1_IP: "${NODE_1_IP}"
  BLOCK_DEVICE_PATH_NODE_0: "${bd0}"
  BLOCK_DEVICE_PATH_NODE_1: "${bd1}"
  DISK_BY_ID_NODE_0: "${DISK_RESOLVED_NODE0}"
  DISK_BY_ID_NODE_1: "${DISK_RESOLVED_NODE1}"
  DRBD_DEVICE: "${DRBD_DEVICE}"
  DRBD_RESOURCE: "${DRBD_RESOURCE_NAME}"
  DRBD_PORT: "${DRBD_PORT}"
  SETUP_TIMESTAMP: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
}

print_success() {
    echo ""
    local b o
    b='' o=''
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        b=$(tput bold 2>/dev/null) || true
        o=$(tput sgr0 2>/dev/null) || true
    fi
    echo "${b}  --> DRBD setup completed successfully <--${o}"
}

main() {
    parse_args "$@"

    if [[ "$SHOW_CONFIG_ONLY" -eq 1 ]]; then
        if [[ -z "$BACKING_PATH" && -z "$BACKING_PATH_NODE0" ]]; then
            show_config_defaults_only
            exit 0
        fi
        check_prerequisites
        detect_nodes
        show_config_cluster_preview
        exit 0
    fi

    check_prerequisites
    detect_nodes

    if [[ "$LIST_DEVICES_ONLY" -eq 1 ]]; then
        list_devices
        exit 0
    fi

    print_config
    validate_and_resolve_disks

    setup_kmm_operator
    setup_image_registry
    create_drbd_module
    wait_for_modules
    configure_drbd
    sync_drbd
    create_filesystem_over_drbd
    make_both_node_secondary
    setup_drbd_autostart
    create_success_configmap
    print_success
}

main "$@"
