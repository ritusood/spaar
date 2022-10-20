#!/bin/bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2022 Intel Corporation

set -o errexit
set -o nounset
set -o pipefail

KUBE_PATH=/home/vagrant/.kube/config
WORKING_DIR=/tmp

function apply_cluster {
#    local kubeconfig=$1
    local file=$1
    echo "Applying to cluster: $file"
    kubectl apply -f $file

}

function apply_cluster_namespace {
#    local kubeconfig=$1
    local file=$1
    local namespace=$2
    echo "Applying to cluster: $file"
    kubectl apply -f $file -n $namespace
}

function delete_cluster {
#    local kubeconfig=$1
    local file=$1
    echo "Deleting from cluster: $file"
    kubectl delete -f $file
}

function delete_cluster_namespace {
#    local kubeconfig=$1
    local file=$1
    local namespace=$2
    echo "Deleting from cluster: $file"
    kubectl delete -f $file -n $namespace
}


function create_app {
   local name=$1
   local namespace=$2
   local domain=$3
   local appName=$4
   local destinationHost=$5

   http_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
   https_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   http="$appName.$domain:$http_port"
   https="$appName.$domain:$https_port"

   appDomainName=$appName.$domain
   cat << NET > $WORKING_DIR/$appName-data.yaml
namespace: $namespace
customerName: $name
caCommonName: $name
appName: $appName
appDomainName: $appDomainName
http: $http
https: $https
destinationHost: $destinationHost
NET
   gomplate -d data=$WORKING_DIR/$appName-data.yaml -f ./certs/cert-template.yaml > $WORKING_DIR/$appName-cert.yaml
   gomplate -d data=$WORKING_DIR/$appName-data.yaml -f ./istio/app-gateway-vs-template.yaml > $WORKING_DIR/$appName-istio.yaml

    #Create cert  for the app
    apply_cluster   $WORKING_DIR/$appName-cert.yaml
    # Apply app istio resources including authorization
    apply_cluster   $WORKING_DIR/$appName-istio.yaml
}

function delete_app {
    local name=$1
    local appName=$2
    delete_cluster $WORKING_DIR/$appName-istio.yaml
    delete_cluster $WORKING_DIR/$appName-cert.yaml
    rm $WORKING_DIR/$appName-*.yaml
}


name="oops"
namespace="oops"
# list of colon sperated values
domain_name="oops"
# list of clusters colon sperated values
pop_location="oops"
dedicated_gateway="false"
app_name="oops"
destination_host="oops"

while getopts ":v:" flag
do
    case "${flag}" in
        v) values=${OPTARG}
           name=$(./yq eval '.name' $values)
           namespace=$(./yq eval '.namespace' $values)
           domain_name=$(./yq eval '.domain' $values)
           app_name=$(./yq eval '.app' $values)
           destination_host=$(./yq eval '.host' $values)
           dedicated_gateway=$(./yq eval '.dedicatedGateway' $values)
           pop_location=$(./yq eval '.pop' $values) ;;
    esac
done
echo $name $namespace $domain_name $pop_location $dedicated_gateway
shift $((OPTIND-1))

WORKING_DIR=/tmp/$name
case "$1" in
    "create" )
        create_app $name $namespace $domain_name $app_name $destination_host
    ;;
    "delete" )
        delete_app $name $app_name
    ;;
    *)
    usage ;;
esac
