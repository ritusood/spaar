# Config

## Setup environment

### Install helm

```
wget https://get.helm.sh/helm-v3.9.1-linux-amd64.tar.gz
tar -zxvf helm-v3.9.1-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
  
```
Add repo for istio

```
https://istio.io/latest/docs/setup/install/helm/

helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

```

### Deploy Istio

## LB Setup

Create namespace for the load balancer proxy

```
    kubectl apply -f config/setup.yaml

```


### Deploy LB istio ingress gateway


Install helm chart for istio/gateway

```
    helm install istio-ingressgateway-lb -n lb-ns istio/gateway

```

## Add Customer

Create namespace for the customer

```
    kubectl apply -f config/inner/c1/setup.yaml

```


### Install helm chart for istio/gateway for the customer

```
    helm install istio-ingressgateway-c1 -n c1-ns istio/gateway

```

### Certs

```
 helm repo add jetstack https://charts.jetstack.io


```


### Install Keycloak broker for the customer

```

 helm repo add codecentric https://codecentric.github.io/helm-charts
 helm install -n c1-ns keycloak --set postgresql.enabled=false --set service.type=NodePort codecentric/keycloak

 https://www.keycloak.org/docs-api/11.0/rest-api/index.html

 curl --location --request POST 'http://<keycloak url>/auth/realms/master/protocol/openid-connect/token' --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=password' --data-urlencode 'client_id=admin-cli' --data-urlencode 'username=admin' --data-urlencode 'password=admin' --data-urlencode 'client_secret=<secret>'

 192.168.121.187

```


### Install Oauth2-proxy for the customer

```
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests

helm install --namespace c1-ns --values oauth2-proxy-config.svc.yaml oauth2-proxy oauth2-proxy/oauth2-proxy

```