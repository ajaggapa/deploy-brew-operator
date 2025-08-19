#!/bin/bash

# Fail fast and loudly on errors; treat unset vars as errors; fail on pipeline errors
set -Eeuo pipefail
set -x

# Ensure optional sed in-place suffix variable is defined (empty by default)
: "${SED_IN_PLACE:=}"

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

# Random name generator (safe for directories, images, tags). Returns 5-char string.
generate_random_name() {
    # Avoid set -o pipefail causing failure on SIGPIPE from head
    { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 5; } || true
}

# Configuration Variables - initialized empty as mandatory arguments, plus new optional
OPERATOR_VERSION_SEARCH=""
INTERNAL_REGISTRY_URL=""
INTERNAL_REGISTRY_AUTH_FILE=""
OPERATOR_NAME=""
OPERATOR_PACKAGE_NAME=""
OLM_PACKAGE_NAME=""
OPERATOR_NAMESPACE=""
OPERATOR_GROUP_ALL_NAMESPACES="false"
BUILD_NAME="" # New variable for optional direct build name
BREW_BUILD_TO_USE=""

OPERATOR_MANIFESTS_DIR="operator-bundle-$(generate_random_name)"

# Function to display usage information
usage() {
    echo "Usage: $0 --operator <sriov|metallb|ptp|nmstate> --operator-ns <namespace> --internal-registry <registry_url> --internal-registry-auth <auth_file_path> [--version <operator_version> | --build-name <brew_build_name>]"
    echo "  --operator            : One of: sriov, metallb, ptp, nmstate. Mandatory."
    echo "  --operator-ns         : Namespace to install the operator into (e.g., openshift-sriov-network-operator). Mandatory."
    echo "  --internal-registry   : The URL of your internal image registry (e.g., registry.hlxcl14.lab.eng.tlv2.redhat.com:5000). Mandatory."
    echo "  --internal-registry-auth: The path to the podman/OpenShift authentication file for the registry (e.g., ~/.docker/config.json). Mandatory."
    echo "  --version             : Optional if --build-name is provided. Version to search for in Brew builds (e.g., v4.20)."
    echo "  --build-name          : Optional. Exact Brew build name. If provided, it is used and --version is ignored."
    echo "Example: $0 --version v4.20 --operator sriov --operator-ns openshift-sriov-network-operator --internal-registry registry.example.com:5000 --internal-registry-auth ~/.docker/config.json"
    echo "Example with build name: $0 --operator sriov --operator-ns openshift-sriov-network-operator --internal-registry registry.example.com:5000 --internal-registry-auth ~/.docker/config.json --build-name sriov-network-operator-metadata-container-v4.20.0.202112142229.p0.gbfeaa5b.assembly.stream-1"
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
        --operator)
            OPERATOR_NAME="$2"
            shift
            shift
            ;;
        --operator-ns)
            OPERATOR_NAMESPACE="$2"
            shift
            shift
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

# Map OPERATOR_NAME to OPERATOR_PACKAGE_NAME and validate allowed values
case "${OPERATOR_NAME}" in
    sriov)
        OPERATOR_PACKAGE_NAME="sriov-network-operator-metadata-container"
        OLM_PACKAGE_NAME="sriov-network-operator"
        OPERATOR_NAMESPACE="openshift-sriov-network-operator"
        ;;
    metallb)
        OPERATOR_PACKAGE_NAME="ose-metallb-operator-bundle-container"
        OLM_PACKAGE_NAME="metallb-operator"
        OPERATOR_NAMESPACE="metallb-system"
        OPERATOR_GROUP_ALL_NAMESPACES="true"
        ;;
    ptp)
        OPERATOR_PACKAGE_NAME="ose-ptp-operator-metadata-container"
        OLM_PACKAGE_NAME="ptp-operator"
        OPERATOR_NAMESPACE="openshift-ptp"
        ;;
    nmstate)
        OPERATOR_PACKAGE_NAME="ose-kubernetes-nmstate-operator-bundle-container"
        OLM_PACKAGE_NAME="kubernetes-nmstate-operator"
        OPERATOR_NAMESPACE="openshift-nmstate"
        ;;
    "")
        # not provided; handled below in validation
        ;;
    *)
        echo "Error: --operator must be one of: sriov, metallb, ptp, nmstate."
        usage
        ;;
esac

# Validate that all mandatory arguments are provided
if [ -z "${OPERATOR_VERSION_SEARCH}" ] && [ -z "${BUILD_NAME}" ]; then
    echo "Error: either --version or --build-name must be provided."
    usage
fi
if [ -z "${OPERATOR_NAME}" ]; then
    echo "Error: --operator argument is required and must be one of: sriov, metallb, ptp, nmstate."
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

if [ -n "${BUILD_NAME}" ]; then
    echo "Attempting to install ${OPERATOR_NAME} operator using build ${BUILD_NAME} on namespace ${OPERATOR_NAMESPACE} "
else
    echo "Attempting to install ${OPERATOR_NAME} operator of version ${OPERATOR_VERSION_SEARCH} on namespace ${OPERATOR_NAMESPACE} "
fi
echo "Using internal registry: ${INTERNAL_REGISTRY_URL}"
echo "Using internal registry authentication file: ${INTERNAL_REGISTRY_AUTH_FILE}"
echo "Resolved operator package: ${OPERATOR_PACKAGE_NAME}"
echo "OLM package name: ${OLM_PACKAGE_NAME}"
echo ""

# Step 0: Cleanup existing operator resources
echo "Step 0: Cleaning up existing operator resources..."
oc delete namespace "${OPERATOR_NAMESPACE}" || true
oc delete catalogsource "catalog-${OPERATOR_NAME}" -n openshift-marketplace || true


# Step 1: Prepare Internal Registry
echo "Step 1: Checking reachability of the internal registry: ${INTERNAL_REGISTRY_URL}"
if ! curl -X GET https://"${INTERNAL_REGISTRY_URL}"/v2/_catalog --insecure >/dev/null 2>&1; then
    echo "Error: Internal registry not reachable at https://${INTERNAL_REGISTRY_URL}. Please ensure it is running and accessible."
    exit 1
fi
echo "Internal registry is reachable."
echo ""

# Step 2: Find and Get Operator Bundle Image
echo "Step 2: Finding and getting the operator bundle link from Brew..."
if [ -n "${BUILD_NAME}" ]; then
    BREW_BUILD_TO_USE="${BUILD_NAME}"
    echo "Using provided Brew build name: ${BUILD_NAME}"
else
    echo "Listing builds for ${OPERATOR_PACKAGE_NAME} and grepping for ${OPERATOR_VERSION_SEARCH}..."
    BREW_BUILD_TO_USE=$(brew list-builds  --package="${OPERATOR_PACKAGE_NAME}"  --state=COMPLETE --quiet --reverse | grep "${OPERATOR_VERSION_SEARCH}" | awk '{print $1}' | head -1)
fi

if [ -z "$BREW_BUILD_TO_USE" ]; then
    echo "Error: Could not determine the Brew build name. Please check the provided --build-name or the operator name and version combination."
    exit 1
fi

echo "Using Brew build: ${BREW_BUILD_TO_USE}"

OPERATOR_BUNDLE_IMAGE=$(brew --noauth call --json-output getBuild buildInfo="${BREW_BUILD_TO_USE}" 2>/dev/null | jq -r '.extra.image.index.pull[0]')

if [ -z "$OPERATOR_BUNDLE_IMAGE" ] || [[ "$OPERATOR_BUNDLE_IMAGE" == "null" ]]; then
    echo "Error: Could not extract the operator bundle image link from Brew build '${BREW_BUILD_TO_USE}'. Exiting."
    exit 1
fi

echo "Operator Bundle Image found: ${OPERATOR_BUNDLE_IMAGE}"
echo ""

# Step 3: Mirror the bundle image to your internal registry
echo "Step 3: Mirroring the bundle image to internal registry..."
OC_IMAGE_MIRROR_AUTH_FLAG="-a=${INTERNAL_REGISTRY_AUTH_FILE}"

if ! oc image mirror --insecure=true -a "${INTERNAL_REGISTRY_AUTH_FILE}" "${OPERATOR_BUNDLE_IMAGE}" "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_PACKAGE_NAME}:latest"; then
    echo "Error: Failed to mirror the bundle image. Exiting."
    exit 1
fi
echo "Bundle image mirrored successfully."
echo ""

# Step 4: Validate the bundle
echo "Step 4: Validating the bundle..."
if ! opm alpha bundle validate --tag "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_PACKAGE_NAME}:latest" --image-builder podman; then
    echo "Warning: BUNDLE VALIDATION FAILED. Continuing, but you might want to investigate."
fi
echo "Bundle validation complete."
echo ""

# Step 5: Build index image
echo "Step 5: Building the index image..."
if ! opm index add --skip-tls --bundles="${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_PACKAGE_NAME}:latest" --tag "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_NAME}-index:latest" -c podman; then
    echo "Error: Failed to build the index image. Exiting."
    exit 1
fi
echo "Index image built successfully."
podman images | grep "${OPERATOR_NAME}"-index
echo ""

# Step 6: Push index-image to local registry
echo "Step 6: Pushing index image to internal registry..."
if ! podman push "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_NAME}-index:latest" --authfile="${INTERNAL_REGISTRY_AUTH_FILE}" --tls-verify=false; then
    echo "Error: Failed to push the index image to the internal registry. Exiting."
    exit 1
fi
echo "Index image pushed successfully."
echo ""

# Step 7: Extract operator images links from index image and modify mappings
echo "Step 7: Extracting and modifying operator image links..."

mkdir -p "$OPERATOR_MANIFESTS_DIR"

if ! oc adm catalog mirror "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_NAME}-index:latest" "${INTERNAL_REGISTRY_URL}/operators" --insecure=true "${OC_IMAGE_MIRROR_AUTH_FLAG}" --manifests-only --to-manifests="${OPERATOR_MANIFESTS_DIR}" --path="/database/index.db:./"; then
    echo "Error: Failed to extract catalog manifests. Exiting."
    exit 1
fi
echo "Catalog manifests extracted to ${OPERATOR_MANIFESTS_DIR}/"
echo "Modifying mapping.txt and imageContentSourcePolicy.yaml..."

sed -i"${SED_IN_PLACE}" 's#registry.redhat.io/openshift4/#registry-proxy.engineering.redhat.com/rh-osbs/openshift-#g' "./${OPERATOR_MANIFESTS_DIR}/mapping.txt"
sed -i"${SED_IN_PLACE}" 's#openshift4-##g' "./${OPERATOR_MANIFESTS_DIR}/mapping.txt"
sed -i"${SED_IN_PLACE}" '/operator-bundle:latest/d' "./${OPERATOR_MANIFESTS_DIR}/mapping.txt" 
sed -i"${SED_IN_PLACE}" 's#openshift4-##g' "./${OPERATOR_MANIFESTS_DIR}/imageContentSourcePolicy.yaml"

echo "Image links modified successfully."
echo ""

# Step 8: Mirror operator's images to internal registry
echo "Step 8: Mirroring operator's images to internal registry based on modified mapping..."
if ! oc image mirror --insecure=true "${OC_IMAGE_MIRROR_AUTH_FLAG}" --filter-by-os=".*" --keep-manifest-list -f "./${OPERATOR_MANIFESTS_DIR}/mapping.txt"; then
    echo "Error: Failed to mirror operator images. Exiting."
    exit 1
fi
echo "Operator images mirrored successfully."
echo ""

# OCP Side Deployment

# Step 9: Add internal registry to allowed insecure registries on cluster
echo "Step 9: Adding internal registry to allowed insecure registries on cluster..."
if ! oc patch image.config.openshift.io/cluster --patch '{"spec":{ "registrySources": { "insecureRegistries" : ["'"${INTERNAL_REGISTRY_URL}"'"] }}}' --type=merge; then
    echo "Error: Failed to patch cluster image configuration. Exiting."
    exit 1
fi

# Step 10: Apply imageContentSourcePolicy.yaml
echo "Step 10: Applying imageContentSourcePolicy.yaml..."
if ! oc create -f "./${OPERATOR_MANIFESTS_DIR}/imageContentSourcePolicy.yaml"; then
    echo "Warning: imageContentSourcePolicy might already exist or failed to create. Continuing, but check your cluster status."
fi
echo "Waiting for 30 seconds for cluster nodes to restart after applying ImageContentSourcePolicy..."
sleep 30

echo "Waiting for 10 minutes for cluster nodes to restart after applying ImageContentSourcePolicy..."
if ! oc wait --for=condition=Updating=False --timeout=10m mcp --all; then
    echo "Warning: CatalogSource pod did not become ready in time. Check 'oc get pods -n openshift-marketplace | grep internal'." 
fi
echo ""

# Step 11: Disable all default catalog sources
echo "Step 11: Disabling all default catalog sources..."
if ! oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge; then
    echo "Error: Failed to patch operatorhub cluster. Exiting."
    exit 1
fi
echo "Operatorhub cluster patched."
echo ""

# Step 12: Create CatalogSource
echo "Step 12: Creating CatalogSource pointing to the internal registry..."

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: catalog-${OPERATOR_NAME}
  namespace: openshift-marketplace
spec:
  displayName: operator-images
  image: "${INTERNAL_REGISTRY_URL}/operators/${OPERATOR_NAME}-index:latest"
  publisher: Red Hat
  sourceType: grpc
EOF

if [ "${PIPESTATUS[1]}" -ne 0 ]; then
    echo "Error: Failed to create CatalogSource. Exiting."
    exit 1
fi
echo "CatalogSource created."
echo "Waiting for CatalogSource to report READY..."
CATALOG_READY_ATTEMPTS=60   
while :; do
    cs_state=$(oc -n openshift-marketplace get catalogsource "catalog-${OPERATOR_NAME}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    if [ "${cs_state}" = "READY" ]; then
        break
    fi
    CATALOG_READY_ATTEMPTS=$((CATALOG_READY_ATTEMPTS-1)) || true
    if [ "${CATALOG_READY_ATTEMPTS}" -le 0 ]; then
        echo "Warning: CatalogSource did not report READY within 60s. Continuing." 
        break
    fi
    sleep 2
done
echo "CatalogSource reported READY."
echo ""

# Step 13: Deploy Operator's namespace
echo "Step 13: Deploying operator's namespace (${OPERATOR_NAMESPACE})..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${OPERATOR_NAMESPACE}
  annotations:
    workload.openshift.io/allowed: management
EOF
if [ "${PIPESTATUS[1]}" -ne 0 ]; then
    echo "Warning: Namespace might already exist or failed to create."
fi
echo "Namespace created/ensured."
echo ""

# Step 14: Deploy OperatorGroup resource
echo "Step 14: Deploying OperatorGroup..."
if [ "${OPERATOR_GROUP_ALL_NAMESPACES}" = "true" ]; then
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF
else
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  targetNamespaces:
  - ${OPERATOR_NAMESPACE}
EOF
fi
if [ "${PIPESTATUS[1]}" -ne 0 ]; then
    echo "Warning: OperatorGroup might already exist or failed to create."
fi
echo "OperatorGroup created/ensured."
echo ""

# Step 15: Deploy Subscription
echo "Step 15: Deploying Subscription to internal registry..."
# Snapshot existing CSVs in namespace to detect a newly created one
existing_csvs=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: subscription-${OPERATOR_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: stable
  name: ${OLM_PACKAGE_NAME}
  source: catalog-${OPERATOR_NAME}
  sourceNamespace: openshift-marketplace
EOF
if [ "${PIPESTATUS[1]}" -ne 0 ]; then
    echo "Error: Failed to create Subscription. Exiting."
    exit 1
fi
echo "Subscription created."
echo "Waiting for operator CSV to be installed and running..."
# Wait for a newly created CSV (not present before Subscription) and then for it to reach Succeeded
echo "Waiting up to 60s for a NEW CSV to be created in ${OPERATOR_NAMESPACE}..."
NEW_CSV_NAME=""
CSV_CREATE_DEADLINE=$((SECONDS+60))
while [ ${SECONDS} -lt ${CSV_CREATE_DEADLINE} ]; do
    current_csvs=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)
    for name in ${current_csvs}; do
        case " ${existing_csvs} " in
            *" ${name} "*) ;; # existed before
            *) NEW_CSV_NAME="${name}"; break ;;
        esac
    done
    [ -n "${NEW_CSV_NAME}" ] && break
    sleep 2
done

if [ -n "${NEW_CSV_NAME}" ]; then
    echo "Detected new CSV: ${NEW_CSV_NAME}. Waiting for phase Succeeded (120s timeout)..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${NEW_CSV_NAME}" -n "${OPERATOR_NAMESPACE}" --timeout=120s; then
        echo "Warning: CSV ${NEW_CSV_NAME} did not reach 'Succeeded' phase in time. Check 'oc get csv ${NEW_CSV_NAME} -n ${OPERATOR_NAMESPACE} -o yaml'."
    fi
else
    echo "Warning: No new CSV detected within 60s. Proceeding to wait on any CSV in namespace."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n "${OPERATOR_NAMESPACE}" --timeout=120s; then
        echo "Warning: No CSV reached 'Succeeded' phase in time. Check 'oc get csv -n ${OPERATOR_NAMESPACE}'."
    fi
fi
oc get csv -n "${OPERATOR_NAMESPACE}"
echo ""

echo "${OPERATOR_NAME} operator installation script finished."
echo "You can check the operator's status with: oc get pods -n ${OPERATOR_NAMESPACE}"
echo "And CSV status with: oc get csv -n ${OPERATOR_NAMESPACE}"
