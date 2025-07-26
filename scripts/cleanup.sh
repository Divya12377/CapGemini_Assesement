#!/bin/bash
# scripts/cleanup.sh - Cleanup script for AWS EKS Jenkins Blue-Green deployment

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
ECR_REPOSITORY="bluegreen-app"
NAMESPACE="jenkins"
APP_NAMESPACE="bluegreen-app"

echo -e "${YELLOW}🧹 Starting cleanup of AWS EKS Jenkins Blue-Green deployment resources...${NC}"

# Function to ask for confirmation
confirm() {
    local message=$1
    echo -e "${YELLOW}$message${NC}"
    read -p "Are you sure? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo -e "${BLUE}Skipping...${NC}"
        return 1
    fi
    return 0
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"
for cmd in aws kubectl eksctl; do
    if ! command_exists $cmd; then
        echo -e "${RED}Error: $cmd is not installed${NC}"
        exit 1
    fi
done

# Check AWS credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    exit 1
fi

echo -e "${GREEN}Prerequisites check passed${NC}"
echo ""

# Show what will be deleted
echo -e "${YELLOW}The following resources will be deleted:${NC}"
echo "- EKS Cluster: $CLUSTER_NAME"
echo "- ECR Repository: $ECR_REPOSITORY"
echo "- IAM Policies: AWSLoadBalancerControllerIAMPolicy"
echo "- All associated resources (Load Balancers, Security Groups, etc.)"
echo ""

if ! confirm "⚠️  This will delete ALL resources related to this blue-green deployment setup."; then
    echo -e "${BLUE}Cleanup cancelled by user${NC}"
    exit 0
fi

# Delete Kubernetes resources first
echo -e "${YELLOW}Step 1: Cleaning up Kubernetes resources...${NC}"

if kubectl cluster-info >/dev/null 2>&1; then
    echo -e "${BLUE}Deleting application resources...${NC}"
    kubectl delete namespace $APP_NAMESPACE --ignore-not-found=true
    
    echo -e "${BLUE}Deleting Jenkins resources...${NC}"
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    
    echo -e "${BLUE}Deleting load balancer controller resources...${NC}"
    kubectl delete -f https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.4/v2_4_4_full.yaml --ignore-not-found=true || true
    
    echo -e "${GREEN}Kubernetes resources cleaned up${NC}"
else
    echo -e "${YELLOW}No active Kubernetes cluster found or cluster not accessible${NC}"
fi

echo ""

# Delete ECR repository
echo -e "${YELLOW}Step 2: Deleting ECR repository...${NC}"
if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $REGION >/dev/null 2>&1; then
    echo -e "${BLUE}Deleting ECR repository: $ECR_REPOSITORY${NC}"
    
    # Delete all images first
    IMAGE_TAGS=$(aws ecr list-images --repository-name $ECR_REPOSITORY --region $REGION --query 'imageIds[*].imageTag' --output text 2>/dev/null || echo "")
    if [ -n "$IMAGE_TAGS" ] && [ "$IMAGE_TAGS" != "None" ]; then
        echo -e "${BLUE}Deleting container images...${NC}"
        aws ecr batch-delete-image --repository-name $ECR_REPOSITORY --region $REGION --image-ids imageTag=$IMAGE_TAGS || true
    fi
    
    # Delete repository
    aws ecr delete-repository --repository-name $ECR_REPOSITORY --region $REGION --force
    echo -e "${GREEN}ECR repository deleted${NC}"
else
    echo -e "${YELLOW}ECR repository $ECR_REPOSITORY not found${NC}"
fi

echo ""

# Delete EKS cluster
echo -e "${YELLOW}Step 3: Deleting EKS cluster...${NC}"
if eksctl get cluster --name $CLUSTER_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${BLUE}Deleting EKS cluster: $CLUSTER_NAME${NC}"
    echo -e "${YELLOW}This may take 10-15 minutes...${NC}"
    
    # Delete cluster
    eksctl delete cluster --name $CLUSTER_NAME --region $REGION --wait
    
    echo -e "${GREEN}EKS cluster deleted${NC}"
else
    echo -e "${YELLOW}EKS cluster $CLUSTER_NAME not found${NC}"
fi

echo ""

# Delete IAM policies and roles
echo -e "${YELLOW}Step 4: Cleaning up IAM resources...${NC}"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Delete Load Balancer Controller IAM policy
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
if aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1; then
    echo -e "${BLUE}Deleting IAM policy: AWSLoadBalancerControllerIAMPolicy${NC}"
    
    # Detach policy from all roles first
    ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn $POLICY_ARN --query 'PolicyRoles[*].RoleName' --output text 2>/dev/null || echo "")
    if [ -n "$ATTACHED_ROLES" ] && [ "$ATTACHED_ROLES" != "None" ]; then
        for role in $ATTACHED_ROLES; do
            echo -e "${BLUE}Detaching policy from role: $role${NC}"
            aws iam detach-role-policy --role-name $role --policy-arn $POLICY_ARN || true
        done
    fi
    
    # Delete policy
    aws iam delete-policy --policy-arn $POLICY_ARN
    echo -e "${GREEN}IAM policy deleted${NC}"
else
    echo -e "${YELLOW}IAM policy AWSLoadBalancerControllerIAMPolicy not found${NC}"
fi

# Clean up service account roles
echo -e "${BLUE}Cleaning up service account roles...${NC}"
aws iam list-roles --query 'Roles[?contains(RoleName, `eksctl-'$CLUSTER_NAME'`) || contains(RoleName, `AmazonEKSLoadBalancerControllerRole`)].RoleName' --output text | while read role; do
    if [ -n "$role" ] && [ "$role" != "None" ]; then
        echo -e "${BLUE}Deleting role: $role${NC}"
        
        # Detach all policies
        aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[*].PolicyArn' --output text | while read policy_arn; do
            if [ -n "$policy_arn" ] && [ "$policy_arn" != "None" ]; then
                aws iam detach-role-policy --role-name $role --policy-arn $policy_arn || true
            fi
        done
        
        # Delete role
        aws iam delete-role --role-name $role || true
    fi
done

echo ""

# Clean up local files
echo -e "${YELLOW}Step 5: Cleaning up local files...${NC}"
if [ -f "iam_policy.json" ]; then
    echo -e "${BLUE}Removing iam_policy.json${NC}"
    rm -f iam_policy.json
fi

# Remove kubeconfig context
if kubectl config get-contexts -o name | grep -q "$CLUSTER_NAME"; then
    echo -e "${BLUE}Removing kubeconfig context${NC}"
    kubectl config delete-context arn:aws:eks:$REGION:$AWS_ACCOUNT_ID:cluster/$CLUSTER_NAME || true
fi

echo ""

# Clean up Docker images (optional)
if confirm "🐳 Do you want to clean up local Docker images and containers?"; then
    echo -e "${BLUE}Cleaning up Docker resources...${NC}"
    
    # Remove containers
    docker ps -aq --filter "ancestor=bluegreen-app" | xargs -r docker rm -f || true
    docker ps -aq --filter "ancestor=$ECR_REPOSITORY" | xargs -r docker rm -f || true
    
    # Remove images
    docker images --filter "reference=bluegreen-app*" -q | xargs -r docker rmi -f || true
    docker images --filter "reference=*$ECR_REPOSITORY*" -q | xargs -r docker rmi -f || true
    
    # Clean up system
    docker system prune -f || true
    
    echo -e "${GREEN}Docker cleanup completed${NC}"
fi

echo ""

# Summary
echo -e "${GREEN}✅ Cleanup completed successfully!${NC}"
echo ""
echo -e "${BLUE}Summary of cleaned up resources:${NC}"
echo "✓ EKS Cluster: $CLUSTER_NAME"
echo "✓ ECR Repository: $ECR_REPOSITORY"
echo "✓ IAM Policies and Roles"
echo "✓ Kubernetes namespaces and resources"
echo "✓ Load Balancers and associated AWS resources"
echo "✓ Local configuration files"

if [ -f "~/.aws/config" ]; then
    echo ""
    echo -e "${YELLOW}Note: AWS credentials and configuration are preserved${NC}"
    echo -e "${BLUE}If you want to remove AWS CLI configuration, run: aws configure list${NC}"
fi

echo ""
echo -e "${GREEN}All resources have been successfully cleaned up!${NC}"
echo -e "${BLUE}You can now safely re-run the setup script to create a fresh deployment.${NC}"
