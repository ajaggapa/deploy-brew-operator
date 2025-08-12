# deploy-brew-operator
# Deploying the SR-IOV Operator on a Disconnected Cluster

This document explains how to use the provided script to deploy the SR-IOV Operator to an OpenShift cluster that is not connected to the internet. The script automates the process of fetching the correct operator version from a local image registry and authenticating with that registry.

---

## Prerequisites

Before you run this script, make sure you have the following ready:

* **A valid `kubeconfig` file:** This file must have the necessary permissions to deploy resources to your cluster. The script uses the `KUBECONFIG` environment variable to find this file.
* **An internal image registry:** The operator images must be available in a local registry that your cluster can access.
* **Authentication secret:** A single `json` file that contains the credentials required to pull images from your internal registry.

---

## Usage

To deploy the operator, run the script with the following flags. You'll need to replace the example values with your specific information.

```bash
./deploy-sriov-operator.sh \
--version v4.20 \
--internal-registry registry.hlxcl14.lab.eng.tlv2.redhat.com:5000 \
--internal-registry-auth /home/kni/combined-secret.json
