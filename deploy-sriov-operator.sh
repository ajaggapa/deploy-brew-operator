#!/bin/bash

# Pre-requirements Check (Basic checks - extend as needed)
echo "Checking pre-requirements..."
command -v podman >/dev/null 2>&1 || { echo >&2 "Podman is not installed. Please install Podman and try again."; exit 1; }
command -v oc >/dev/null 2>&1 || { echo >&2 "OpenShift CLI (oc) is not installed. Please install oc and try again."; exit 1; }
command -v opm >/dev/null 2>&1 || { echo >&2 "OPM CLI (opm) is not installed. Please install opm and try again."; exit 1; }
command -v brew >/dev/null 2>&1 || { echo >&2 "Brew CLI (brew) is not installed. Please install brew and try again."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo >&2 "jq is not installed. Please install jq (for JSON parsing) and try again."; exit 1; }
echo "Pre-requirements seem to be met."
echo "Ensure you are logged into your OCP cluster (oc login) and have administrative privileges."
echo ""

# Configuration Variables - initialized empty as mandatory arguments, plus new optional
OPERATOR_VERSION_SEARCH=""
INTERNAL_REGISTRY_URL=""
INTERNAL_REGISTRY_AUTH_FILE=""
BUILD_NAME="" # New variable for optional direct build name

INDEX_IMAGE_NAME="sriov-network-operator-index"
INDEX_IMAGE_TAG="1.0.0"
SRIOV_MANIFESTS_DIR="sriov-network-operator-bundle-container"

# Function to display usage information
usage() {
    echo "Usage: $0 --version <operator_version> --internal-registry <registry_url> --internal-registry-auth <auth_file_path> [--build-name <brew_build_name>]"
    echo "  --version             : The SR-IOV operator version (e.g., v4.20). Mandatory."
    echo "  --internal-registry   : The URL of your internal image registry (e.g., registry.hlxcl14.lab.eng.tlv2.redhat.com:5000). Mandatory."
    echo "  --internal-registry-auth: The path to the podman/OpenShift authentication file for the registry (e.g., ~/.docker/config.json). Mandatory."
    echo "  --build-name          : Optional. The exact Brew build name (e.g., sriov-network-operator-metadata-container-v4.20.0.202508111916.p0.gab41a01.assembly.stream.el9-1)."
    echo "                          If provided, this will be used instead of auto-detecting the latest build for the specified version."
    echo "Example: $0 --version v4.9 --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 --internal-registry-auth ~/.docker/config.json"
    echo "Example with build name: $0 --version v4.9 --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 --internal-registry-auth ~/.docker/config.json --build-name sriov-network-operator-metadata-container-v4.9.0.202112142229.p0.gbfeaa5b.assembly.stream-1"
    exit 1
}

# Argument Handling
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --version)
            OPERATOR_VERSION_SEARCH="$2"
            shift # past argument
            shift # past value
            ;;
        --internal-registry)
            INTERNAL_REGISTRY_URL="$2"
            shift # past argument
            shift # past value
            ;;
        --internal-registry-auth)
            INTERNAL_REGISTRY_AUTH_FILE="$2"
            shift # past argument
            shift # past value
            ;;
        --build-name)
            BUILD_NAME="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Validate that all mandatory arguments are provided
if [ -z "${OPERATOR_VERSION_SEARCH}" ]; then
    echo "Error: --version argument is required."
    usage
fi
if [ -z "${INTERNAL_REGISTRY_URL}" ]; then
    echo "Error: --internal-registry argument is required."
    usage
fi
if [ -z "${INTERNAL_REGISTRY_AUTH_FILE}" ]; then
    echo "Error: --internal-registry-auth argument is required."
    usage
fi

# Set OPERATOR_BUNDLE_NAME based on whether --build-name was provided
if [ -n "${BUILD_NAME}" ]; then
    OPERATOR_BUNDLE_NAME_FOR_BREW_SEARCH="${BUILD_NAME}"
    echo "Using explicit Brew build name: ${BUILD_NAME}"
else
    OPERATOR_BUNDLE_NAME_FOR_BREW_SEARCH="sriov-network-operator-metadata-container"
    echo "Automatically detecting latest Brew build for version"
fi


echo "Attempting to install SR-IOV operator version: ${OPERATOR_VERSION_SEARCH}"
echo "Using internal registry: ${INTERNAL_REGISTRY_URL}"
echo "Using internal registry authentication file: ${INTERNAL_REGISTRY_AUTH_FILE}"
echo ""

# Step 1: Prepare Internal Registry
echo "Step 1: Checking reachability of the internal registry: ${INTERNAL_REGISTRY_URL}"
# We no longer attempt to start a local Podman registry automatically, as the registry URL is mandatory.
curl -X GET https://${INTERNAL_REGISTRY_URL}/v2/_catalog --insecure >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Internal registry not reachable at https://${INTERNAL_REGISTRY_URL}. Please ensure it is running and accessible."
    exit 1
fi
echo "Internal registry is reachable."
echo ""

# Step 2 & 3: Find and Get Link to Operator Bundle/Metadata
echo "Step 2 & 3: Finding and getting the operator bundle link from Brew..."

# Dynamically find the latest relevant bundle or use provided build name
if [ -n "${BUILD_NAME}" ]; then
    LATEST_BREW_BUILD="${BUILD_NAME}"
    echo "Using provided Brew build name: ${LATEST_BREW_BUILD}"
else
    echo "Listing builds for ${OPERATOR_BUNDLE_NAME_FOR_BREW_SEARCH} and grepping for ${OPERATOR_VERSION_SEARCH}..."
    echo "brew list-builds  --package="${OPERATOR_BUNDLE_NAME_FOR_BREW_SEARCH}"  --state=COMPLETE --quiet --reverse | grep "${OPERATOR_VERSION_SEARCH}" | awk '{print $1}' | head -1"
    LATEST_BREW_BUILD=$(brew list-builds  --package="${OPERATOR_BUNDLE_NAME_FOR_BREW_SEARCH}"  --state=COMPLETE --quiet --reverse | grep "${OPERATOR_VERSION_SEARCH}" | awk '{print $1}' | head -1)
fi

if [ -z "$LATEST_BREW_BUILD" ]; then
    echo "Error: Could not determine the Brew build name. Please check the provided --build-name or the operator name and version combination."
    echo "Example Brew build name from document: sriov-network-operator-metadata-container-v4.9.0.202112142229.p0.gbfeaa5b.assembly.stream-1"
    exit 1
fi

echo "Using Brew build: ${LATEST_BREW_BUILD}"

OPERATOR_BUNDLE_IMAGE=$(brew --noauth call --json getBuild buildInfo=${LATEST_BREW_BUILD} 2>/dev/null | jq -r '.extra.image.index.pull[0]')

if [ -z "$OPERATOR_BUNDLE_IMAGE" ] || [[ "$OPERATOR_BUNDLE_IMAGE" == "null" ]]; then
    echo "Error: Could not extract the operator bundle image link from Brew build '${LATEST_BREW_BUILD}'. Exiting."
    exit 1
fi

echo "Operator Bundle Image found: ${OPERATOR_BUNDLE_IMAGE}"
echo ""

# Step 4: Mirror the bundle image to your internal registry
echo "Step 4: Mirroring the bundle image to internal registry..."
# Added --registry-config as it is now always provided
OC_IMAGE_MIRROR_AUTH_FLAG="--registry-config ${INTERNAL_REGISTRY_AUTH_FILE}"

oc image mirror --insecure=true -a ${INTERNAL_REGISTRY_AUTH_FILE} "${OPERATOR_BUNDLE_IMAGE}" "${INTERNAL_REGISTRY_URL}/operators/openshift-ose-sriov-network-operator-bundle:latest" 
if [ $? -ne 0 ]; then
    echo "Error: Failed to mirror the bundle image. Exiting."
    exit 1
fi
echo "Bundle image mirrored successfully."
echo ""

# Step 5: Validate the bundle
echo "Step 5: Validating the bundle..."
opm alpha bundle validate --tag "${INTERNAL_REGISTRY_URL}/operators/openshift-ose-sriov-network-operator-bundle:latest" --image-builder podman
if [ $? -ne 0 ]; then
    echo "Warning: Bundle validation failed. Continuing, but you might want to investigate."
fi
echo "Bundle validation complete."
echo ""

# Step 6: Build index image
echo "Step 6: Building the index image..."
# Ensure Podman is logged in to your internal registry if required for opm build step
# e.g., 'podman login ${INTERNAL_REGISTRY_URL}' should be done manually before running this script
opm index add --skip-tls --bundles="${INTERNAL_REGISTRY_URL}/operators/openshift-ose-sriov-network-operator-bundle:latest" --tag "${INTERNAL_REGISTRY_URL}/operators/${INDEX_IMAGE_NAME}:${INDEX_IMAGE_TAG}" -c podman
if [ $? -ne 0 ]; then
    echo "Error: Failed to build the index image. Exiting."
    exit 1
fi
echo "Index image built successfully."
podman images | grep ${INDEX_IMAGE_NAME}
echo ""

# Step 7: Push index-image to local registry
echo "Step 7: Pushing index image to internal registry..."
# Ensure Podman is logged in to your internal registry if required for push
podman push "${INTERNAL_REGISTRY_URL}/operators/${INDEX_IMAGE_NAME}:${INDEX_IMAGE_TAG}" --authfile="${INTERNAL_REGISTRY_AUTH_FILE}" --tls-verify=false
if [ $? -ne 0 ]; then
    echo "Error: Failed to push the index image to the internal registry. Exiting."
    exit 1
fi
echo "Index image pushed successfully."
echo ""

# Step 8: Extract operator images links from index image and modify mappings
echo "Step 8: Extracting and modifying operator image links..."

# Create a temporary directory for manifests
mkdir -p "$SRIOV_MANIFESTS_DIR"

oc adm catalog mirror "${INTERNAL_REGISTRY_URL}/operators/${INDEX_IMAGE_NAME}:${INDEX_IMAGE_TAG}" "${INTERNAL_REGISTRY_URL}/operators" --insecure=true ${OC_IMAGE_MIRROR_AUTH_FLAG} --manifests-only --to-manifests="${SRIOV_MANIFESTS_DIR}" --path="/database/index.db:./"
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract catalog manifests. Exiting."
    exit 1
fi
echo "Catalog manifests extracted to ${SRIOV_MANIFESTS_DIR}/"

echo "Modifying mapping.txt and imageContentSourcePolicy.yaml..."

sed -i${SED_IN_PLACE} 's#registry.redhat.io/openshift4/#registry-proxy.engineering.redhat.com/rh-osbs/openshift-#g' "./${SRIOV_MANIFESTS_DIR}/mapping.txt"
sed -i${SED_IN_PLACE} 's#openshift4-##g' "./${SRIOV_MANIFESTS_DIR}/mapping.txt"
sed -i${SED_IN_PLACE} '/operator-bundle:latest/d' "./${SRIOV_MANIFESTS_DIR}/mapping.txt" 
sed -i${SED_IN_PLACE} 's#openshift4-##g' "./${SRIOV_MANIFESTS_DIR}/imageContentSourcePolicy.yaml"

echo "Image links modified successfully."
echo ""

# Step 9: Mirror operator's images to internal registry
echo "Step 9: Mirroring operator's images to internal registry based on modified mapping..."
oc image mirror --insecure=true ${OC_IMAGE_MIRROR_AUTH_FLAG} --filter-by-os=".*" --keep-manifest-list -f "./${SRIOV_MANIFESTS_DIR}/mapping.txt"
if [ $? -ne 0 ]; then
    echo "Error: Failed to mirror operator images. Exiting."
    exit 1
fi
echo "Operator images mirrored successfully."
echo ""

# OCP Side Deployment

# Step 10: Apply imageContentSourcePolicy.yaml
echo "Step 10: Applying imageContentSourcePolicy.yaml..."
oc create -f "./${SRIOV_MANIFESTS_DIR}/imageContentSourcePolicy.yaml"
if [ $? -ne 0 ]; then
    echo "Warning: imageContentSourcePolicy might already exist or failed to create. Continuing, but check your cluster status."
fi
echo "Waiting for 10 seconds for cluster nodes to restart after applying ImageContentSourcePolicy..."
sleep 10
echo ""

# Step 11: Add internal registry to allowed insecure registries on cluster
echo "Step 11: Adding internal registry to allowed insecure registries on cluster..."
oc patch image.config.openshift.io/cluster --patch '{"spec":{ "registrySources": { "insecureRegistries" : ["'${INTERNAL_REGISTRY_URL}'"] }}}' --type=merge
if [ $? -ne 0 ]; then
    echo "Error: Failed to patch cluster image configuration. Exiting."
    exit 1
fi
# Wait until all nodes report Ready and are schedulable (not SchedulingDisabled)
echo "Waiting for 30 seconds for cluster nodes to restart after applying ImageContentSourcePolicy..."
sleep 30
echo "Waiting for 10 minutes for cluster nodes to restart after applying ImageContentSourcePolicy..."
oc wait --for=condition=Updating=False --timeout=10m mcp --all
if [ $? -ne 0 ]; then
    echo "Warning: CatalogSource pod did not become ready in time. Check 'oc get pods -n openshift-marketplace | grep internal'." 
fi
echo ""

# Step 11 (second part): Disable all default sources
echo "Step 11 (second part): Disabling all default sources..."
oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge
if [ $? -ne 0 ]; then
    echo "Error: Failed to patch operatorhub cluster. Exiting."
    exit 1
fi
echo "Operatorhub cluster patched."
echo ""

# Step 11 (second part): Create CatalogSource
echo "Step 11: Creating CatalogSource pointing to the internal registry..."

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: internal-registry
  namespace: openshift-marketplace
spec:
  displayName: internal-images
  image: "${INTERNAL_REGISTRY_URL}/operators/${INDEX_IMAGE_NAME}:${INDEX_IMAGE_TAG}"
  publisher: Red Hat
  sourceType: grpc
EOF

if [ $? -ne 0 ]; then
    echo "Error: Failed to create CatalogSource. Exiting."
    exit 1
fi
echo "CatalogSource created."
echo "Waiting for CatalogSource pod to be ready..."
oc wait --for=condition=ready pod -l olm.catalogSource=internal-registry -n openshift-marketplace --timeout=60s
if [ $? -ne 0 ]; then
    echo "Warning: CatalogSource pod did not become ready in time. Check 'oc get pods -n openshift-marketplace | grep internal'."
fi
oc get packagemanifest -n openshift-marketplace | grep sriov
echo ""

# Step 12: Deploy Operator's namespace
echo "Step 12: Deploying operator's namespace (openshift-sriov-network-operator)..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  annotations:
    workload.openshift.io/allowed: management
EOF
if [ $? -ne 0 ]; then
    echo "Warning: Namespace might already exist or failed to create."
fi
echo "Namespace created/ensured."
echo ""

# Step 13: Deploy OperatorGroup resource
echo "Step 13: Deploying OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
EOF
if [ $? -ne 0 ]; then
    echo "Warning: OperatorGroup might already exist or failed to create."
fi
echo "OperatorGroup created/ensured."
echo ""

# Step 14: Deploy Subscription
echo "Step 14: Deploying Subscription to internal registry..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  name: sriov-network-operator
  source: internal-registry
  sourceNamespace: openshift-marketplace
EOF
if [ $? -ne 0 ]; then
    echo "Error: Failed to create Subscription. Exiting."
    exit 1
fi
echo "Subscription created."
echo "Waiting for SR-IOV operator CSV to be installed and running..."
# Wait for CSV to be in Succeeded phase
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -l operators.coreos.com/sriov-network-operator.openshift-sriov-network-operator= -n openshift-sriov-network-operator --timeout=120s
if [ $? -ne 0 ]; then
    echo "Warning: SR-IOV operator CSV did not reach 'Succeeded' phase in time. Check 'oc get csv -n openshift-sriov-network-operator'."
fi
oc get csv -n openshift-sriov-network-operator
echo ""

echo "SR-IOV Network Operator installation script finished."
echo "You can check the operator's status with: oc get pods -n openshift-sriov-network-operator"
echo "And CSV status with: oc get csv -n openshift-sriov-network-operator"

