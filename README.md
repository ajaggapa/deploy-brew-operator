## Overview

`deploy-operator.sh` mirrors an operator from Brew to your internal registry, builds and pushes an index image, creates a custom CatalogSource, and installs the operator via OLM on your OpenShift cluster. This script supports only 4 operators: sriov-operator, metallb-operator, ptp-operator and nmstate-operator

## Prerequisites

- Logged into the target OpenShift cluster with cluster-admin privileges (`oc login`)
- Tools installed and on PATH: `oc`, `podman`, `opm`, `brew`, `jq`
- `KUBECONFIG` environment variable pointing to your cluster kubeconfig
- Reachable internal registry and auth file (e.g., Podman/OC credentials JSON)

Notes:
- This script uses insecure transport flags for dev/lab registries. Use trusted TLS in production.
- The script disables default OperatorHub sources and applies an ImageContentSourcePolicy to prefer mirrored images.

## Usage

```bash
KUBECONFIG=<path/to/kubeconfig> ./deploy-operator.sh \
  --internal-registry <host:port> \
  --internal-registry-auth <path/to/auth.json> \
  --operator <sriov|metallb|ptp|nmstate> \
  --version <vX.Y>
```

Optional flags:
- `--build-name <brew_build_name>`: use a specific Brew build instead of auto-selecting by version
- `--operator-ns <namespace>`: override the default namespace (normally auto-set per operator)

Operator mapping:
- sriov → brew: `sriov-network-operator-metadata-container`, OLM: `sriov-network-operator`, ns: `openshift-sriov-network-operator`
- metallb → brew: `ose-metallb-operator-bundle-container`, OLM: `metallb-operator`, ns: `metallb-system` (all-namespaces OperatorGroup)
- ptp → brew: `ose-ptp-operator-metadata-container`, OLM: `ptp-operator`, ns: `openshift-ptp`
- nmstate → brew: `ose-kubernetes-nmstate-operator-bundle-container`, OLM: `kubernetes-nmstate-operator`, ns: `openshift-nmstate`

## Examples

### sriov
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-operator.sh \
  --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --operator sriov \
  --version v4.20
```

### metallb
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-operator.sh \
  --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --operator metallb \
  --version v4.20
```

### nmstate
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-operator.sh \
  --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --operator nmstate \
  --version v4.20
```

### ptp
```bash
KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
./deploy-operator.sh \
  --internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 \
  --internal-registry-auth /home/kni/combined-secret.json \
  --operator ptp \
  --version v4.20
```

## What the script does

- Mirrors the selected operator bundle to the internal registry
- Validates the bundle, builds an index image, and pushes it to the internal registry
- Extracts and adjusts mirroring manifests, mirrors all required operator images
- Patches cluster Image config (adds internal registry as insecure) and applies ImageContentSourcePolicy
- Disables default OperatorHub sources
- Creates a CatalogSource pointing at the internal index image and waits for readiness
- Ensures namespace and OperatorGroup, then creates a Subscription
- Detects the newly created CSV for the operator and waits for phase `Succeeded`

## Verify

```bash
oc get catalogsource -n openshift-marketplace catalog-<operator>
oc get subscription -n <operator-namespace>
oc get csv -n <operator-namespace>
oc get pods -n <operator-namespace>
```

## Troubleshooting

- Ensure `oc login` as a user with cluster-admin
- Confirm registry reachability and credentials
- If runs are slow after ImageContentSourcePolicy, wait for MCP to finish updating
- The script prints each command (`set -x`) to aid debugging


