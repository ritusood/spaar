#!/bin/bash

# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2022 Intel Corporation

set -o errexit
set -o nounset
set -o pipefail



function install_packages {
    local name=$1
    local namespace=$2
    local domains=$3

    kubectl create ns $namespace
    http_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    https_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    http="http://$domains:$http_port/*"
    https="https://$domains:$https_port/*"
    echo $http $https
    jq '.realm = '\"$name\"' | .clients[].redirectUris[0] = '\"$http\"' | .clients[].redirectUris[1] = '\"$https\"''  keycloak/realm.json  > /tmp/realm.json
    cat << NET > /tmp/keycloak-data.yaml
    namespace: $namespace
NET
    gomplate -d data=/tmp/keycloak-data.yaml -f ./keycloak/keycloak.yaml | kubectl apply -f -

    sleep 30
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
    cat << NET > /tmp/oauth2-data.yaml
clientID: "oauth2-proxy"
namespace: $namespace
customer-name: $name
oidcIssuerUrl: $oidcIssuerUrl
redeemUrl: $redeemUrl
domainName: $domains
whitelistDomains: $whitelistDomains
redirectUrl: $redirectUrl
clientSecret: "lsuaCKsXRCQ0gID8BZHYK8tfAMlxP1cR"
cookieSecret: "UmRaMTlQajM1a2ordWFYRnlJb2tjWEd2MVpCK2grOFM="
secret: c1-keycloak-cert
whitelistDomains: $whitelistDomains
redirectUrl: $redirectUrl
caCommonName: customer1-ca
appName: app1
appDomainName: app1.customer1.com
destinationHost: httpbin.bar.cluster2
NET
gomplate -d data=/tmp/oauth2-data.yaml -f ./oath2-proxy/oauth2-proxy-template.yaml > /tmp/oauth2-cfg.yaml
}

function usage {
    echo "Usage: $0 -a app1:cluster1:cluster2 -b m3db:cluster1 -c app3:cluster3 create|cleanup"
}

function cleanup {
    rm -f yq
    rm -f *.tar.gz
    rm -f values.yaml
    rm -f emco-cfg.yaml
    rm -rf $OUTPUT_DIR
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

echo "Hi"
Name="oops"
namespace="oops"
# list of colon sperated values
domain_names="oops"
# list of clusters colon sperated values
pop_locations="oops"
dedicated_gateway="oops"

while getopts ":c:n:d:p:g:" flag
do
    case "${flag}" in
        n) namespace=${OPTARG};;
        c) Name=${OPTARG};;
        d) domain_names=${OPTARG};;
        p) pop_locations=${OPTARG};;
        g) dedicated_gateway=${OPTARG}
    esac
done
echo $Name $namespace $domain_names $pop_locations $dedicated_gateway
shift $((OPTIND-1))

input="hello"

#install_yq_locally
case "$1" in
     "add" )
        if [ "${Name}" == "oops" ] ; then
            echo -e "ERROR - Customer name is required"
            exit
        fi
        if [ "${namespace}" == "oops"  ] ; then
            echo -e "Error - Namespace is required"
            exit
        fi
        if [ "${domain_names}" == "oops" ] ; then
            echo -e "Atleast one 1 domain name must be provided"
            exit
        fi
        
        install_packages $Name $namespace $domain_names
        echo "Done create!!!"
        
        ;;
    "delete" )
        cleanup
    ;;
    *)
        usage ;;
esac
