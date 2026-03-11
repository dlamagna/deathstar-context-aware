#!/bin/bash
set -e

### === CONFIGURATION === ###
POD_CIDR="10.244.0.0/16"
USER_HOME="/home/$(whoami)"
SOCIAL_NETWORK_DIR="$USER_HOME/DeathStarBench/socialNetwork/k8s"
### ====================== ###

# 1. Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# 2. Install containerd
apt update && apt install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 3. Enable kernel modules & sysctl params
modprobe overlay
modprobe br_netfilter

tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# 4. Install Kubernetes tools
apt-get update && apt-get install -y apt-transport-https curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/kubernetes-apt-keyring.gpg

echo 'deb https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# 5. Initialize cluster
kubeadm init --pod-network-cidr=${POD_CIDR} --skip-token-print

# 6. Configure kubectl for user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 7. Install Flannel CNI
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# 8. Allow master to run pods
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# 9. Install Helm
curl https://baltocdn.com/helm/signing.asc | sudo tee /etc/apt/trusted.gpg.d/helm.asc > /dev/null
echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt update
sudo apt install helm -y

