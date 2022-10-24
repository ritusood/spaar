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


function create_authz {
   local name=$1
   local namespace=$2
   local appName=$3
   local index=$4
   local url=$5
   local role=$6
   mkdir -p $WORKING_DIR/$appName
   cat << NET > $WORKING_DIR/$appName/$appName-$index-role-data.yaml
namespace: $namespace
customerName: $name
appName: $appName
index: $index
url: $url
role: $role
NET
    gomplate -d data=$WORKING_DIR/$appName/$appName-$index-role-data.yaml -f ./istio/app-authz-template-url.yaml > $WORKING_DIR/$appName/$appName-$index-istio.yaml

    # Apply app istio authorizations
    apply_cluster   $WORKING_DIR/$appName/$appName-$index-istio.yaml
}

function delete_authz {
    local name=$1
   local namespace=$2
   local appName=$3
   local index=$4
    delete_cluster $WORKING_DIR/$appName/$appName-$index-istio.yaml
    rm $WORKING_DIR/$appName/$appName-$index-istio.yaml
}


name="oops"
namespace="oops"
pop_location="oops"
app_name="oops"
index="oops"
url="oops"
role="oops"
host="oops"

while getopts ":v:" flag
do
    case "${flag}" in
        v) values=${OPTARG}
           index=$(./yq eval '.index' $values)
           name=$(./yq eval '.name' $values)
           namespace=$(./yq eval '.namespace' $values)
           app_name=$(./yq eval '.app' $values)
           url=$(./yq eval '.url' $values)
           role=$(./yq eval '.role' $values)
           destination_host=$(./yq eval '.host' $values)
           pop_location=$(./yq eval '.pop' $values) ;;
    esac
done
shift $((OPTIND-1))

WORKING_DIR=/tmp/$name
case "$1" in
    "create" )
        create_authz $name $namespace $app_name $index $url $role
    ;;
    "delete" )
        delete_authz $name $app_name
    ;;
    *)
    usage ;;
esac
