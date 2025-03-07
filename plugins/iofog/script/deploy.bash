#!/bin/bash

set -e

BOOTSTRAP_AGENTS="$1"

OS=$(uname -s | tr A-Z a-z)
SCRIPT=plugins/iofog/script
ANSIBLE=plugins/iofog/ansible
export KUBECONFIG=conf/kube.conf

# Wait for Kubernetes cluster
"$SCRIPT"/wait-for-pods.bash kube-system

# Helm
helm init --wait
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
kubectl rollout status --watch deployment/tiller-deploy -n kube-system
helm repo add iofog https://eclipse-iofog.github.io/helm
helm repo update iofog

# ioFog core on Kubernetes
kubectl create namespace iofog

helm install iofog/iofog --set-string \
controller.image="$CONTROLLER_IMG",\
connector.image="$CONNECTOR_IMG"

echo "Waiting for Controller Pod..."
"$SCRIPT"/wait-for-pods.bash iofog name=controller

echo "Waiting for Controller LoadBalancer IP..."
IP=$("$SCRIPT"/wait-for-lb.bash iofog controller)
PORT=51121
TOKEN=$("$SCRIPT"/get-controller-token.bash "$IP" "$PORT")

helm install iofog/iofog-k8s --set-string \
controller.token="$TOKEN",\
scheduler.image="$SCHEDULER_IMG",\
operator.image="$OPERATOR_IMG",\
kubelet.image="$KUBELET_IMG"


# Get GKE Controller and Connector IPs and save to config files
CTRL_IP=$("$SCRIPT"/wait-for-lb.bash iofog controller)
echo "$CTRL_IP":51121 > conf/controller.conf
CNCT_IP=$("$SCRIPT"/wait-for-lb.bash iofog connector)
echo "$CNCT_IP":8080 > conf/connector.conf

# Agents
"$SCRIPT"/add-agent-hosts.bash $(cat conf/agents.conf)

if [ "$OS" == "darwin" ]; then
	sed -i '' -e "s/controller_ip=.*/controller_ip=$CTRL_IP/g" "$ANSIBLE"/hosts
else
	sed -i "s/controller_ip=.*/controller_ip=$CTRL_IP/g" "$ANSIBLE"/hosts
fi
if [ "$BOOTSTRAP_AGENTS" = "True" ]; then
	ANSIBLE_CONFIG="$ANSIBLE" ansible-playbook -i "$ANSIBLE"/hosts "$ANSIBLE"/bootstrap.yml
fi
ANSIBLE_CONFIG="$ANSIBLE" ansible-playbook -i "$ANSIBLE"/hosts "$ANSIBLE"/init.yml