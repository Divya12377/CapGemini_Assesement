#!/bin/bash

# Complete AWS EKS Jenkins Blue-Green Deployment Setup Script
# Author: Setup Guide
# Description: Automated setup for EKS cluster with Jenkins and Blue-Green deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="jenkins-bluegreen-cluster"
REGION="us-west-2"
NODE_GROUP_NAME="worker-nodes"
NAMESPACE="jenkins"
APP_NAMESPACE="bluegreen-app"

echo -e "${GREEN}Starting AWS EKS Jenkins Blue-Green Deployment Setup...${NC}"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"
for cmd in aws kubectl eksctl docker git; do
    if ! command_exists $cmd; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done
echo -e "${GREEN}All prerequisites are installed${NC}"

# Check AWS credentials
echo -e "${YELLOW}Checking AWS credentials...${NC}"
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi
echo -e "${GREEN}AWS credentials configured${NC}"

# Create EKS cluster
echo -e "${YELLOW}Creating EKS cluster...${NC}"
if ! eksctl get cluster --name $CLUSTER_NAME --region $REGION > /dev/null 2>&1; then
    eksctl create cluster \
        --name $CLUSTER_NAME \
        --region $REGION \
        --nodegroup-name $NODE_GROUP_NAME \
        --node-type t3.medium \
        --nodes 3 \
        --nodes-min 2 \
        --nodes-max 4 \
        --managed \
        --with-oidc \
        --ssh-access \
        --ssh-public-key k8 \
        --full-ecr-access
    echo -e "${GREEN}EKS cluster created successfully${NC}"
else
    echo -e "${GREEN}EKS cluster already exists${NC}"
fi

# Update kubeconfig
echo -e "${YELLOW}Updating kubeconfig...${NC}"
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Verify cluster connection
echo -e "${YELLOW}Verifying cluster connection...${NC}"
kubectl get nodes

# Create namespaces
echo -e "${YELLOW}Creating namespaces...${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install AWS Load Balancer Controller
echo -e "${YELLOW}Installing AWS Load Balancer Controller...${NC}"
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.4/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json || true

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name "AmazonEKSLoadBalancerControllerRole" \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --approve || true

# Deploy Jenkins
echo -e "${YELLOW}Deploying Jenkins...${NC}"
kubectl apply -f k8s/jenkins/ -n $NAMESPACE

# Wait for Jenkins to be ready
echo -e "${YELLOW}Waiting for Jenkins to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=jenkins -n $NAMESPACE --timeout=600s

# Get Jenkins admin password
echo -e "${YELLOW}Getting Jenkins admin password...${NC}"
JENKINS_PASSWORD=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=jenkins -o jsonpath='{.items[0].metadata.name}') -- cat /var/jenkins_home/secrets/initialAdminPassword)
echo -e "${GREEN}Jenkins admin password: $JENKINS_PASSWORD${NC}"

# Get Jenkins URL
JENKINS_URL=$(kubectl get svc jenkins -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo -e "${GREEN}Jenkins URL: http://$JENKINS_URL:8080${NC}"

# Deploy sample application
echo -e "${YELLOW}Deploying sample application...${NC}"
kubectl apply -f k8s/app/ -n $APP_NAMESPACE

# Create ECR repository
echo -e "${YELLOW}Creating ECR repository...${NC}"
aws ecr create-repository --repository-name bluegreen-app --region $REGION || true

# Get ECR login
ECR_URI=$(aws ecr describe-repositories --repository-names bluegreen-app --region $REGION --query 'repositories[0].repositoryUri' --output text)
echo -e "${GREEN}ECR Repository URI: $ECR_URI${NC}"

# Build and push initial image
echo -e "${YELLOW}Building and pushing initial Docker image...${NC}"
cd app
docker build -t bluegreen-app .
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
docker tag bluegreen-app:latest $ECR_URI:latest
docker push $ECR_URI:latest
cd ..

echo -e "${GREEN}Setup completed successfully!${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Access Jenkins at: http://$JENKINS_URL:8080"
echo "2. Login with admin/$JENKINS_PASSWORD"
echo "3. Install suggested plugins"
echo "4. Create a new pipeline job using the provided Jenkinsfile"
echo "5. Configure GitHub webhook for automatic deployments"

echo -e "${GREEN}Setup Summary:${NC}"
echo "- EKS Cluster: $CLUSTER_NAME"
echo "- Jenkins Namespace: $NAMESPACE" 
echo "- App Namespace: $APP_NAMESPACE"
echo "- ECR Repository: $ECR_URI"
echo "- Jenkins URL: http://$JENKINS_URL:8080"
echo "- Jenkins Password: $JENKINS_PASSWORD"
