## Prerequisites

- Have `git` and `ssh-keygen` tools installed.
- Have access to the `GitHub` repository and the necessary permissions to **add secrets** and **deploy keys**.
- Have a `Docker Hub` account.

## Setup

### 1. Docker Hub Secrets

To enable our **CI pipeline** to push images to Docker Hub, it is necesary to set up these two secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and `DOCKERHUB_REPO`.

#### 1.1 Generate Docker Hub Token

1.1.1 Log in to Docker Hub.\
1.1.2 Go to Account Settings.\
1.1.3 Navigate to Security.\
1.1.4 Click on *"New Access Token"*.\
1.1.5 Provide a description for the token and create it.\
1.1.6 Copy the token (will be shown only once).

#### 1.2 Add Secrets to GitHub

1.2.1 Navigate to the GitHub repository.\
1.2.2 Go to Settings -> Security -> Secrets and variables -> Actions.\
1.2.3 Click on *"New repository secret"*.\
1.2.4 Name the secret `DOCKERHUB_USERNAME` and set its value to your Docker Hub username.\
1.2.5 Create another secret named `DOCKERHUB_TOKEN` and set its value to the token you generated in the previous step.
1.2.6 Create another secret named `DOCKERHUB_REPO` and set to the Docker Hub repository name.

This repository is designed to work with a Github Actions CI like this one:
```yml
name: Build and Push Docker Image

on:
  push:
    branches:
      - main

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v2.10.0

    - name: Cache Docker layers
      uses: actions/cache@v3.3.2
      with:
        path: /tmp/.buildx-cache
        key: ${{ runner.os }}-buildx-${{ github.sha }}
        restore-keys: |
          ${{ runner.os }}-buildx-

    - name: Login to DockerHub
      uses: docker/login-action@v3.0.0
      with:
        username: ${{ secrets.DOCKERHUB_USERNAME }}
        password: ${{ secrets.DOCKERHUB_TOKEN }}

    - name: Build and push Docker image
      run: |
        docker build -t ${{ secrets.DOCKERHUB_USERNAME }}/${{ secrets.DOCKERHUB_REPO }}:${GITHUB_SHA} \
          --build-arg BUILDKIT_INLINE_CACHE=1 --cache-from=type=local,src=/tmp/.buildx-cache .
        docker tag ${{ secrets.DOCKERHUB_USERNAME }}/${{ secrets.DOCKERHUB_REPO }}:${GITHUB_SHA} \
          ${{ secrets.DOCKERHUB_USERNAME }}/${{ secrets.DOCKERHUB_REPO }}:latest
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/${{ secrets.DOCKERHUB_REPO }}:${GITHUB_SHA}
        docker push ${{ secrets.DOCKERHUB_USERNAME }}/${{ secrets.DOCKERHUB_REPO }}:latest
```

### 2. SSH Key for Private Repository Access

To allow **ArgoCD** to access and sync with the private GitHub repository, it is necesary set up an SSH key.

#### 2.1 Generate SSH Key

```bash
ssh-keygen -t rsa -b 4096 -f ./argo-access-key -C "argocd-access"
```

This will generate two files in your current directory: *argo-access-key* (private key) and *argo-access-key.pub* (public key).

#### 2.2 Add Public Key to GitHub as Deploy Key

2.2.1 Navigate to your GitHub repository.\
2.2.2 Go to Settings -> Security -> Deploy keys.\
2.2.3 Click on *"Add deploy key"*.\
2.2.4 Name it, paste the contents of `argo-access-key.pub` into the key field, and click on *"Add key"*.

### 3. Configuration Files

#### 3.1 .env File

Create a .env file in the root directory with the following format:

```bash
DOCKER_USERNAME=<your_docker_username>
DOCKER_PASSWORD=<your_docker_password>
ARGOCD_PASSWORD=<your_argocd_password>
SERVICE_NAME=<your service name (the name of the service of target the repository manifest)>
GITHUB_REPO_URL=<your repository url>
K8S_CLUSTER_NAME=<your_cluster_name>  # Optional
K8S_APP_NAMESPACE=<your_app_namespace>  # Optional
K8S_APP_PORT=<your_app_port>  # Optional
K8S_ARGOCD_NAMESPACE=<your_argocd_namespace>  # Optional
K8S_ARGOCD_PORT=<your_argocd_port>  # Optional
```

### 4. values.yaml Configuration

To set up the necessary configurations for your deployment, you must create a `values.yaml` file inside the *k8s-manifests/app-chart/* directory. Use the following command:

```bash
cat << EOF > k8s-manifests/app-chart/values.yaml
applicationName: your-application-name
namespace: argocd-namespace
destinationNamespace: your-destination-namespace
repoURL: ssh://git@your-github-account/your-repo.git
targetRevision: your-branch-or-commit
manifestPath: path/to/your-repo-manifest.yml
EOF
```

### 5. Running the Setup Script

#### Initial Setup

If you're running the setup script for the first time or wish to reset your password, execute the following command:

```bash
./setup.sh -f
```

#### Subsequent Runs

For subsequent runs, you can simply use:
```bash
./setup.sh
```
