#!/bin/bash
# scripts/monitor.sh - Real-time monitoring script for Blue-Green deployment

# Configuration
NAMESPACE="bluegreen-app"
REFRESH_INTERVAL=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Function to get current active environment
get_active_env() {
    kubectl get service bluegreen-app-main -n $NAMESPACE -o jsonpath='{.spec.selector.environment}' 2>/dev/null || echo "unknown"
}

# Function to get external URL
get_external_url() {
    kubectl get service bluegreen-app-main -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending"
}

# Function to get pod status with colors
get_pod_status() {
    local env=$1
    kubectl get pods -n $NAMESPACE -l environment=$env --no-headers 2>/dev/null | while read line; do
        if echo "$line" | grep -q "Running"; then
            echo -e "${GREEN}$line${NC}"
        elif echo "$line" | grep -q "Pending\|ContainerCreating"; then
            echo -e "${YELLOW}$line${NC}"
        elif echo "$line" | grep -q "Error\|CrashLoopBackOff\|Failed"; then
            echo -e "${RED}$line${NC}"
        else
            echo "$line"
        fi
    done
}

# Function to display the monitoring dashboard
display_dashboard() {
    clear
    
    # Header
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    🚀 Blue-Green Deployment Monitor                          ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Current time and refresh info
    echo -e "${BLUE}📅 Current time: ${YELLOW}$(date)${NC}"
    echo -e "${BLUE}🔄 Auto-refresh: ${YELLOW}${REFRESH_INTERVAL}s${NC} (Press Ctrl+C to exit)"
    echo ""
    
    # Active environment
    ACTIVE_ENV=$(get_active_env)
    if [ "$
