#!/bin/bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2022 Intel Corporation

set -o errexit
set -o nounset
set -o pipefail

KUBE_PATH=/home/vagrant/.kube/config
WORKING_DIR=/tmp

function global_install {

   apply_cluster   ./certs/clusterissuer.yaml
   if [[ $(kubectl get ns lbns)  ]]; then
      echo "Namespace lbns exists"
   else
      kubectl create ns lbns
      echo "Namespace lbns created"
   fi
   helm install istio-ingressgateway-lb -n lbns istio/gateway
}

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

function  install_prereq {
   local name=$1
   local namespace=$2
   local domains=$3

   echo "install_prereq"
   if [[ $(kubectl get ns $namespace)  ]]; then
      echo "Namespace $namespace exists"
   else
      kubectl create ns $namespace
      echo "Namespace $namespace created"
   fi
   # Create Data file
   generate_data $name $namespace $domains
   # Create yamls for ca-issuer, istio-gateway and keycloak
   gomplate -d data=$WORKING_DIR/data.yaml -f ./certs/ca-template.yaml > $WORKING_DIR/ca-issuer.yaml
   helm template istio-ingressgateway-$name -n $namespace istio/gateway > $WORKING_DIR/istio-gateway.yaml
   kubectl create cm -n $namespace keycloak-configmap --from-file=$WORKING_DIR/realm.json -o yaml --dry-run=client > $WORKING_DIR/keycloak-cm.yaml
   gomplate -d data=$WORKING_DIR/data.yaml -f ./keycloak/keycloak.yaml > $WORKING_DIR/keycloak.yaml

   #Create namespace and cert issuer for the customer
    apply_cluster   $WORKING_DIR/ca-issuer.yaml
    #Install Istio
    apply_cluster   $WORKING_DIR/istio-gateway.yaml
    #Install Keycloak cm
    apply_cluster   $WORKING_DIR/keycloak-cm.yaml
    #Install Keycloak
    apply_cluster   $WORKING_DIR/keycloak.yaml
}

function  install_oauth2 {
   local name=$1
   local namespace=$2

   echo "install_oauth2"
   generate_oauth2_data $name $namespace
   # Install oauth2-proxy for the customer
   gomplate -d data=$WORKING_DIR/data.yaml -f ./oath2-proxy/oauth2-proxy-template.yaml > $WORKING_DIR/oauth2-cfg-data.yaml
   helm template --namespace $namespace --values $WORKING_DIR/oauth2-cfg-data.yaml oauth2-proxy oauth2-proxy/oauth2-proxy > $WORKING_DIR/oauth2-proxy.yaml
   # Apply KNCC CR to update Istio Configmap for the newly installed oath2-proxy
   gomplate -d data=$WORKING_DIR/data.yaml -f ./oath2-proxy/configctrl.yaml > $WORKING_DIR/kncc-istio-cm.yaml

   sleep 10
    #Install oauth2-proxy
    apply_cluster_namespace   $WORKING_DIR/oauth2-proxy.yaml $namespace
    #Update the istio cm with kncc
}


function  generate_data {
    local name=$1
    local namespace=$2
    local domains=$3


    http_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    https_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    http="http://$domains:$http_port/*"
    https="https://$domains:$https_port/*"
    echo $http $https
    jq '.realm = '\"$name\"' | .clients[].redirectUris[0] = '\"$http\"' | .clients[].redirectUris[1] = '\"$https\"''  keycloak/realm.json  > $WORKING_DIR/realm.json

    whitelistDomains=.$domains:*
    redirectUrl="https://$domains:$https_port/oauth2/callback"
    istioHosts='"'*.$domains'"'

    cat << NET > $WORKING_DIR/data.yaml
namespace: $namespace
customerName: $name
domainName: $domains
whitelistDomains: $whitelistDomains
redirectUrl: $redirectUrl
istioHosts: $istioHosts
NET

}

function generate_oauth2_data {
    local name=$1
    local namespace=$2

    clientID="oauth2-proxy"
    hosts=`hostname -I`
    echo $hosts
    hostip=$(echo $hosts | cut -d ' ' -f1| tr -d ' ')
    echo $hostip
    kc_port=$(kubectl -n $namespace get service keycloak -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
    echo $hostip:$kc_port
    oidcIssuerUrl="http://$hostip:$kc_port/realms/$name"
    redeemUrl="$oidcIssuerUrl/protocol/openid-connect/token"
    jwksUri="$oidcIssuerUrl/protocol/openid-connect/certs"

    cat << NET >> $WORKING_DIR/data.yaml
clientID: $clientID
oidcIssuerUrl: $oidcIssuerUrl
redeemUrl: $redeemUrl
jwksUri: $jwksUri
clientSecret: "lsuaCKsXRCQ0gID8BZHYK8tfAMlxP1cR"
cookieSecret: "UmRaMTlQajM1a2ordWFYRnlJb2tjWEd2MVpCK2grOFM="
NET

}

function install_istio_policies {
   local name=$1
   # Install Request Authentication
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/request-auth-template.yaml > $WORKING_DIR/outer-istio.yaml
   # Install oauth configuration
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/oauth-config-template.yaml >> $WORKING_DIR/outer-istio.yaml
   # Install outer gateway configuration for the customer
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/outer-gateway-vs-template.yaml >> $WORKING_DIR/outer-istio.yaml

   #Install Istio resources for the customer
    apply_cluster   $WORKING_DIR/outer-istio.yaml
}

function create_app {
   local name=$1
   local namespace=$2
   local domain=$3
   local appName=$4
   local role=$5
   local destinationHost=$6

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
role: $role
destinationHost: $destinationHost
NET
   gomplate -d data=$WORKING_DIR/$appName-data.yaml -f ./certs/cert-template.yaml > $WORKING_DIR/$appName-cert.yaml
   gomplate -d data=$WORKING_DIR/$appName-data.yaml -f ./istio/app-gateway-vs-template.yaml > $WORKING_DIR/$appName-istio.yaml
   gomplate -d data=$WORKING_DIR/$appName-data.yaml -f ./istio/app-authz-template.yaml >> $WORKING_DIR/$appName-istio.yaml

    #Create cert  for the app
    apply_cluster   $WORKING_DIR/$appName-cert.yaml
    # Apply app istio resources including authorization
    apply_cluster   $WORKING_DIR/$appName-istio.yaml
    echo "Use URL --> $http $https"
}

function delete_app {
    local name=$1
    local appName=$2
    delete_cluster $WORKING_DIR/$appName-istio.yaml
    delete_cluster $WORKING_DIR/$appName-cert.yaml
    rm $WORKING_DIR/$appName-*.yaml
}

function create_packages {
   local name=$1
   local namespace=$2
   local domains=$3

   if [ -d "$WORKING_DIR" ]; then rm -Rf $WORKING_DIR; fi
   mkdir -p $WORKING_DIR
   install_prereq $name $namespace $domains
   install_oauth2 $name $namespace
}

function create_istio {
   local name=$1
   local namespace=$2
   local domains=$3

   apply_cluster   $WORKING_DIR/kncc-istio-cm.yaml
   install_istio_policies $name
}

function delete_packages {
    local name=$1
    local namespace=$2

    delete_cluster_namespace $WORKING_DIR/oauth2-proxy.yaml $namespace
    delete_cluster $WORKING_DIR/keycloak.yaml
    delete_cluster $WORKING_DIR/keycloak-cm.yaml
    delete_cluster $WORKING_DIR/istio-gateway.yaml
    delete_cluster $WORKING_DIR/ca-issuer.yaml
}
function delete_istio {
    local name=$1
    local namespace=$2

    delete_cluster $WORKING_DIR/outer-istio.yaml
    delete_cluster $WORKING_DIR/kncc-istio-cm.yaml

}

# Install yq for parsing yaml files. It installs it locally (current folder) if it is not
# already present. The rest of this script uses this local version (so as to not conflict
# with other versions potentially installed on the system already.
function install_yq_locally {
    if [ ! -x ./yq ]; then
        echo 'Installing yq locally'
        VERSION=v4.12.0
        BINARY=yq_linux_amd64
        wget https://github.com/mikefarah/yq/releases/download/${VERSION}/${BINARY} -O yq && chmod +x yq
fi
}

name="oops"
namespace="oops"
# list of colon sperated values
domain_name="oops"
# list of clusters colon sperated values
pop_location="oops"
dedicated_gateway="false"
app_name="oops"
role="oops"
destination_host="oops"

install_yq_locally
while getopts ":v:" flag
do
    case "${flag}" in
        v) values=${OPTARG}
           name=$(./yq eval '.name' $values)
           namespace=$(./yq eval '.namespace' $values)
           domain_name=$(./yq eval '.domain' $values)
           app_name=$(./yq eval '.app' $values)
           role=$(./yq eval '.role' $values)
           destination_host=$(./yq eval '.host' $values)
           dedicated_gateway=$(./yq eval '.dedicatedGateway' $values)
           pop_location=$(./yq eval '.pop' $values);;
    esac
done
echo $name $namespace $domain_name $pop_location $dedicated_gateway
shift $((OPTIND-1))

WORKING_DIR=/tmp/$name
case "$1" in
     "prepare" )
        global_install;;
    "createPackages" )
        if [ "${name}" == "oops" ] ; then
            echo -e "ERROR - Customer name is required"
            exit
        fi
        if [ "${namespace}" == "oops"  ] ; then
            echo -e "Error - Namespace is required"
            exit
        fi
        if [ "${domain_name}" == "oops" ] ; then
            echo -e "Atleast one 1 domain name must be provided"
            exit
        fi
        create_packages $name $namespace $domain_name
        echo "Done create!!!"
        ;;
     "createIstio" )
        if [ "${name}" == "oops" ] ; then
            echo -e "ERROR - Customer name is required"
            exit
        fi
        if [ "${namespace}" == "oops"  ] ; then
            echo -e "Error - Namespace is required"
            exit
        fi
        if [ "${domain_name}" == "oops" ] ; then
            echo -e "Atleast one 1 domain name must be provided"
            exit
        fi
        create_istio $name $namespace $domain_name
        echo "Done create!!!"
        ;;
    "deletePackages" )
        delete_packages $name $namespace
        ;;
     "deleteIstio" )
        delete_istio $name $namespace
        ;;
     "create" )
        if [ "${name}" == "oops" ] ; then
            echo -e "ERROR - Customer name is required"
            exit
        fi
        if [ "${namespace}" == "oops"  ] ; then
            echo -e "Error - Namespace is required"
            exit
        fi
        if [ "${domain_name}" == "oops" ] ; then
            echo -e "Atleast one 1 domain name must be provided"
            exit
        fi
        create_packages $name $namespace $domain_name
        create_istio $name $namespace $domain_name
        echo "Done create!!!"
        ;;
    "delete" )
        delete_istio $name $namespace
        delete_packages $name $namespace
    ;;
    "addapp" )
        create_app $name $namespace $domain_name $app_name $role $destination_host
    ;;
    "delapp" )
        delete_app $name $app_name
    ;;
    *)
        usage ;;
esac
