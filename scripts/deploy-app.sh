#!/bin/bash
# scripts/deploy-app.sh - Manual deployment script

set -e

# Configuration
CLUSTER_NAME="jenkins-bluegreen-cluster"
REGION="us-west-2"
APP_NAMESPACE="bluegreen-app"
ECR_REPOSITORY="bluegreen-app"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get current active environment
get_current_environment() {
    kubectl get service bluegreen-app-main -n $APP_NAMESPACE -o jsonpath='{.spec.selector.environment}' 2>/dev/null || echo "blue"
}

# Switch traffic between environments
switch_traffic() {
    local target_env=$1
    echo -e "${YELLOW}Switching traffic to $target_env environment...${NC}"
    
    kubectl patch service bluegreen-app-main -n $APP_NAMESPACE -p "{\"spec\":{\"selector\":{\"environment\":\"$target_env\"}}}"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Traffic successfully switched to $target_env${NC}"
        echo -e "${BLUE}Verifying the switch...${NC}"
        kubectl get service bluegreen-app-main -n $APP_NAMESPACE -o jsonpath='{.spec.selector.environment}'
        echo ""
    else
        echo -e "${RED}Failed to switch traffic${NC}"
        exit 1
    fi
}

# Deploy to specific environment
deploy_to_environment() {
    local env=$1
    local image_tag=$2
    
    echo -e "${YELLOW}Deploying to $env environment with tag $image_tag...${NC}"
    
    # Get ECR URI
    ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $REGION --query 'repositories[0].repositoryUri' --output text)
    
    # Replace placeholders and apply
    sed "s|\${ECR_URI}|$ECR_URI|g; s|\${BUILD_NUMBER}|$image_tag|g" k8s/app/${env}-deployment.yaml | kubectl apply -f -
    
    # Wait for rollout
    echo -e "${BLUE}Waiting for deployment to complete...${NC}"
    kubectl rollout status deployment/bluegreen-app-$env -n $APP_NAMESPACE --timeout=300s
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully deployed to $env environment${NC}"
        
        # Show deployment info
        echo -e "${BLUE}Deployment details:${NC}"
        kubectl get deployment bluegreen-app-$env -n $APP_NAMESPACE -o wide
    else
        echo -e "${RED}Deployment to $env environment failed${NC}"
        exit 1
    fi
}

# Test environment health
test_environment() {
    local env=$1
    echo -e "${YELLOW}Testing $env environment...${NC}"
    
    # Get service cluster IP
    SERVICE_IP=$(kubectl get svc bluegreen-app-$env -n $APP_NAMESPACE -o jsonpath='{.spec.clusterIP}')
    
    if [ -z "$SERVICE_IP" ]; then
        echo -e "${RED}Could not get service IP for $env environment${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Testing health endpoint at $SERVICE_IP...${NC}"
    
    # Run health check
    kubectl run test-pod-$env --rm -i --restart=Never --image=curlimages/curl -- \
        curl -f -s http://$SERVICE_IP/health
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}$env environment is healthy${NC}"
        
        # Run additional tests
        echo -e "${BLUE}Testing API endpoint...${NC}"
        kubectl run test-pod-api-$env --rm -i --restart=Never --image=curlimages/curl -- \
            curl -f -s http://$SERVICE_IP/api/info
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}All tests passed for $env environment${NC}"
        else
            echo -e "${YELLOW}Health check passed but API test failed${NC}"
            return 1
        fi
    else
        echo -e "${RED}$env environment health check failed${NC}"
        return 1
    fi
}

# Show deployment status
show_status() {
    echo -e "${YELLOW}=== Blue-Green Deployment Status ===${NC}"
    current_env=$(get_current_environment)
    echo -e "${BLUE}Active environment: ${GREEN}$current_env${NC}"
    echo ""
    
    echo -e "${BLUE}🔵 Blue Environment:${NC}"
    if kubectl get deployment bluegreen-app-blue -n $APP_NAMESPACE >/dev/null 2>&1; then
        kubectl get deployment bluegreen-app-blue -n $APP_NAMESPACE -o wide
        echo "Pods:"
        kubectl get pods -n $APP_NAMESPACE -l environment=blue -o wide
    else
        echo "Not deployed"
    fi
    echo ""
    
    echo -e "${BLUE}🟢 Green Environment:${NC}"
    if kubectl get deployment bluegreen-app-green -n $APP_NAMESPACE >/dev/null 2>&1; then
        kubectl get deployment bluegreen-app-green -n $APP_NAMESPACE -o wide
        echo "Pods:"
        kubectl get pods -n $APP_NAMESPACE -l environment=green -o wide
    else
        echo "Not deployed"
    fi
    echo ""
    
    echo -e "${BLUE}🎯 Main Service:${NC}"
    kubectl get service bluegreen-app-main -n $APP_NAMESPACE -o wide
    echo ""
    
    echo -e "${BLUE}🌐 External Access:${NC}"
    EXTERNAL_IP=$(kubectl get service bluegreen-app-main -n $APP_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [ -n "$EXTERNAL_IP" ]; then
        echo "Application URL: http://$EXTERNAL_IP"
    else
        echo "External IP not yet assigned"
    fi
    echo ""
    
    echo -e "${BLUE}📈 HPA Status:${NC}"
    kubectl get hpa -n $APP_NAMESPACE 2>/dev/null || echo "HPA not configured"
}

# Rollback to previous environment
rollback() {
    current_env=$(get_current_environment)
    rollback_env=$([ "$current_env" == "blue" ] && echo "green" || echo "blue")
    
    echo -e "${YELLOW}Rolling back from $current_env to $rollback_env${NC}"
    
    # Check if rollback environment exists
    if ! kubectl get deployment bluegreen-app-$rollback_env -n $APP_NAMESPACE >/dev/null 2>&1; then
        echo -e "${RED}Cannot rollback: $rollback_env environment is not deployed${NC}"
        exit 1
    fi
    
    # Test rollback environment first
    if test_environment $rollback_env; then
        switch_traffic $rollback_env
        echo -e "${GREEN}Rollback completed successfully${NC}"
    else
        echo -e "${RED}Rollback aborted: $rollback_env environment is not healthy${NC}"
        exit 1
    fi
}

# Scale environment
scale_environment() {
    local env=$1
    local replicas=$2
    
    echo -e "${YELLOW}Scaling $env environment to $replicas replicas...${NC}"
    
    kubectl scale deployment bluegreen-app-$env -n $APP_NAMESPACE --replicas=$replicas
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Successfully scaled $env environment to $replicas replicas${NC}"
        kubectl get deployment bluegreen-app-$env -n $APP_NAMESPACE
    else
        echo -e "${RED}Failed to scale $env environment${NC}"
        exit 1
    fi
}

# Main function
main() {
    case "$1" in
        "deploy")
            if [ -z "$2" ] || [ -z "$3" ]; then
                echo "Usage: $0 deploy <environment> <image_tag>"
                echo "Example: $0 deploy blue v1.2.3"
                exit 1
            fi
            deploy_to_environment $2 $3
            ;;
        "switch")
            if [ -z "$2" ]; then
                echo "Usage: $0 switch <environment>"
                echo "Example: $0 switch green"
                exit 1
            fi
            switch_traffic $2
            ;;
        "test")
            if [ -z "$2" ]; then
                echo "Usage: $0 test <environment>"
                echo "Example: $0 test blue"
                exit 1
            fi
            test_environment $2
            ;;
        "status")
            show_status
            ;;
        "rollback")
            rollback
            ;;
        "scale")
            if [ -z "$2" ] || [ -z "$3" ]; then
                echo "Usage: $0 scale <environment> <replicas>"
                echo "Example: $0 scale blue 5"
                exit 1
            fi
            scale_environment $2 $3
            ;;
        *)
            echo "Usage: $0 {deploy|switch|test|status|rollback|scale}"
            echo ""
            echo "Commands:"
            echo "  deploy <env> <tag>     - Deploy to specific environment"
            echo "  switch <env>           - Switch traffic to environment"
            echo "  test <env>             - Test environment health"
            echo "  status                 - Show current deployment status"
            echo "  rollback               - Rollback to previous environment"
            echo "  scale <env> <replicas> - Scale environment replicas"
            echo ""
            echo "Examples:"
            echo "  $0 deploy blue v1.2.3"
            echo "  $0 test blue"
            echo "  $0 switch green"
            echo "  $0 status"
            echo "  $0 rollback"
            echo "  $0 scale blue 5"
            exit 1
            ;;
    esac
}

main "$@"
