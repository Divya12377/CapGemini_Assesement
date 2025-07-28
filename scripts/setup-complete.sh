#!/bin/bash

# Updated Complete AWS EKS Jenkins Blue-Green Deployment Setup Script
# Author: Updated Setup Guide
# Description: Automated setup for EKS cluster with Jenkins and Blue-Green deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="jenkins-bluegreen-cluster"
REGION="us-west-2"
NODE_GROUP_NAME="worker-nodes"
NAMESPACE="jenkins"
APP_NAMESPACE="bluegreen-app"
ECR_REPOSITORY="bluegreen-app"

echo -e "${GREEN}🚀 Starting AWS EKS Jenkins Blue-Green Deployment Setup...${NC}"

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

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo -e "${GREEN}AWS credentials configured for account: $AWS_ACCOUNT_ID${NC}"

# Check if EKS cluster exists
echo -e "${YELLOW}Checking EKS cluster status...${NC}"
if ! eksctl get cluster --name $CLUSTER_NAME --region $REGION > /dev/null 2>&1; then
    echo -e "${YELLOW}Creating EKS cluster (this will take 15-20 minutes)...${NC}"
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
        --full-ecr-access \
        --enable-ssm
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
echo -e "${GREEN}Successfully connected to cluster${NC}"

# Create namespaces
echo -e "${YELLOW}Creating namespaces...${NC}"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}Namespaces created${NC}"

# Install AWS Load Balancer Controller (only if not exists)
echo -e "${YELLOW}Setting up AWS Load Balancer Controller...${NC}"

# Create IAM policy if it doesn't exist
if ! aws iam get-policy --policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy > /dev/null 2>&1; then
    echo "Creating IAM policy for Load Balancer Controller..."
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json
fi

# Create IAM service account if it doesn't exist
if ! kubectl get serviceaccount aws-load-balancer-controller -n kube-system > /dev/null 2>&1; then
    eksctl create iamserviceaccount \
      --cluster=$CLUSTER_NAME \
      --namespace=kube-system \
      --name=aws-load-balancer-controller \
      --role-name "AmazonEKSLoadBalancerControllerRole" \
      --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
      --approve
fi

# Install Load Balancer Controller using Helm
if ! kubectl get deployment aws-load-balancer-controller -n kube-system > /dev/null 2>&1; then
    echo "Installing AWS Load Balancer Controller..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
      -n kube-system \
      --set clusterName=$CLUSTER_NAME \
      --set serviceAccount.create=false \
      --set serviceAccount.name=aws-load-balancer-controller
fi

echo -e "${GREEN}AWS Load Balancer Controller configured${NC}"

# Create ECR repository
echo -e "${YELLOW}Creating ECR repository...${NC}"
if ! aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $REGION > /dev/null 2>&1; then
    aws ecr create-repository --repository-name $ECR_REPOSITORY --region $REGION
    echo -e "${GREEN}ECR repository created${NC}"
else
    echo -e "${GREEN}ECR repository already exists${NC}"
fi

ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $REGION --query 'repositories[0].repositoryUri' --output text)
echo -e "${GREEN}ECR Repository URI: $ECR_URI${NC}"

# Build and push sample application
echo -e "${YELLOW}Building and pushing sample application...${NC}"
if [ -d "app" ]; then
    cd app
    
    # Build Docker image
    docker build -t $ECR_REPOSITORY:latest .
    docker build -t $ECR_REPOSITORY:blue .
    docker build -t $ECR_REPOSITORY:green .
    
    # Login to ECR
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
    
    # Tag and push images
    docker tag $ECR_REPOSITORY:latest $ECR_URI:latest
    docker tag $ECR_REPOSITORY:blue $ECR_URI:blue
    docker tag $ECR_REPOSITORY:green $ECR_URI:green
    
    docker push $ECR_URI:latest
    docker push $ECR_URI:blue
    docker push $ECR_URI:green
    
    cd ..
    echo -e "${GREEN}Sample application images pushed to ECR${NC}"
else
    echo -e "${YELLOW}App directory not found, skipping Docker build${NC}"
fi

# Deploy Jenkins using the fixed script
echo -e "${YELLOW}Deploying Jenkins with fixed configuration...${NC}"
./fix-jenkins-complete.sh

# Wait a bit for Jenkins to be fully ready
sleep 30

# Get Jenkins information
JENKINS_POD=$(kubectl get pods -n $NAMESPACE -l app=jenkins -o jsonpath='{.items[0].metadata.name}')
JENKINS_PASSWORD=""
if [ -n "$JENKINS_POD" ]; then
    for i in {1..5}; do
        JENKINS_PASSWORD=$(kubectl exec -n $NAMESPACE $JENKINS_POD -- cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "")
        if [ -n "$JENKINS_PASSWORD" ]; then
            break
        fi
        echo "Waiting for Jenkins password... (attempt $i/5)"
        sleep 30
    done
fi

# Get Jenkins URL
JENKINS_URL=$(kubectl get svc jenkins -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

# Deploy sample blue-green application
echo -e "${YELLOW}Deploying sample blue-green application...${NC}"
if [ -d "k8s/app" ]; then
    # Update image URIs in deployment files
    find k8s/app -name "*.yaml" -exec sed -i "s|\${ECR_URI}|$ECR_URI|g" {} \;
    find k8s/app -name "*.yaml" -exec sed -i "s|\${BUILD_NUMBER}|latest|g" {} \;
    
    kubectl apply -f k8s/app/ -n $APP_NAMESPACE
    echo -e "${GREEN}Sample application deployed${NC}"
    
    # Wait for application deployments
    echo "Waiting for application deployments..."
    kubectl wait --for=condition=available deployment --all -n $APP_NAMESPACE --timeout=300s || true
else
    echo -e "${YELLOW}k8s/app directory not found, skipping application deployment${NC}"
fi

# Create Jenkins pipeline job configuration
echo -e "${YELLOW}Creating Jenkins configuration...${NC}"
cat > jenkins-job-config.xml << 'EOF'
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job@2.40">
  <actions/>
  <description>Blue-Green Deployment Pipeline</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers>
        <com.cloudbees.jenkins.GitHubPushTrigger plugin="github@1.34.1">
          <spec></spec>
        </com.cloudbees.jenkins.GitHubPushTrigger>
      </triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps@2.92">
    <scm class="hudson.plugins.git.GitSCM" plugin="git@4.8.2">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>https://github.com/Divya12377/CapGemini_Assesement.git</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class="list"/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF

echo -e "${GREEN}🎉 Setup completed successfully!${NC}"
echo ""
echo -e "${BLUE}==================== SETUP SUMMARY ====================${NC}"
echo -e "${GREEN}✅ EKS Cluster: $CLUSTER_NAME${NC}"
echo -e "${GREEN}✅ Jenkins Namespace: $NAMESPACE${NC}"
echo -e "${GREEN}✅ App Namespace: $APP_NAMESPACE${NC}"
echo -e "${GREEN}✅ ECR Repository: $ECR_URI${NC}"

if [ "$JENKINS_URL" != "pending" ] && [ -n "$JENKINS_URL" ]; then
    echo -e "${GREEN}✅ Jenkins URL: http://$JENKINS_URL:8080${NC}"
else
    echo -e "${YELLOW}⏳ Jenkins URL: External IP being provisioned${NC}"
    echo -e "${BLUE}   Check with: kubectl get service jenkins -n jenkins${NC}"
    echo -e "${BLUE}   Or use port-forward: kubectl port-forward -n jenkins svc/jenkins 8080:8080${NC}"
fi

if [ -n "$JENKINS_PASSWORD" ]; then
    echo -e "${GREEN}🔑 Jenkins Admin Password: $JENKINS_PASSWORD${NC}"
else
    echo -e "${YELLOW}🔑 Jenkins Password: Get with command below${NC}"
    echo -e "${BLUE}   kubectl exec -n jenkins $JENKINS_POD -- cat /var/jenkins_home/secrets/initialAdminPassword${NC}"
fi

echo ""
echo -e "${BLUE}==================== NEXT STEPS ====================${NC}"
echo -e "${YELLOW}1. Access Jenkins:${NC}"
if [ "$JENKINS_URL" != "pending" ] && [ -n "$JENKINS_URL" ]; then
    echo "   - Open: http://$JENKINS_URL:8080"
else
    echo "   - Run: kubectl port-forward -n jenkins svc/jenkins 8080:8080"
    echo "   - Open: http://localhost:8080"
fi

echo ""
echo -e "${YELLOW}2. Initial Jenkins Setup:${NC}"
echo "   - Login with admin and the password above"
echo "   - Install suggested plugins"
echo "   - Create a new admin user"
echo "   - Complete the setup wizard"

echo ""
echo -e "${YELLOW}3. Create Jenkins Pipeline:${NC}"
echo "   - Go to 'New Item' → 'Pipeline'"
echo "   - Name: 'blue-green-deployment'"
echo "   - Configure Git repository: https://github.com/Divya12377/CapGemini_Assesement.git"
echo "   - Set Script Path: Jenkinsfile"

echo ""
echo -e "${YELLOW}4. Test Blue-Green Deployment:${NC}"
echo "   - Run: ./scripts/deploy-app.sh status"
echo "   - Deploy to blue: ./scripts/deploy-app.sh deploy blue v1.0"
echo "   - Test: ./scripts/deploy-app.sh test blue"
echo "   - Switch traffic: ./scripts/deploy-app.sh switch blue"

echo ""
echo -e "${YELLOW}5. Monitor Application:${NC}"
echo "   - Run: ./scripts/monitor.sh"
echo "   - Check app status: kubectl get all -n $APP_NAMESPACE"

echo ""
echo -e "${GREEN}🚀 Your blue-green deployment environment is ready!${NC}"
echo -e "${BLUE}For troubleshooting, check logs with:${NC}"
echo -e "${BLUE}  kubectl logs -n jenkins deployment/jenkins${NC}"
echo -e "${BLUE}  kubectl get events -n jenkins --sort-by='.lastTimestamp'${NC}"
