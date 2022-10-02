#!/bin/bash
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
function  install_packages {
    local name=$1
    local namespace=$2
    local domains=$3

    #kubectl create ns $namespace
    http_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    https_port=$(kubectl -n lb-ns get service istio-ingressgateway-lb -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
    http="http://$domains:$http_port/*"
    https="https://$domains:$https_port/*"
    echo $http $https
    jq '.realm = '\"$name\"' | .clients[].redirectUris[0] = '\"$http\"' | .clients[].redirectUris[1] = '\"$https\"''  keycloak/realm.json  > /tmp/realm.json
    cat << NET > /tmp/keycloak-data.yaml
    namespace: $namespace
NET
   kubectl create cm -n $namespace keycloak-configmap --from-file=/tmp/realm.json
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
caCommonName: customer1-ca
appName: app1
appDomainName: app1.customer1.com
destinationHost: httpbin.bar.cluster2
NET
gomplate -d data=/tmp/oauth2-data.yaml -f ./oath2-proxy/oauth2-proxy-template.yaml > /tmp/oauth2-cfg.yaml
helm install --namespace $namespace --values /tmp/oauth2-cfg.yaml oauth2-proxy oauth2-proxy/oauth2-proxy
}

function  uninstall_packages {
    local name=$1
    local namespace=$2
    
    gomplate -d data=/tmp/keycloak-data.yaml -f ./keycloak/keycloak.yaml | kubectl delete -f -
    kubectl delete cm -n $namespace keycloak-configmap 
    helm uninstall --namespace $namespace  oauth2-proxy

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
install_packages "customer1" "c1ns" "customer1.com"
echo "hello $Name!"
