#! /usr/bin/env bash

# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

source istio.env

# Check if all required variables are non-null
# Globals:
#   None
# Arguments:
#   VAR - The variable to check
# Returns:
#   None
variable_is_set() {
  if [[ -z "${VAR}" ]]; then
    echo "Variable is not set. Please check your istio.env file."
    return 1
  fi
  return 0
}

# Check if required binaries exist
# Globals:
#   None
# Arguments:
#   DEPENDENCY - The command to verify is installed.
# Returns:
#   None
dependency_installed () {
  command -v "${1}" >/dev/null 2>&1 || exit 1
}

# Helper function to enable a given service for a given project
# Globals:
#   None
# Arguments:
#   PROJECT - ID of the project in which to enable the API
#   API     - Name of the API to enable, e.g. compute.googleapis.com
# Returns:
#   None
enable_project_api() {
  gcloud services enable "${2}" --project "${1}"
}

# Provide the default values for the variables
for VAR in "${ISTIO_CLUSTER}" "${ZONE}" "${REGION}" "${GCE_NETWORK}" \
           "${GCE_SUBNET}" "${GCE_SUBNET_CIDR}" "${ISTIO_NETWORK}" \
           "${ISTIO_SUBNET}" "${ISTIO_SUBNET_CIDR}" \
           "${ISTIO_SUBNET_CLUSTER_CIDR}" "${ISTIO_SUBNET_SERVICES_CIDR}" \
           "${GCE_VM}"; do
  variable_is_set "${VAR}"
done

# Ensure the necessary dependencies are installed
if ! dependency_installed "gcloud"; then
  echo "I require gcloud but it's not installed. Aborting."
fi

if ! dependency_installed "kubectl"; then
  echo "I require gcloud but it's not installed. Aborting."
fi

if ! dependency_installed "curl" ; then
  echo "I require curl but it's not installed. Aborting."
fi

if [[ "${ISTIO_PROJECT}" == "" ]]; then
  echo "ISTIO_PROJECT variable in istio.env is not set to a valid project. Aborting..."
  exit 1
fi

if [[ ${GCE_PROJECT} == "" ]]; then
  echo "GCE_PROJECT variable in istio.env is not set to a valid project. Aborting..."
  exit 1
fi

enable_project_api "${ISTIO_PROJECT}" compute.googleapis.com
enable_project_api "${ISTIO_PROJECT}" container.googleapis.com
enable_project_api "${GCE_PROJECT}" compute.googleapis.com

# Setup Terraform
terraform init

# Deploy infrastructure using Terraform
terraform apply -var "istio_project=${ISTIO_PROJECT}" \
  -var "gce_project=${GCE_PROJECT}" \
  -var "istio_cluster=${ISTIO_CLUSTER}" \
  -var "zone=${ZONE}" \
  -var "region=${REGION}" \
  -var "gce_network=${GCE_NETWORK}" \
  -var "gce_subnet=${GCE_SUBNET}" \
  -var "gce_subnet_cidr=${GCE_SUBNET_CIDR}" \
  -var "istio_network=${ISTIO_NETWORK}" \
  -var "istio_subnet=${ISTIO_SUBNET}" \
  -var "istio_subnet_cidr=${ISTIO_SUBNET_CIDR}" \
  -var "istio_subnet_cluster_cidr=${ISTIO_SUBNET_CLUSTER_CIDR}" \
  -var "istio_subnet_services_cidr=${ISTIO_SUBNET_SERVICES_CIDR}" \
  -var "gce_vm=${GCE_VM}" --auto-approve

# Check for required Istio components and download if necessary
if [[ ! -d "$(pwd)/istio-${ISTIO_VERSION}" ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then
    export OS_TYPE="linux"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    export OS_TYPE="osx"
  fi

  curl -L --remote-name https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istio-$ISTIO_VERSION-$OS_TYPE.tar.gz

  # extract istio
  tar -xzf istio-$ISTIO_VERSION-$OS_TYPE.tar.gz

  # remove istio zip
  rm istio-$ISTIO_VERSION-$OS_TYPE.tar.gz
fi

# Setup kubectl with the credentials for the newly created cluster
gcloud container clusters get-credentials "${ISTIO_CLUSTER}" --zone "${ZONE}" \
  --project "${ISTIO_PROJECT}"

if [[ ! "$(kubectl get clusterrolebinding --field-selector metadata.name=cluster-admin-binding \
                                          -o jsonpath='{.items[*].metadata.name}')" ]]; then
  kubectl create clusterrolebinding cluster-admin-binding \
    --clusterrole=cluster-admin --user="$(gcloud config get-value core/account)"
fi

# The setupMeshEx.sh script requires that all calls made to it happen from the
# root of the Istio directory so changing directory to it.
pushd "istio-${ISTIO_VERSION}" || exit

# Add the istioctl binary to the path
export PATH="${PWD}/bin:${PATH}"

# Install Istio into the cluster
kubectl apply -f ./install/kubernetes/istio-demo.yaml

# Install the ILBs necessary for mesh expansion
kubectl apply -f ./install/kubernetes/mesh-expansion.yaml

# Start of mesh expansion

# Export variables that will be used by the setupMeshEx script
export GCP_OPTS="--zone ${ZONE} --project ${ISTIO_PROJECT}"
export SERVICE_NAMESPACE=vm
./install/tools/setupMeshEx.sh generateClusterEnv "${ISTIO_CLUSTER}"

# Turn off the Istio auth to prevent auth issues
#if [[ "${ISTIO_AUTH_POLICY}" == "NONE" ]] ; then
sed -i'' -e "s/CONTROL_PLANE_AUTH_POLICY=MUTUAL_TLS/CONTROL_PLANE_AUTH_POLICY=NONE/g" cluster.env
#fi

# Generate the DNS configuration necessary to have the GCE VM join the mesh.
./install/tools/setupMeshEx.sh generateDnsmasq

# Create the namespace to be used by the service on the VM.
kubectl apply -f ../namespaces.yaml

# Re-export the GCP_OPTS to switch the project to the project where the VM
# resides
export GCP_OPTS="--zone ${ZONE} --project ${GCE_PROJECT}"
# Setup the Istio service proxy and service on the GCE VM
./install/tools/setupMeshEx.sh gceMachineSetup "${GCE_VM}"

# Mesh expansion completed

# Register the external service with the Istio mesh
istioctl register -n vm mysqldb "$(gcloud compute instances describe "${GCE_VM}" \
  --format='value(networkInterfaces[].networkIP)' --project "${GCE_PROJECT}" --zone "${ZONE}")" 3306

# Install the bookinfo services and deployments and set up the initial Istio
# routing. For more information on routing see this Istio blog post:
# https://istio.io/blog/2018/v1alpha3-routing/
kubectl apply -f <(istioctl kube-inject -f ./samples/bookinfo/platform/kube/bookinfo.yaml)
kubectl apply -f <(istioctl kube-inject -f ./samples/bookinfo/platform/kube/bookinfo-ratings-v2-mysql-vm.yaml)
istioctl create -f ./samples/bookinfo/networking/bookinfo-gateway.yaml
istioctl create -f ./samples/bookinfo/networking/virtual-service-all-v1.yaml

# Change the routing to point to the most recent versions of the bookinfo
# microservices
istioctl replace -f ./samples/bookinfo/networking/virtual-service-ratings-mysql-vm.yaml
istioctl replace -f ./samples/bookinfo/networking/virtual-service-reviews-v3.yaml
kubectl apply -f ./samples/bookinfo/networking/destination-rule-all.yaml                                                                                                                                              
kubectl apply -f ./samples/bookinfo/networking/virtual-service-all-v1.yaml                                                                                                                                            
istioctl kube-inject -n bookinfo -f ./samples/bookinfo/platform/kube/bookinfo-ratings-v2-mysql-vm.yaml | kubectl apply -n bookinfo -f -                                                                               
kubectl apply -n bookinfo -f ./samples/bookinfo/networking/virtual-service-ratings-mysql-vm.yaml                                                                                                                      
kubectl apply -f ./samples/bookinfo/networking/virtual-service-reviews-v3.yaml
popd || exit

# Install and deploy the database used by the Istio service
gcloud compute ssh "${GCE_VM}" --project="${GCE_PROJECT}" \
  --zone "${ZONE}" \
  -- "$(cat setup-gce-vm.sh)"

# Get the information about the gateway used by Istio to expose the BookInfo
# application
INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o \
  jsonpath='{.status.loadBalancer.ingress[0].ip}')
INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o \
  jsonpath='{.spec.ports[?(@.name=="http")].port}')
GATEWAY_URL="${INGRESS_HOST}:${INGRESS_PORT}"

echo "You can view the service at http://${GATEWAY_URL}/productpage"
