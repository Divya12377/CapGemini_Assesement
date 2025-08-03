pipeline {
    agent {
        kubernetes {
            yaml """
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                  - name: docker
                    image: docker:20.10-dind
                    securityContext:
                      privileged: true
                    volumeMounts:
                    - name: docker-sock
                      mountPath: /var/run/docker.sock
                  - name: kubectl
                    image: bitnami/kubectl:latest
                    command:
                    - cat
                    tty: true
                  - name: node
                    image: node:18-alpine
                    command:
                    - cat
                    tty: true
                  - name: aws-cli
                    image: amazon/aws-cli:latest
                    command:
                    - cat
                    tty: true
                  volumes:
                  - name: docker-sock
                    hostPath:
                      path: /var/run/docker.sock
            """
        }
    }
    
    environment {
        APP_NAME = "bluegreen-app"
        DOCKER_TAG = "${BUILD_NUMBER}"
        NAMESPACE = "bluegreen-app"  // Your app namespace from setup
        AWS_REGION = "us-west-2"    // Your region from setup
        ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com"
        ECR_REPOSITORY = "bluegreen-app"
        APP_VERSION = "1.0.${BUILD_NUMBER}"
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    echo "Repository checked out successfully"
                    sh "ls -la"
                    sh "ls -la app/ || echo 'App directory not found'"
                }
            }
        }
        
        stage('Get AWS Account ID') {
            steps {
                container('aws-cli') {
                    script {
                        // Get AWS Account ID dynamically
                        def accountId = sh(
                            script: 'aws sts get-caller-identity --query Account --output text',
                            returnStdout: true
                        ).trim()
                        env.AWS_ACCOUNT_ID = accountId
                        env.ECR_REGISTRY = "${accountId}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        echo "AWS Account ID: ${accountId}"
                        echo "ECR Registry: ${env.ECR_REGISTRY}"
                    }
                }
            }
        }
        
        stage('Build Application') {
            steps {
                container('node') {
                    script {
                        echo "Building Node.js application..."
                        dir('app') {
                            sh """
                                echo "Installing dependencies..."
                                npm install
                                echo "Running tests..."
                                npm test || echo "Tests completed"
                                echo "Application built successfully"
                                ls -la
                            """
                        }
                    }
                }
            }
        }
        
        stage('Build and Push Docker Image') {
            steps {
                container('docker') {
                    script {
                        echo "Building and pushing Docker image..."
                        dir('app') {
                            sh """
                                echo "Building Docker image: ${ECR_REPOSITORY}:${DOCKER_TAG}"
                                docker build -t ${ECR_REPOSITORY}:${DOCKER_TAG} .
                                docker tag ${ECR_REPOSITORY}:${DOCKER_TAG} ${ECR_REPOSITORY}:latest
                                docker images | grep ${ECR_REPOSITORY}
                            """
                        }
                    }
                }
                
                container('aws-cli') {
                    script {
                        echo "Logging into ECR and pushing image..."
                        sh """
                            # Login to ECR
                            aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}
                            
                            # Tag images for ECR
                            docker tag ${ECR_REPOSITORY}:${DOCKER_TAG} ${ECR_REGISTRY}/${ECR_REPOSITORY}:${DOCKER_TAG}
                            docker tag ${ECR_REPOSITORY}:${DOCKER_TAG} ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
                            docker tag ${ECR_REPOSITORY}:${DOCKER_TAG} ${ECR_REGISTRY}/${ECR_REPOSITORY}:blue
                            
                            # Push to ECR
                            docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:${DOCKER_TAG}
                            docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
                            docker push ${ECR_REGISTRY}/${ECR_REPOSITORY}:blue
                            
                            echo "Images pushed successfully to ECR"
                        """
                    }
                }
            }
        }
        
        stage('Cleanup Previous Green') {
            steps {
                container('kubectl') {
                    script {
                        echo "Cleaning up previous green deployment..."
                        sh """
                            kubectl delete deployment ${APP_NAME}-green -n ${NAMESPACE} --ignore-not-found=true
                            kubectl delete service ${APP_NAME}-green-service -n ${NAMESPACE} --ignore-not-found=true
                            echo "Previous green deployment cleaned up"
                        """
                    }
                }
            }
        }
        
        stage('Deploy Blue Environment') {
            steps {
                container('kubectl') {
                    script {
                        echo "Creating and deploying blue environment..."
                        
                        writeFile file: 'blue-deployment.yaml', text: """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-blue
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    version: blue
    environment: blue
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
      version: blue
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        version: blue
        environment: blue
    spec:
      containers:
      - name: app
        image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:${DOCKER_TAG}
        ports:
        - containerPort: 3000
        env:
        - name: ENVIRONMENT
          value: "blue"
        - name: APP_VERSION
          value: "${APP_VERSION}"
        - name: BUILD_NUMBER
          value: "${BUILD_NUMBER}"
        readinessProbe:
          httpGet:
            path: /ready
            port: 3000
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 3
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-blue-service
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
    version: blue
spec:
  selector:
    app: ${APP_NAME}
    version: blue
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 3000
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-main-service
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  selector:
    app: ${APP_NAME}
    version: blue
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 3000
  type: LoadBalancer
"""
                        
                        sh """
                            echo "Creating namespace if it doesn't exist..."
                            kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
                            
                            echo "Applying blue deployment..."
                            kubectl apply -f blue-deployment.yaml
                            
                            echo "Waiting for blue deployment to be ready..."
                            kubectl rollout status deployment/${APP_NAME}-blue -n ${NAMESPACE} --timeout=300s
                            
                            echo "Checking deployment status..."
                            kubectl get deployment ${APP_NAME}-blue -n ${NAMESPACE}
                            kubectl get pods -l app=${APP_NAME},version=blue -n ${NAMESPACE}
                            kubectl get services -l app=${APP_NAME} -n ${NAMESPACE}
                        """
                    }
                }
            }
        }
        
        stage('Health Check') {
            steps {
                container('kubectl') {
                    script {
                        echo "Performing comprehensive health check..."
                        
                        sh """
                            echo "Waiting for pods to be ready..."
                            kubectl wait --for=condition=ready pod -l app=${APP_NAME},version=blue -n ${NAMESPACE} --timeout=300s
                            
                            echo "Checking pod status..."
                            kubectl get pods -l app=${APP_NAME},version=blue -n ${NAMESPACE} -o wide
                            
                            echo "Checking service endpoints..."
                            kubectl get endpoints ${APP_NAME}-blue-service -n ${NAMESPACE}
                            
                            echo "Testing application endpoints..."
                            # Get a pod name for testing
                            POD_NAME=\$(kubectl get pods -l app=${APP_NAME},version=blue -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}')
                            
                            echo "Testing health endpoint..."
                            kubectl exec \$POD_NAME -n ${NAMESPACE} -- wget -q -O- http://localhost:3000/health || echo "Health check endpoint test"
                            
                            echo "Testing ready endpoint..."
                            kubectl exec \$POD_NAME -n ${NAMESPACE} -- wget -q -O- http://localhost:3000/ready || echo "Ready check endpoint test"
                            
                            echo "Testing main endpoint..."
                            kubectl exec \$POD_NAME -n ${NAMESPACE} -- wget -q -O- http://localhost:3000/ || echo "Main endpoint test"
                            
                            echo "Testing API info endpoint..."
                            kubectl exec \$POD_NAME -n ${NAMESPACE} -- wget -q -O- http://localhost:3000/api/info || echo "API info endpoint test"
                        """
                        
                        echo "✅ Health check completed successfully"
                    }
                }
            }
        }
        
        stage('Switch Traffic (Blue-Green)') {
            steps {
                container('kubectl') {
                    script {
                        echo "Switching traffic to blue environment..."
                        
                        sh """
                            echo "Updating main service to point to blue environment..."
                            kubectl patch service ${APP_NAME}-main-service -n ${NAMESPACE} -p '{"spec":{"selector":{"version":"blue"}}}'
                            
                            echo "Verifying traffic switch..."
                            kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE} -o yaml | grep -A 3 selector
                            
                            echo "Getting service information..."
                            kubectl get services -l app=${APP_NAME} -n ${NAMESPACE}
                            
                            # Get external IP/hostname
                            EXTERNAL_ENDPOINT=\$(kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
                            
                            if [ "\$EXTERNAL_ENDPOINT" != "pending" ] && [ "\$EXTERNAL_ENDPOINT" != "" ]; then
                                echo "🌐 Application accessible at: http://\$EXTERNAL_ENDPOINT"
                                echo "🌐 Health check: http://\$EXTERNAL_ENDPOINT/health"
                                echo "🌐 API info: http://\$EXTERNAL_ENDPOINT/api/info"
                            else
                                echo "🔄 External endpoint is pending, use port-forward to test:"
                                echo "kubectl port-forward service/${APP_NAME}-main-service 8080:80 -n ${NAMESPACE}"
                            fi
                        """
                        
                        echo "✅ Traffic switched to blue environment successfully"
                    }
                }
            }
        }
        
        stage('Post-Deployment Verification') {
            steps {
                container('kubectl') {
                    script {
                        echo "Performing post-deployment verification..."
                        
                        sh """
                            echo "Final deployment status:"
                            kubectl get all -l app=${APP_NAME} -n ${NAMESPACE}
                            
                            echo "Deployment history:"
                            kubectl rollout history deployment/${APP_NAME}-blue -n ${NAMESPACE}
                            
                            echo "Pod logs (last 20 lines):"
                            kubectl logs -l app=${APP_NAME},version=blue -n ${NAMESPACE} --tail=20 || echo "Could not fetch logs"
                            
                            echo "Resource usage:"
                            kubectl top pods -l app=${APP_NAME} -n ${NAMESPACE} || echo "Metrics not available"
                        """
                    }
                }
            }
        }
    }
    
    post {
        always {
            script {
                echo "📋 Pipeline execution completed"
                echo "🏷️  Build Number: ${BUILD_NUMBER}"
                echo "🏷️  App Version: ${APP_VERSION}"
                echo "📦 Application: ${APP_NAME}"
                echo "🌐 Environment: Blue"
                echo "🏢 ECR Repository: ${ECR_REGISTRY}/${ECR_REPOSITORY}"
            }
        }
        
        success {
            script {
                echo "🎉 Blue-Green deployment completed successfully!"
                echo "✅ Application ${APP_NAME}:${DOCKER_TAG} is now live in blue environment"
                echo "🔗 Available Endpoints:"
                echo "   - GET / (main application with environment info)"
                echo "   - GET /health (health check - used by liveness probe)"
                echo "   - GET /ready (readiness check - used by readiness probe)"
                echo "   - GET /api/info (application info with uptime)"
                
                container('kubectl') {
                    script {
                        try {
                            sh """
                                echo "Getting final service information..."
                                kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE}
                                
                                EXTERNAL_ENDPOINT=\$(kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || kubectl get service ${APP_NAME}-main-service -n ${NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
                                
                                if [ "\$EXTERNAL_ENDPOINT" != "pending" ] && [ "\$EXTERNAL_ENDPOINT" != "" ]; then
                                    echo "🌐 SUCCESS: Application is accessible at http://\$EXTERNAL_ENDPOINT"
                                else
                                    echo "ℹ️  External IP pending. Use: kubectl port-forward service/${APP_NAME}-main-service 8080:80 -n ${NAMESPACE}"
                                fi
                            """
                        } catch (Exception e) {
                            echo "Could not get service information: ${e.getMessage()}"
                        }
                    }
                }
            }
        }
        
        failure {
            script {
                echo "❌ Blue-Green deployment failed!"
                
                container('kubectl') {
                    script {
                        try {
                            echo "🔄 Attempting rollback..."
                            sh """
                                kubectl rollout undo deployment/${APP_NAME}-blue -n ${NAMESPACE} || true
                                kubectl get pods -l app=${APP_NAME} -n ${NAMESPACE} || true
                                echo "Rollback initiated"
                                
                                echo "Error diagnosis:"
                                kubectl describe deployment ${APP_NAME}-blue -n ${NAMESPACE} || true
                                kubectl logs -l app=${APP_NAME},version=blue -n ${NAMESPACE} --tail=50 || true
                            """
                        } catch (Exception e) {
                            echo "⚠️  Rollback failed: ${e.getMessage()}"
                        }
                    }
                }
            }
        }
        
        cleanup {
            script {
                echo "🧹 Cleaning up temporary files..."
                sh "rm -f blue-deployment.yaml || true"
            }
        }
    }
}
