#!/bin/bash
# set -x
## editable variables
local_as="64512"
k8s_cidr="10.244.0.0/16"


##########################
target_repository="$HOSTNAME:8443"
## DEFINING FUNCTIONS, scroll down to the bottom
setup_docker_registry_certs(){
    current_ip=$(hostname -I | awk '{print $1}')
    if [ ! -n "$(grep -P "${current_ip}[[:space:]]+$HOSTNAME" "/etc/hosts")" ]; then
        echo -e "$currnet_ip $HOSTNAME" | sudo tee -a "/etc/hosts" > /dev/null
    fi    
    sudo mkdir -p /etc/docker/cert.d/"$target_repository"/
    tee openssl.cnf >/dev/null <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $HOSTNAME
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = $HOSTNAME
IP.1 = 127.0.0.1
IP.2 = $current_ip
EOF
    sudo openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
    -keyout /etc/docker/cert.d/"$target_repository"/myCA.key \
    -out /etc/docker/cert.d/"$target_repository"/myCA.crt \
    -config openssl.cnf -extensions v3_req
    ## Cleanup
    rm openssl.cnf

    ## Set permissions
    sudo chmod 644 /etc/docker/cert.d/"$target_repository"/myCA.crt
    sudo chmod 644 /etc/docker/cert.d/"$target_repository"/myCA.key
    sudo cp /etc/docker/cert.d/"$target_repository"/* /usr/local/share/ca-certificates/
    sudo update-ca-certificates
}
install_base(){
## update and upgrade packages
    sudo apt update && sudo apt upgrade -y

    ## Kubernetes requires that swap is off and never comes back on
    sudo swapoff -a
    sudo sed -i '/swap/s/^/#/' /etc/fstab
    sudo mkdir -p /mnt/disks/ssd1
    ## Setup configuration for the containerd serivce
    sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
    sudo modprobe overlay
    sudo modprobe br_netfilter

    ## setup configuration for host network forwarding to kubernetes
    sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    sudo sysctl --system

    ## install containerd runtime dependencies
    sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates net-tools

    ## enable docker repository
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y

    ## install containerd and docker
    sudo apt update
    sudo apt install -y containerd.io docker-registry docker-ce-cli docker-ce

    ## configure containerd and set to to start useing systemd cgroup
    containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
    sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

    ## restart and endable containerd
    sudo systemctl restart containerd
    sudo systemctl enable containerd

    ## add apt repository for KLubernetes
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    ## install kubernetes
    sudo apt update
    sudo apt install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
}
install_calico(){
    curl https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml -O
    kubectl apply -f calico.yaml
    sudo curl -L https://github.com/projectcalico/calico/releases/download/v3.31.4/calicoctl-linux-amd64 -o /usr/local/bin/calicoctl
    sudo chmod +x /usr/local/bin/calicoctl

    cat << EOF | calicoctl create -f -
    apiVersion: projectcalico.org/v3
    kind: BGPConfiguration
    metadata:
      name: default
    spec:
      logSeverityScreen: Info
      nodeToNodeMeshEnabled: true
      asNumber: $local_as
EOF
}

## setup Docker Registry
setup_docker_registry(){
    check_password="uiewqazybnenm.zjklwoyew3"  ## dummy password for logic
    read -p "What do you want to use as the local docker registry username: " docker_username
    while [[ $docker_password != $check_password ]]; do
        read -sp "What do you want to use as the local docker registry password: " docker_password && echo
        read -sp "Verify password: " check_password && echo
        if [[ $docker_password != $check_password ]]; then
            echo -e "\nOOPS, passwords do not match, try again\n"
        fi
    done
    sudo mkdir -p /etc/docker/registry/
    
    sudo tee /etc/docker/registry/config.yml >/dev/null <<EOF
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/docker-registry
  delete:
    enabled: true
http:
  addr: :8443
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /etc/docker/cert.d/${target_repository}/myCA.crt
    key: /etc/docker/cert.d/${target_repository}/myCA.key
  auth:
    htpasswd:
      realm: basic-realm
      path: /etc/docker/registry/.htpasswd
health:
  storagedriver:
    enabled: true
    interval: 10s
EOF
    ## assign password to the docker registry
    sudo htpasswd -Bbc /etc/docker/registry/.htpasswd $docker_username $docker_password
    ## create kubernetes service account for logging into local docker registry
    kubectl create namespace fortiaigate
    kubectl patch serviceaccount default -n fortiaigate -p '{"imagePullSecrets": [{"name": "$target_repository"}]}'
    kubectl create secret docker-registry docker-imagepull -n fortiaigate --docker-server=$target_repository --docker-username=$docker_username --docker-password=$docker_password
    ## Reset Docker Registry Service
    sudo systemctl stop docker-registry.service
    sudo systemctl start docker-registry.service
    sleep 1s
    sudo usermod -aG docker $USER
    newgrp docker
}


## run below on master node only
install_master(){
    setup_docker_registry_certs
    install_base
    ## install helm
    sudo apt-get install curl gpg apt-transport-https apache2-utils -y
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install helm -y

    ## Initialize Master Node
    sudo kubeadm init --pod-network-cidr $k8s_cidr

    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    ## Apply Network configuration
    echo "Waiting for Nodes to be ready...."
    kubectl wait --for=condition=Ready node --all --timeout=60s
    curl https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml -O
    kubectl apply -f calico.yaml

    ## install calico commandline tool
    install_calico

    ## For auto completion run the following commands
    sudo apt-get install bash-completion -y
    echo 'source <(kubectl completion bash)' >>~/.bashrc
    echo 'source <(docker completion bash)' >>~/.bashrc
    source ~/.bashrc # Reload the shell configuration
    setup_docker_registry

    ## Single host?
    read -p "Would you like this install to be a single host (only master) deployment? (note: requires 16 cpu cores, 48gig ram and 300g hd)" answer
    if [[ ${answer,,} == "y" || ${answer,,} == "single" || ${answer,,} == "yes" ]]; then
        kubectl taint nodes --all node-role.kubernetes.io/control-plane-
        echo -e "Success!!! You can now move on to importing images to the registry."
    else
        ## reprint join command at the end for easy access
        echo -e "\n\t\tSuccess!!! You can now move on to importing images to the registry.
        Join new worker nodes to the cluster with the command below after running
        'Install Worker Config'.\n"
        
        kubeadm token create --print-join-command
        echo "^^^^^^^^^^^^^^^^^^^^^^^SAVE THIS COMMAND^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
    fi
}

install_worker(){
    ## check to see if the master node is reachable
    read -p "What is the IP address of the master node?" master_ip
    read -p "What is the name of the master node?" master_name
    read -p "What is the admin username of the master node?" master_username
    while ! ping -c 1 "$master_ip"; do
        echo "$master_ip is not responding to icmp."
        read -p "Are you sure the ip is $master_ip? Enter again: " master_ip
    done
    echo -e "Attempting to login...\nWhat is the master admin password so we can pull and trust the repository cert?"
    sudo scp $master_admin@$master_ip:/etc/docker/cert.d/"$target_repository"/* \
    /etc/docker/cert.d/"$target_repository"/
    sudo chmod 644 /etc/docker/cert.d/"$target_repository"/myCA.crt
    sudo chmod 644 /etc/docker/cert.d/"$target_repository"/myCA.key
    sudo cp /etc/docker/cert.d/"$target_repository"/* /usr/local/share/ca-certificates/
    sudo update-ca-certificates


    ## Add host lookup for master
    echo -e "$master_ip $master_name" | sudo tee -a "/etc/hosts" > /dev/null
    ## install base configuration
    install_base
    
    echo -e "Next you need to join the worker to the master node with the kubeadm join command you got at the
end of the master install. After that, you are done here. Everything else is installed and
controlled from the master control-plane node."
    exit 0
}

install_ingress_controller(){
    read -p "Would you like to use nginx (n)? or HAProxy (h)?" choice
    if [[ $choice == "n" ]]; then
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        helm repo update
        helm install ingress-nginx ingress-nginx/ingress-nginx --create-namespace --namespace ingress-nginx
    elif [[ $choice == "h" ]]; then
        helm repo add haproxytech https://haproxytech.github.io/helm-charts
        helm repo update
        echo "Pulling and installing... This might take a bit"
        helm install haproxy-kubernetes-ingress haproxytech/kubernetes-ingress --create-namespace \
        --namespace haproxy-controller
    else
        echo "None selected, Will continue without installing ingress controller."
    fi
}


create_persistent_volume(){
    ## create, or recreate the kubectl persistant volume
    if kubectl get pv fortiaigate-pv > /dev/null 2>&1; then
        read -p "pv exsists, would you like to delete and recreate it? (y/n): " renew_pv
        if [[ "${renew_pv,,}" == "y" ]]; then
            kubectl delete pv fortiaigate-pv
            echo "please ssh into nodes and manually delete the contents of /mnt/disks/ssd1/"
        fi
    fi
    READY_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | 
    .type=="Ready" and .status=="True") | .metadata.name')
    ready_nodes=()
    while IFS= read -r line || [ -n "$line" ]; do
        # Double quotes around "$line" preserve spaces and newlines
        ready_nodes+=("$line")
    done <<< "$READY_NODES"
    node_list=$(printf "          - %s\\n" "${ready_nodes[@]}")
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: fortiaigate-pv
spec:
  capacity:
    storage: 30Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteMany
  persistentVolumeReclaimPolicy: Delete
  storageClassName:
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
${node_list}

EOF
    sleep 1
    kubectl get pv -o wide
}

## Sets for one basic BGP peer. See calico documentation for BGP filters and advanced setup
set_bgp_peer(){
    read -p "BGP peer ip? (x.x.x.x): " peer_ip
    read -p "BGP peer as?          : " peer_as
    cat << EOF | calicoctl apply -f -
    apiVersion: projectcalico.org/v3
    kind: BGPPeer
    metadata:
        name: default
    spec:
        peerIP: $peer_ip
        asNumber: $peer_as
EOF
    calico get bgppeer && calico get bgpconfiguration
}

## Review docker images for all fortiaigate images and tag them in the repository for use by k8s cluster
push_fortiaigate(){
    docker_images=$(docker images --format json)
    echo "--------Reviewing all fortiaigate images and taging them in the repository for use by k8s cluster------------"
    while IFS= read -r item; do
        repository=$(echo "$item" | jq -r '.Repository')
        if [[ $repository == *"docker-fortiaigate-local"* ]]; then
            image="${repository##*/}"
            tag=$(echo "$item" | jq -r '.Tag')
            tag_lower=${tag,,}
            docker tag "$repository:$tag" "$target_repository/$image:$tag_lower"
            echo "Successfully tagged $image"
            docker push "$target_repository/$image:$tag_lower"
            echo "Done pushing $image."
        fi
    done <<< "$docker_images"
}
## in curent folder, find all .tar docs and load them to docker unless its the helm chart... extract that and clean up
import_fortiaigate(){
    read -p "Are the images already loaded to docker?(y/n): " lp
    if [[ ${lp,,} == "n" ]]; then    
        docker login $target_repository
        for file in *.tar; do
            if [[ "$file" == *"helm"* ]]; then
                echo "Found the helm chart, Extracting it!"
                tar -xf $file
                echo "Done Extracting, Cleaning up helm"
                rm $file
            else
                echo -n "loading $file "
                docker load -i $file &
                PID=$!
                while kill -0 $PID 2>/dev/null; do
                    echo -n "."
                    sleep 1
                done
            fi
        done
    fi
    push_fortiaigate
}
install_fortiaigate(){
    read -p "Do you want to edit values.yaml first? (y/n): " edit_values
    while [[ "${edit_values,,}" != "n" ]]; do 
        nano ./fortiaigate/values.yaml
        read -p "Edit values.yaml again? (y/n): " edit_values
    done
    helm install fortiaigate ./fortiaigate -n fortiaigate -f ./fortiaigate/values.yaml 2>/dev/null || \
    helm upgrade fortiaigate ./fortiaigate -n fortiaigate -f ./fortiaigate/values.yaml
    echo -e "\nSuccess!! Now run 'kubectl get pods -n fortiaigate' to check the status of the cluster"
    exit 0
}

start(){
    ##### START OF PROGRAM #####
    echo "
___________            __  .__   _____  .__  ________        __
\_   _____/___________/  |_|__| /  _  \ |__|/  _____/_____ _/  |_  ____
 |    __)/  _ \_  __ \   __\  |/  /_\  \|  /   \  ___\__  \\\   __\/ __ \ 
 |     \(  <_> )  | \/|  | |  /    |    \  \    \_\  \/ __ \|  | \  ___/
 \___  / \____/|__|   |__| |__\____|__  /__|\______  (____  /__|  \___  >
     \/                               \/           \/     \/          \/
  _________       __                 ___________           .__
 /   _____/ _____/  |_ __ ________   \__    ___/___   ____ |  |
 \_____  \_/ __ \   __\  |  \____ \    |    | /  _ \ /  _ \|  |
 /        \  ___/|  | |  |  /  |_> >   |    |(  <_> |  <_> )  |__
/_______  /\___  >__| |____/|   __/    |____| \____/ \____/|____/
        \/     \/           |__|
    - Built by Paul Pogreba"
    echo -e "\nThis program is designed to work on a clean base install of Ubuntu Server 24.04 LTS.
This program will help to setup a master and worker nodes. If you choose multi node
cluster, join the worker(s) to the cluster before you continue to the other steps.
Run this script from inside the folder where all the downloaded .tar files reside for
a complete operational install of FortiAiGate. If you run this with 'sudo' please exit
and relaunch without elevated privilages. You will be asked for your sudo password later.\n
  Docs for the deployment of FortiAiGate can be found at
https://docs.fortinet.com/document/fortiaigate/8.0.0/fortiaigate-administration-guide/512071/fortiaigate-deployment \n"

    OPTIONS=("Install Master Config" "Install Worker Config" "Import Images to local registry" "Install Ingress Controller" \
    "Create PersistentVolume" "Install FortiAiGate" "Uninstall FortiAiGate" "Set Bgp Peer" "Exit")
    PS3="Which option do you want? (1 -${#OPTIONS[@]}): "


    select option in "${OPTIONS[@]}"; do
        case "$option" in
            "Install Master Config") install_master;;
            "Install Worker Config") install_worker;;
            "Import Images to local registry") import_fortiaigate;;
            "Install Ingress Controller") install_ingress_controller;;
            "Create PersistentVolume") create_persistent_volume;;
            "Install FortiAiGate") install_fortiaigate;;
            "Set Bgp Peer") set_bgp_peer;;
            "Uninstall FortiAiGate") helm uninstall fortiaigate -n fortiaigate;;
            "Exit") exit 0;;
            *) echo -e "\nNOPE! please make a valid selection" && sleep 1s && start;;
        esac
    done
}

start
exit 0
