#!/bin/bash

# Function to check if a command exists
check_command() {
    [ -x "$(command -v $1)" ] && return 0 || return 1
}

# Function to install a dependency if it's not already present
install_dependency() {
    if ! check_command "$1"; then
        echo "Installing $1..."
        source "./install/$1.sh" && "install_$1" || {
            echo "Error: Failed to install $1"
            exit 1
        }
    fi
}

# Function to create a Kubernetes namespace if it doesn't exist
create_namespace() {
    local ns="$1"
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Creating namespace $ns..."
        kubectl create namespace "$ns"
    fi
}

# Ensure required files and environment variables exist
[ -f "./argocd-private-repo" ] || { echo "Error: SSH key for ArgoCD not found."; exit 1; }
[ -f .env ] || { echo "Error: .env file not found!"; exit 1; }

source .env || { echo "Error: Failed to load .env file!"; exit 1; }

[ -n "$DOCKER_USERNAME" ] && [ -n "$DOCKER_PASSWORD" ] || {
    echo "Error: DOCKER_USERNAME or DOCKER_PASSWORD is not set in .env file."
    exit 1
}

[ -n "$ARGOCD_PASSWORD" ] || {
    echo "Error: ARGOCD_PASSWORD is not set in .env file."
    exit 1
}

# Define default values for Kubernetes settings
CLUSTER_NAME=${K8S_CLUSTER_NAME:-cluster-app}
APP_NAMESPACE=${K8S_APP_NAMESPACE:-app}
APP_PORT=${K8S_APP_PORT:-8888}
ARGOCD_NAMESPACE=${K8S_ARGOCD_NAMESPACE:-argocd}
ARGOCD_PORT=${K8S_ARGOCD_PORT:-8080}

# Setting error options for the script
set -e
set -u

# Install necessary tools and utilities
for tool in docker minikube helm kubectl argocd netcat; do
    install_dependency "$tool"
done

MINIKUBE_STATUS=$(minikube status -p $CLUSTER_NAME --format '{{.Host}}' 2>/dev/null)

# Start Minikube if not running
if [[ "$MINIKUBE_STATUS" != "Running" ]]; then
    echo "Starting Minikube cluster named $CLUSTER_NAME..."
    minikube start -p $CLUSTER_NAME || { 
        echo "Error: Failed to start Minikube with cluster name $CLUSTER_NAME!"; 
        exit 1; 
    }
    kubectl config use-context $CLUSTER_NAME
else
    echo "Minikube cluster named $CLUSTER_NAME is already running."
fi

# Create necessary namespaces
create_namespace $APP_NAMESPACE
create_namespace $ARGOCD_NAMESPACE

# Deploy ArgoCD if not deployed
if ! kubectl get deployment argocd-server -n $ARGOCD_NAMESPACE >/dev/null 2>&1; then
    kubectl create -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || {
        echo "Error: Failed to install ArgoCD" >&2
        exit 1
    }
fi

echo "Waiting for argoCD..."
kubectl wait --timeout 600s --for=condition=Ready pods --all -n $ARGOCD_NAMESPACE

if kubectl get secret github-private-repo-ssh -n $ARGOCD_NAMESPACE >/dev/null 2>&1; then
    echo "Removing existing github-private-repo-ssh secret..."
    kubectl delete secret github-private-repo-ssh -n $ARGOCD_NAMESPACE
fi

echo "Creating github-private-repo-ssh secret..."
kubectl -n $ARGOCD_NAMESPACE create secret generic github-private-repo-ssh --from-file=sshPrivateKey=./argocd-private-repo

if kubectl get secret dockerhub-credentials -n $APP_NAMESPACE >/dev/null 2>&1; then
    echo "Removing dockerhub-credentials secret..."
    kubectl delete secret dockerhub-credentials -n $APP_NAMESPACE
fi

echo "Creating dockerhub-credentials secret..."
kubectl create secret docker-registry dockerhub-credentials \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=$DOCKER_USERNAME \
    --docker-password=$DOCKER_PASSWORD \
    -n $APP_NAMESPACE

helm template app-chart k8s-manifests/app-chart -f k8s-manifests/app-chart/values.yaml | kubectl apply -f -

echo "Waiting for argoCD..."
kubectl wait --timeout 600s --for=condition=Ready pods --all -n $ARGOCD_NAMESPACE

kubectl port-forward svc/argocd-server -n $ARGOCD_NAMESPACE $ARGOCD_PORT:443 &
PF_ARGO_PID=$!

until netcat -zv localhost $ARGOCD_PORT 2>/dev/null; do
    echo "Waiting ArgoCD port forwarding to be ready..."
    sleep 1
done
echo "ArgoCD port forwarding is ready."

ISFIRST=true

if [ "${1:-}" == "-f" ]; then
    ARGOCD_INITIAL_PASSWORD=$(kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    argocd login localhost:$ARGOCD_PORT --username admin --password $ARGOCD_INITIAL_PASSWORD
    argocd account update-password --current-password $ARGOCD_INITIAL_PASSWORD --new-password $ARGOCD_PASSWORD
else
    argocd login localhost:$ARGOCD_PORT --username admin --password $ARGOCD_PASSWORD
fi

argocd repo add ssh://git@github.com/pablo-lamtenzan/recruit-test-devops.git --ssh-private-key-path ./argocd-private-repo

bash << EOF & &>/dev/null
    while true ; do
        kubectl port-forward -n $APP_NAMESPACE svc/recruit $APP_PORT:8888 &>/dev/null
        sleep 5
    done
EOF
PF_APP_PID=$!

until nc -z -v -w5 localhost $APP_PORT &>/dev/null; do
    echo "Waiting Application port forwarding to be ready..."
    sleep 1
done
echo "Application port forwarding is ready."

echo "Setup complete!"
echo "Access the Argo CD UI at https://localhost:${ARGOCD_PORT}."
echo "Access the Application at http://localhost:${APP_PORT}."
echo "Press Ctrl + C to exit."

cleanup_and_exit() {
    echo "Received Ctrl + C. Cleaning up..."
    kill $PF_ARGO_PID $PF_APP_PID
    echo "Cleanup complete. Exiting."
    exit 1
}

trap 'cleanup_and_exit' SIGINT

wait
