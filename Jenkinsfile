pipeline {
    agent {
        docker {
            image 'node:18'
            args '-v /var/run/docker.sock:/var/run/docker.sock'
        }
    }

    environment {
        AWS_ACCOUNT_ID = '603480426027'
        AWS_REGION = 'us-west-2'
        ECR_REPOSITORY = 'bluegreen-app'
        ECR_URI = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"
        CLUSTER_NAME = 'jenkins-bluegreen-cluster'
        APP_NAMESPACE = 'bluegreen-app'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.BUILD_NUMBER = "${BUILD_NUMBER}"
                    env.GIT_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                }
            }
        }

        stage('Build Application') {
            steps {
                dir('app') {
                    sh 'npm install'
                    sh 'npm test || true'
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                dir('app') {
                    sh """
                        docker build -t ${ECR_URI}:${BUILD_NUMBER} .
                        docker tag ${ECR_URI}:${BUILD_NUMBER} ${ECR_URI}:latest
                    """
                }
            }
        }

        stage('Push to ECR') {
            steps {
                sh """
                    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}
                    docker push ${ECR_URI}:${BUILD_NUMBER}
                    docker push ${ECR_URI}:latest
                """
            }
        }

        stage('Deploy to Staging') {
            steps {
                script {
                    def currentEnv = getCurrentActiveEnvironment()
                    def targetEnv = (currentEnv == 'blue') ? 'green' : 'blue'

                    echo "Current active environment: ${currentEnv}"
                    echo "Deploying to: ${targetEnv}"

                    sh """
                        sed 's/\\\${ECR_URI}/${ECR_URI}/g; s/\\\${BUILD_NUMBER}/${BUILD_NUMBER}/g' k8s/app/${targetEnv}-deployment-template.yaml | kubectl apply -f -
                        kubectl rollout status deployment/bluegreen-app-${targetEnv} -n ${APP_NAMESPACE} --timeout=300s
                    """

                    env.TARGET_ENV = targetEnv
                }
            }
        }

        stage('Run Tests') {
            steps {
                script {
                    sh """
                        echo "Testing ${env.TARGET_ENV} environment"
                        kubectl wait --for=condition=ready pod -l app=bluegreen-app,environment=${env.TARGET_ENV} -n ${APP_NAMESPACE} --timeout=300s
                        kubectl port-forward -n ${APP_NAMESPACE} svc/bluegreen-app-${env.TARGET_ENV} 8080:80 &
                        PF_PID=\$!
                        sleep 10

                        curl -f http://localhost:8080/health || exit 1
                        curl -f http://localhost:8080/api/info || exit 1
                        curl -f http://localhost:8080/ || exit 1

                        kill \$PF_PID || true
                        echo "All tests passed for ${env.TARGET_ENV} environment"
                    """
                }
            }
        }

        stage('Switch Traffic') {
            steps {
                script {
                    input message: "Switch traffic to ${env.TARGET_ENV} environment?", ok: "Deploy"
                    sh """
                        kubectl patch service bluegreen-app-main -n ${APP_NAMESPACE} -p '{"spec":{"selector":{"environment":"${env.TARGET_ENV}"}}}'
                        echo "Traffic switched to ${env.TARGET_ENV} environment"
                        kubectl get service bluegreen-app-main -n ${APP_NAMESPACE} -o jsonpath='{.spec.selector}'
                    """
                }
            }
        }

        stage('Cleanup Old Environment') {
            steps {
                script {
                    def oldEnv = (env.TARGET_ENV == 'blue') ? 'green' : 'blue'
                    timeout(time: 5, unit: 'MINUTES') {
                        input message: "Scale down ${oldEnv} environment?", ok: "Scale Down"
                    }
                    sh """
                        kubectl scale deployment bluegreen-app-${oldEnv} -n ${APP_NAMESPACE} --replicas=1
                        echo "Scaled down ${oldEnv} environment to 1 replica"
                    """
                }
            }
        }
    }

    post {
        success {
            echo 'Blue-Green deployment completed successfully!'
            echo "Application deployed to: ${env.TARGET_ENV} environment"
        }
        failure {
            echo 'Blue-Green deployment failed!'
            script {
                if (env.TARGET_ENV) {
                    def rollbackEnv = (env.TARGET_ENV == 'blue') ? 'green' : 'blue'
                    sh """
                        echo "Rolling back to ${rollbackEnv} environment"
                        kubectl patch service bluegreen-app-main -n ${APP_NAMESPACE} -p '{"spec":{"selector":{"environment":"${rollbackEnv}"}}}'
                    """
                }
            }
        }
        always {
            sh 'docker system prune -f || true'
        }
    }
}

// Helper function to determine current active environment
def getCurrentActiveEnvironment() {
    def currentEnv = 'blue'
    try {
        currentEnv = sh(
            script: "kubectl get service bluegreen-app-main -n ${APP_NAMESPACE} -o jsonpath='{.spec.selector.environment}'",
            returnStdout: true
        ).trim()
    } catch (Exception e) {
        echo "Could not determine current environment, defaulting to blue. Error: ${e.getMessage()}"
    }
    return currentEnv ?: 'blue'
}
