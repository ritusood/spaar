# Config

## Overview of steps

Some questions:
1)	On step 3bx is Public IP for the customer an input?
2)	Step 4ai will this input be cluster name?
3)	5bc not sure what this step was?
4)	Step 5div want to confirm that coreDNS needs to be updated in this step. AFAIK KNCC can’t be used for that, is that correct?

Steps for setting up Scenario 1 Demo
1.	Bring up 4 clusters
2.	Prepare clusters with common elements
    a.	Istio Ingress Proxy Gateway (for LB)
    b.	VPN Gateway
3.	For each new customer:
a.	Inputs  
    i.	Domain name, namespace, 
    ii.	Set of Public DNS servers info, 
    iii.	Set of private DNS server (PowerDNS) info
b.	Get cluster names for the customer and do below steps for each cluster
    i.	Add Gateway and VirtualService resource for the outer Istio Ingress Proxy (LB)
    ii.	Create namespace for the customer
    iii. Deploy keycloak broker for the customer
    iv.	Deploy Istio Ingress gateway in the new namespace
    v.	Deploy oauth2-proxy in the new namespace
    vi.	Configure oauth2-proxy
    vii. Configure Keycloak
    viii.	Edit configmap of Ingress Proxy (LB) to add oauth2-proxy extensionProvider
    ix.	If Public IP then deploy and configure VPN gateway else Configure common VPN Gateway for customer specific info (GRE tunnels, iptables etc.)

4.	Add customer DC
    a.	Inputs - 
        i.	Primary ZTNA instance to connect 
        ii.	Secondary ZTNA instance(optional)
    b.	Automate IPSec tunnel creation b/w ZTNA and DC for both Primary and secondary instances
5.	Add an app per customer:
    a.	Input – ZTNA instances to configure for this app, external domain name for the app, port number assignment
    b.	Input - Internal application IP addresses or domain names.
    c.	Update Public DNS Server (try this out)
i.	Update Public IP
d.	Istio configuration 
    i.	Create Gateway and Virtual Service 
    ii.	Create Public key/ Private key pair and then create secret in customer namespace (cert-manager reachability info)
    iii.	Add Gateway and VirtualService resource for the inner Istio Ingress Proxy for the app
    iv.	Create Service entries for the app running on external cluster if IP address or if domain name update the coreDNS.
1.	VirtualService with host IP address (try this out)
2.	Check Istio DNS capabilities, check whether Virtual service can use external domain name if DNS can be resolved.
6.	Attach roles authorization Per application (Check users group(?) if possible)
a.	Input – application name, role
b.	Add Authorization policy for the role



## Setup environment

### Install Kubernetes

sudo apt update
    3  sudo apt install software-properties-common curl gnupg
    4  sudo apt-get install docker.io
    5  sudo systemctl status docker
     12  sudo vi /etc/docker/daemon.json
   13  sudo systemctl status docker
   14  sudo systemctl daemon-reload
	   15  sudo systemctl restart docker
   18  sudo systemctl status docker
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
    7  sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
curl-shttps://packages.cloud.google.com/apt/dists/kubernetes-xenial/main/binary-amd64/Packages|grepVersion|awk'{print $2}'

From <https://stackoverflow.com/questions/49721708/how-to-install-specific-version-of-kubernetes> 

sudo apt-get install -q kubeadm=1.23.9-00
sudo apt-get install -q kubelet=1.23.9-00
sudo apt-get install -q kubectl=1.23.9-00

    8  sudo apt-get install kubeadm kubelet kubectl
    9  sudo apt-mark hold kubeadm kubelet kubectl
   10  kubeadm version
   11  sudo kubeadm init --pod-network-cidr=10.244.0.0/16

kubectl taint node edge4 node-role.kubernetes.io/master:NoSchedule-
{ "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries": ["172.25.103.10:5000"]
}


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

```

  export ISTIO_VERSION=1.15.1
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
  export PATH=$PATH:/home/vagrant/istio-1.15.1/bin
  istioctl version
  istioctl install -f istio-cfg.yaml



```



```

apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiooperator-config
  namespace: istio-system
spec:
  profile: minimal
  meshConfig:
    accessLogFile: /dev/stdout
    enableAutoMtls: true
    defaultConfig:
      proxyMetadata:
        # Enable Istio agent to handle DNS
        ISTIO_META_DNS_CAPTURE: "true"
  components:
    # Enable Istio Ingress gateway
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        env:
          - name: ISTIO_META_ROUTER_MODE
            value: "sni-dnat"
        service:
          type: NodePort
          ports:
            - port: 80
              targetPort: 8080
              name: http2
            - port: 443
              targetPort: 8443
              name: https
            - port: 15443
              targetPort: 15443
              name: tls
              nodePort: 32001
  values:
    global:
      pilotCertProvider: istiod


```

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

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```


### Install Keycloak broker for the customer

```

 helm repo add codecentric https://codecentric.github.io/helm-charts
 helm install -n c1-ns keycloak --set postgresql.enabled=false --set service.type=NodePort codecentric/keycloak

 https://www.keycloak.org/docs-api/11.0/rest-api/index.html

 curl --location --request POST 'http://<keycloak url>/auth/realms/master/protocol/openid-connect/token' --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'grant_type=password' --data-urlencode 'client_id=admin-cli' --data-urlencode 'username=admin' --data-urlencode 'password=admin' --data-urlencode 'client_secret=<secret>'


kubectl create cm -n c1-ns keycloak-configmap --from-file=inner/c1/realm.json
jq '.realm = "customer1" | .clients[].redirectUris[0] = "http://customer1.com:31519/*" | .clients[].redirectUris[1] = "https://customer1.com:31518/*"'  ../../keycloak/releam.json  > releam.json
gomplate -d data=./inner/c1/keycloak-data.yaml -f ./keycloak/keycloak.yaml | kubectl apply -f -

 
```


### Install Oauth2-proxy for the customer

```
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests

helm install --namespace c1-ns --values oauth2-proxy-config.svc.yaml oauth2-proxy oauth2-proxy/oauth2-proxy

```

 wget https://github.com/hairyhenderson/gomplate/releases/download/v3.11.2/gomplate_linux-amd64
  sudo mv gomplate_linux-amd64 /usr/local/bin/gomplate
  sudo chmod +x /usr/local/bin/gomplate
  sudo apt-get install jq


gomplate -d data=./inner/c1/keycloak-data.yaml -f ./keycloak/keycloak.yaml | kubectl apply -f -

 jq '.realm = "customer1" | .clients[].redirectUris[0] = "http://customer1.com:31519/*" | .clients[].redirectUris[1] = "https://customer1.com:31518/*"'  ../../keycloak/releam.json  > releam.json


 helm install --namespace c1-ns --values inner/c1/oauth2-cfg.yaml oauth2-proxy oauth2-proxy/oauth2-proxy

kubectl  get secrets root-secret -n c2ns -o yaml | grep ca.crt | awk '{print $2}' | base64 -d > /vagrant/ca.crt