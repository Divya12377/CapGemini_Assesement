#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 Complete Jenkins Fix - Clean Deployment${NC}"
echo "============================================="

# Step 1: Clean up ALL existing resources
echo -e "${YELLOW}Step 1: Cleaning up all existing Jenkins resources...${NC}"

# Delete any existing deployments
kubectl delete deployment jenkins jenkins-new -n jenkins --ignore-not-found=true

# Delete all pods (force)
kubectl delete pods --all -n jenkins --force --grace-period=0 --ignore-not-found=true

# Delete all PVCs (including the pending one)
kubectl delete pvc --all -n jenkins --ignore-not-found=true

# Wait for cleanup
echo "Waiting for cleanup to complete..."
sleep 15

# Check if there are any PVs that need cleanup
JENKINS_PVS=$(kubectl get pv -o jsonpath='{.items[?(@.spec.claimRef.namespace=="jenkins")].metadata.name}' 2>/dev/null || echo "")
if [ -n "$JENKINS_PVS" ]; then
    echo "Cleaning up orphaned PVs..."
    for pv in $JENKINS_PVS; do
        echo "Deleting PV: $pv"
        kubectl patch pv $pv -p '{"metadata":{"finalizers":null}}' --ignore-not-found=true
        kubectl delete pv $pv --ignore-not-found=true
    done
fi

# Step 2: Verify available storage classes
echo -e "${YELLOW}Step 2: Checking available storage classes...${NC}"
kubectl get storageclass

# Get the default storage class or gp2
STORAGE_CLASS=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' || echo "gp2")
if [ -z "$STORAGE_CLASS" ]; then
    STORAGE_CLASS="gp2"
fi
echo "Using storage class: $STORAGE_CLASS"

# Step 3: Ensure namespace and RBAC
echo -e "${YELLOW}Step 3: Setting up namespace and RBAC...${NC}"
kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

# Create ServiceAccount and RBAC
cat << EOFRBAC | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins
subjects:
- kind: ServiceAccount
  name: jenkins
  namespace: jenkins
EOFRBAC

# Step 4: Deploy Jenkins with emptyDir (no PVC issues)
echo -e "${YELLOW}Step 4: Deploying Jenkins with working configuration...${NC}"
cat << EOFJENKINS | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    app: jenkins
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jenkins
  template:
    metadata:
      labels:
        app: jenkins
    spec:
      serviceAccountName: jenkins
      securityContext:
        runAsUser: 1000
        fsGroup: 1000
      containers:
      - name: jenkins
        image: jenkins/jenkins:lts
        ports:
        - containerPort: 8080
          name: web
        - containerPort: 50000
          name: agent
        env:
        - name: JAVA_OPTS
          value: "-Djenkins.install.runSetupWizard=false -Xmx1024m -Djava.awt.headless=true"
        - name: JENKINS_OPTS
          value: "--httpPort=8080"
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        volumeMounts:
        - name: jenkins-home
          mountPath: /var/jenkins_home
        livenessProbe:
          httpGet:
            path: /login
            port: 8080
          initialDelaySeconds: 180
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /login
            port: 8080
          initialDelaySeconds: 120
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /login
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
      volumes:
      - name: jenkins-home
        emptyDir: {}
      nodeSelector:
        kubernetes.io/os: linux
EOFJENKINS

# Step 5: Create Jenkins Service
echo -e "${YELLOW}Step 5: Creating Jenkins service...${NC}"
cat << EOFSVC | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: jenkins
  namespace: jenkins
  labels:
    app: jenkins
spec:
  selector:
    app: jenkins
  ports:
    - name: web
      port: 8080
      targetPort: 8080
      protocol: TCP
    - name: agent
      port: 50000
      targetPort: 50000
      protocol: TCP
  type: LoadBalancer
EOFSVC

# Step 6: Wait for Jenkins to be ready
echo -e "${YELLOW}Step 6: Waiting for Jenkins to be ready (this may take 5-10 minutes)...${NC}"

# Wait for deployment to be available
echo "Waiting for deployment to be available..."
kubectl wait --for=condition=available deployment/jenkins -n jenkins --timeout=600s

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Jenkins deployment didn't become available in time${NC}"
    echo "Let's check what's happening..."
    kubectl get pods -n jenkins
    kubectl describe pods -n jenkins
    kubectl logs -n jenkins deployment/jenkins --tail=50
    exit 1
fi

# Wait for pod to be ready
echo "Waiting for Jenkins pod to be ready..."
kubectl wait --for=condition=ready pod -l app=jenkins -n jenkins --timeout=600s

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Jenkins pod didn't become ready in time${NC}"
    echo "Let's check the pod status and logs..."
    kubectl get pods -n jenkins
    kubectl describe pods -n jenkins -l app=jenkins
    kubectl logs -n jenkins -l app=jenkins --tail=100
    exit 1
fi

echo -e "${GREEN}✅ Jenkins is ready!${NC}"

# Step 7: Get access information
echo -e "${YELLOW}Step 7: Getting access information...${NC}"

# Show current status
echo "Current Jenkins status:"
kubectl get pods -n jenkins -l app=jenkins
kubectl get service jenkins -n jenkins

# Get Jenkins admin password
echo ""
echo "Getting Jenkins admin password..."
JENKINS_POD=$(kubectl get pods -n jenkins -l app=jenkins -o jsonpath='{.items[0].metadata.name}')

# Wait a bit more for Jenkins to fully initialize
sleep 30

for i in {1..10}; do
    ADMIN_PASSWORD=$(kubectl exec -n jenkins $JENKINS_POD -- cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASSWORD" ]; then
        break
    fi
    echo "Waiting for Jenkins to create admin password... (attempt $i/10)"
    sleep 15
done

echo ""
echo -e "${GREEN}🎉 Jenkins is successfully deployed and running!${NC}"
echo ""
echo -e "${BLUE}==================== ACCESS INFORMATION ====================${NC}"

if [ -n "$ADMIN_PASSWORD" ]; then
    echo -e "${GREEN}Jenkins Admin Password: $ADMIN_PASSWORD${NC}"
else
    echo -e "${YELLOW}Admin password not ready yet. Get it with:${NC}"
    echo "kubectl exec -n jenkins $JENKINS_POD -- cat /var/jenkins_home/secrets/initialAdminPassword"
fi

echo ""
echo -e "${BLUE}Access Methods:${NC}"
echo "1. Port Forward (immediate access):"
echo "   kubectl port-forward -n jenkins svc/jenkins 8080:8080"
echo "   Then open: http://localhost:8080"
echo ""

# Check for external LoadBalancer
EXTERNAL_IP=$(kubectl get service jenkins -n jenkins -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "2. External LoadBalancer:"
    echo "   http://$EXTERNAL_IP:8080"
else
    echo "2. External LoadBalancer (still provisioning):"
    echo "   Check status with: kubectl get service jenkins -n jenkins"
    echo "   Once EXTERNAL-IP shows, access via: http://EXTERNAL-IP:8080"
fi

echo ""
echo -e "${BLUE}==================== NEXT STEPS ====================${NC}"
echo "1. Access Jenkins using one of the methods above"
echo "2. Use the admin password to login"
echo "3. Complete the Jenkins setup wizard"
echo "4. Install suggested plugins"
echo "5. Create a new admin user"
echo "6. Configure Jenkins for your blue-green deployment pipeline"
echo ""
echo -e "${GREEN}Setup completed successfully! 🚀${NC}"
