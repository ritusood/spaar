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

function  install_prereq {
   local name=$1
   local namespace=$2
   local domains=$3
   local idp_server=$4

   if [[ $(kubectl get ns $namespace)  ]]; then
      echo "Namespace $namespace exists"
   else
      kubectl create ns $namespace
      echo "Namespace $namespace created"
   fi
   # Create Data file
   generate_data $name $namespace $domains $idp_server
   # Create yamls for ca-issuer, istio-gateway and keycloak
   gomplate -d data=$WORKING_DIR/data.yaml -f ./certs/ca-template.yaml > $WORKING_DIR/ca-issuer.yaml
   helm template istio-ingressgateway-$name -n $namespace istio/gateway > $WORKING_DIR/istio-gateway.yaml
   kubectl create cm -n $namespace keycloak-configmap --from-file=$WORKING_DIR/realm.json -o yaml --dry-run=client > $WORKING_DIR/keycloak-cm.yaml
   gomplate -d data=$WORKING_DIR/data.yaml -f ./keycloak/keycloak.yaml > $WORKING_DIR/keycloak.yaml
    
    if [ "${resouces_only}" == "false" ] ; then
    #Create namespace and cert issuer for the customer
        echo "install Istio Ingress and Keycloak broker"
        apply_cluster   $WORKING_DIR/ca-issuer.yaml
        #Install Istio
        apply_cluster   $WORKING_DIR/istio-gateway.yaml
        #Install Keycloak cm
        apply_cluster   $WORKING_DIR/keycloak-cm.yaml
        #Install Keycloak
        apply_cluster   $WORKING_DIR/keycloak.yaml
    fi
}

function  install_oauth2 {
   local name=$1
   local namespace=$2

   
   generate_oauth2_data $name $namespace
   # Install oauth2-proxy for the customer
   gomplate -d data=$WORKING_DIR/data.yaml -f ./oath2-proxy/oauth2-proxy-template.yaml > $WORKING_DIR/oauth2-cfg-data.yaml
   helm template --namespace $namespace --values $WORKING_DIR/oauth2-cfg-data.yaml oauth2-proxy oauth2-proxy/oauth2-proxy > $WORKING_DIR/oauth2-proxy.yaml
   # Apply KNCC CR to update Istio Configmap for the newly installed oath2-proxy
   gomplate -d data=$WORKING_DIR/data.yaml -f ./oath2-proxy/configctrl.yaml > $WORKING_DIR/kncc-istio-cm.yaml
    if [ "${resouces_only}" == "false" ] ; then
        echo "install_oauth2"
        #Install oauth2-proxy
        apply_cluster_namespace   $WORKING_DIR/oauth2-proxy.yaml $namespace
    fi
}


function  generate_data {
    local name=$1
    local namespace=$2
    local domains=$3
    local idp_server=$4

    http_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    https_port=$(kubectl -n lbns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    http="http://$domains:$http_port/*"
    https="https://$domains:$https_port/*"
    token_url="http://$idp_server/realms/users/protocol/openid-connect/token"
    authorization_url="http://$idp_server/realms/users/protocol/openid-connect/auth"
    jq '.realm = '\"$name\"' | .clients[].redirectUris[0] = '\"$http\"' | .clients[].redirectUris[1] = '\"$https\"' | .identityProviders[].config.tokenUrl = '\"$token_url\"' | .identityProviders[].config.authorizationUrl = '\"$authorization_url\"''  keycloak/realm.json  > $WORKING_DIR/realm.json

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
    hostip=$(echo $hosts | cut -d ' ' -f1| tr -d ' ')
    kc_port=$(kubectl -n $namespace get service keycloak -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
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

function create_istio_policies {
   local name=$1
   
   # Install Request Authentication
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/request-auth-template.yaml > $WORKING_DIR/outer-istio.yaml
   # Install oauth configuration
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/oauth-config-template.yaml >> $WORKING_DIR/outer-istio.yaml
   # Install outer gateway configuration for the customer
   gomplate -d data=$WORKING_DIR/data.yaml -f ./istio/outer-gateway-vs-template.yaml >> $WORKING_DIR/outer-istio.yaml
   
}

function create_packages {
   local name=$1
   local namespace=$2
   local domains=$3
   local idp_server=$4
   local resouces_only=$5

   if [ -d "$WORKING_DIR" ]; then rm -Rf $WORKING_DIR; fi
   mkdir -p $WORKING_DIR
   install_prereq $name $namespace $domains $idp_server $resouces_only
   install_oauth2 $name $namespace $resouces_only
}

function create_istio {
   local name=$1
   local namespace=$2
   local domains=$3
   local resouces_only=$4

   create_istio_policies $name

    if [ "${resouces_only}" == "false" ] ; then
        apply_cluster   $WORKING_DIR/kncc-istio-cm.yaml
        #Install Istio resources for the customer
        apply_cluster   $WORKING_DIR/outer-istio.yaml            
    fi

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
resouces_only="false"
com="oops"

while getopts ":v:" flag
do
    case "${flag}" in
        v) values=${OPTARG}
           name=$(yq eval '.name' $values)
           namespace=$(yq eval '.namespace' $values)
           domain_name=$(yq eval '.domain' $values)
           dedicated_gateway=$(yq eval '.dedicatedGateway' $values)
           pop_location=$(yq eval '.pop' $values)
           idp_server=$(yq eval '.idp' $values);;
    esac
done

shift $((OPTIND-1))
WORKING_DIR=/tmp/$name
case "$1" in
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
        create_packages $name $namespace $domain_name $idp_server $resouces_only
        create_istio $name $namespace $domain_name $resouces_only
        echo "Customer $name resources created"
        ;;
    "delete" )
        delete_istio $name $namespace
        delete_packages $name $namespace
        echo "Customer $name resources deleted"
    ;;
    *)
        usage ;;
esac
