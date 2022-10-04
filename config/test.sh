#!/bin/bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2022 Intel Corporation

set -o errexit
set -o nounset
set -o pipefail

############################################################
# Help                                                     #
############################################################
Help()
{
   # Display Help
   echo "Add description of the script functions here."
   echo
   echo "Syntax: scriptTemplate [-g|h|v|V]"
   echo "options:"
   echo "g     Print the GPL license notification."
   echo "h     Print this Help."
   echo "v     Verbose mode."
   echo "V     Print software version and exit."
   echo
}

function global_install {
   kubectl apply -f ./certs/clusterissuer.yaml
   kubectl create ns lbns
   helm install istio-ingressgateway -n lbns istio/gateway
}


function  create_packages {
   local name=$1
   local namespace=$2
   local domains=$3

   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./certs/ca-template.yaml > /tmp/$name/ca-issuer.yaml
   helm template istio-ingressgateway -n $namespace istio/gateway > /tmp/$name/istio-gateway.yaml
   kubectl create cm -n $namespace keycloak-configmap --from-file=/tmp/$name/realm.json -o yaml --dry-run=client > /tmp/$name/keycloak-cm.yaml
   gomplate -d data=/tmp/$name/keycloak-data.yaml -f ./keycloak/keycloak.yaml > /tmp/$name/keycloak.yaml

   sleep 30
   
   # Install oauth2-proxy for the customer
   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./oath2-proxy/oauth2-proxy-template.yaml > /tmp/$name/oauth2-cfg-data.yaml
   helm template --namespace $namespace --values /tmp/$name/oauth2-cfg-data.yaml oauth2-proxy oauth2-proxy/oauth2-proxy > /tmp/$name/oauth2-proxy.yaml
   # Apply KNCC CR to update Istio Configmap for the newly installed oath2-proxy
   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./oath2-proxy/configctrl.yaml > /tmp/$name/kncc-istio-cm.yaml
}

function  generate_data {
    local name=$1
    local namespace=$2
    local domains=$3

 
    http_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    https_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    http="http://$domains:$http_port/*"
    https="https://$domains:$https_port/*"
    echo $http $https
    jq '.realm = '\"$name\"' | .clients[].redirectUris[0] = '\"$http\"' | .clients[].redirectUris[1] = '\"$https\"''  keycloak/realm.json  > /tmp/$name/realm.json
    cat << NET > /tmp/$name/keycloak-data.yaml
    namespace: $namespace
NET
    hosts=`hostname -I` 
    echo $hosts
    hostip=$(echo $hosts | cut -d ' ' -f1| tr -d ' ')
    echo $hostip
    kc_port=$(kubectl -n $namespace get service keycloak -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
    echo $hostip:$kc_port
    oidcIssuerUrl="http://$hostip:$kc_port/realms/$name"
    redeemUrl="$oidcIssuerUrl/protocol/openid-connect/token"
    whitelistDomains=.$domains:*
    redirectUrl="https://$domains:$https_port/oauth2/callback"
    clientID="oauth2-proxy-$namespace"
    istioHosts='"'*.$domains'"'
    jwksUri="$oidcIssuerUrl/protocol/openid-connect/certs"
    cat << NET > /tmp/$name/oauth2-data.yaml
clientID: $clientID
namespace: $namespace
customerName: $name
oidcIssuerUrl: $oidcIssuerUrl
redeemUrl: $redeemUrl
domainName: $domains
whitelistDomains: $whitelistDomains
redirectUrl: $redirectUrl
istioHosts: $istioHosts
jwksUri: $jwksUri
clientSecret: "lsuaCKsXRCQ0gID8BZHYK8tfAMlxP1cR"
cookieSecret: "UmRaMTlQajM1a2ordWFYRnlJb2tjWEd2MVpCK2grOFM="
NET

}
function create_istio_policies {
   local name=$1
   # Install Request Authentication
   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./istio/request-auth-template.yaml > /tmp/$name/outer-istio.yaml
   # Install oauth configuration
   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./istio/oauth-config-template.yaml >> /tmp/$name/outer-istio.yaml
   # Install outer gateway configuration for the customer
   gomplate -d data=/tmp/$name/oauth2-data.yaml -f ./istio/outer-gateway-vs-template.yaml >> /tmp/$name/outer-istio.yaml
}

function create_app_resources {
   local name=$1
   local namespace=$2
   local domain=$3
   local appName=$4
   local role=$5
   local destinationHost=$6

   http_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
   https_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   http="$appName.$domain:$http_port"
   https="$appName.$domain:$https_port"
   echo $http $https
   
   appDomainName=$appName.$domain
   cat << NET > /tmp/$name/$appName-data.yaml
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
   gomplate -d data=/tmp/$name/$appName-data.yaml -f ./certs/cert-template.yaml > /tmp/$name/$appName-cert.yaml
   gomplate -d data=/tmp/$name/$appName-data.yaml -f ./istio/app-gateway-vs-template.yaml > /tmp/$name/$appName-istio.yaml
   gomplate -d data=/tmp/$name/$appName-data.yaml -f ./istio/app-authz-template.yaml >> /tmp/$name/$appName-istio.yaml
}

function  install_customer {
    local name=$1
    
    #Create namespace and cert issuer for the customer
    kubectl apply -f /tmp/$name/ca-issuer.yaml
    #Install Istio 
    kubectl apply -f /tmp/$name/istio-gateway.yaml
    #Install Keycloak cm
    kubectl apply -f /tmp/$name/keycloak-cm.yaml
    #Install Keycloak
    kubectl apply -f /tmp/$name/keycloak.yaml
    sleep 10
    #Install oauth2-proxy
    kubectl apply -f /tmp/$name/oauth2-proxy.yaml
    #Update the istio cm with kncc
    kubectl apply -f /tmp/$name/kncc-istio-cm.yaml
    #Install Istio resources for the customer
    kubectl apply -f /tmp/$name/outer-istio.yaml
}

function  uninstall_customer {
    local name=$1
    
    kubectl delete -f /tmp/$name/outer-istio.yaml
    kubectl delete -f /tmp/$name/kncc-istio-cm.yaml
    kubectl delete -f /tmp/$name/oauth2-proxy.yaml
    kubectl delete -f /tmp/$name/keycloak.yaml
    kubectl delete -f /tmp/$name/keycloak-cm.yaml
    kubectl delete -f /tmp/$name/istio-gateway.yaml
    kubectl delete -f /tmp/$name/ca-issuer.yaml
    
}


function create_customer_resources {
   local name=$1
   local namespace=$2
   local domains=$3

   mkdir -p /tmp/$name
   generate_data $name $namespace $domains
   create_packages $name $namespace $domains
   create_istio_policies $name

}

############################################################
############################################################
# Main program                                             #
############################################################
############################################################

# Set variables
Name="world"

############################################################
# Process the input options. Add options as needed.        #
############################################################
# Get the options
while getopts ":hn:" option; do
   case $option in
      h) # display Help
         Help
         exit;;
      n) # Enter a name
         Name=$OPTARG;;
     \?) # Invalid option
         echo "Error: Invalid option"
         exit;;
   esac
done

create_customer_resources "customer1" "c1ns" "customer1.com"
create_app_resources "customer1" "c1ns" "customer1.com" "app1" "user" "httpbin.bar.cluster2"
install_customer "customer1"
echo "hello $Name!"
