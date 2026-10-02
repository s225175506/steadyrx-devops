// SteadyRx DevOps pipeline (SIT753 7.3HD) — Mac / Colima agent
// Build -> Test -> Code Quality -> Security -> Deploy -> Release -> Monitoring
// Every stage works on the same versioned image, and each stage is a gate.

def dockerTest(String cmd) {
    // Runs a command inside the test image with the reports folder mounted.
    sh "docker run --rm -v \"\$PWD/reports:/app/reports\" steadyrx-test:${env.IMAGE_TAG} ${cmd}"
}

pipeline {
    agent any

    parameters {
        booleanParam(name: 'SIMULATE_INCIDENT', defaultValue: true,
            description: 'Run the brute-force login incident drill against production after release')
        booleanParam(name: 'CHAOS_API_DOWN', defaultValue: false,
            description: 'Also stop the production API to prove the ApiDown alert and recovery')
    }

    environment {
        REGISTRY        = 'localhost:5000'
        IMAGE           = 'steadyrx-api'
        VERSION_PREFIX  = '1.0'
        // Colima often ships without the buildx plugin; classic builder is enough for --target.
        DOCKER_BUILDKIT = '0'
        // Colima Docker socket on this Mac Jenkins agent
        DOCKER_HOST     = "unix://${HOME}/.colima/default/docker.sock"
        PATH            = "/opt/homebrew/bin:/usr/local/bin:${env.PATH}"
    }

    triggers {
        pollSCM('H/2 * * * *')
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 45, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
    }

    stages {
        stage('Build') {
            steps {
                script {
                    env.GIT_SHORT = sh(returnStdout: true, script: 'git rev-parse --short HEAD').trim()
                    env.VERSION = "${env.VERSION_PREFIX}.${env.BUILD_NUMBER}"
                    env.IMAGE_TAG = "${env.VERSION}-${env.GIT_SHORT}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} v${env.VERSION}"
                    currentBuild.description = "commit ${env.GIT_SHORT}, image ${env.IMAGE}:${env.IMAGE_TAG}"
                }
                echo "Building ${IMAGE}:${IMAGE_TAG} from commit ${GIT_SHORT}"
                sh 'rm -rf reports && mkdir -p reports'
                sh 'bash ci/ensure-docker.sh'
                sh 'bash ci/ensure-registry.sh'
                // Local registry often needs insecure-registries; also tag locally if push fails
                sh '''
                    set -e
                    docker build --target runtime \
                      --build-arg APP_VERSION="$VERSION" \
                      --build-arg BUILD_SHA="$GIT_SHORT" \
                      -t "$REGISTRY/$IMAGE:$IMAGE_TAG" \
                      -t "$IMAGE:$IMAGE_TAG" .
                    docker build --target test -t "steadyrx-test:$IMAGE_TAG" .
                    if docker push "$REGISTRY/$IMAGE:$IMAGE_TAG"; then
                      echo "Pushed artefact to $REGISTRY/$IMAGE:$IMAGE_TAG"
                    else
                      echo "WARN: push to local registry failed — continuing with the local image tag (compose pull is optional)."
                    fi
                    docker image inspect "$REGISTRY/$IMAGE:$IMAGE_TAG" --format "{{json .}}" > reports/build-image.json
                    echo "Artefact available as $REGISTRY/$IMAGE:$IMAGE_TAG"
                '''
            }
        }

        stage('Test') {
            steps {
                echo 'Unit and integration tests with pytest. The stage fails below 90% coverage.'
                dockerTest('pytest tests/unit tests/integration --junitxml=reports/junit.xml --cov --cov-report=xml:reports/coverage.xml --cov-report=term --cov-fail-under=90')
            }
            post {
                always { junit testResults: 'reports/junit.xml', allowEmptyResults: false }
            }
        }

        stage('Code Quality') {
            steps {
                echo 'Local gates: flake8, pylint >= 9.5, radon and xenon complexity limits.'
                dockerTest('bash ci/quality.sh')
                echo 'SonarCloud analysis (skipped if SONAR_TOKEN credential is missing).'
                script {
                    try {
                        withCredentials([string(credentialsId: 'SONAR_TOKEN', variable: 'SONAR_TOKEN')]) {
                            sh '''
                              docker run --rm -e SONAR_TOKEN \
                                -v "$PWD:/usr/src" \
                                sonarsource/sonar-scanner-cli:11.4 \
                                -Dsonar.projectVersion="$VERSION" \
                                -Dsonar.qualitygate.wait=true \
                                -Dsonar.qualitygate.timeout=300
                            '''
                        }
                    } catch (err) {
                        echo "SonarCloud step skipped or failed soft: ${err.getMessage()}"
                        echo 'Local quality gates already passed — continuing without SonarCloud.'
                    }
                }
            }
        }

        stage('Security') {
            failFast true
            parallel {
                stage('SAST and dependencies') {
                    steps {
                        echo 'Bandit scans the source. pip-audit checks pinned dependencies.'
                        dockerTest('bash ci/security.sh')
                    }
                }
                stage('Container image') {
                    steps {
                        echo 'Trivy scans the runtime image for HIGH/CRITICAL vulns.'
                        sh '''
                          set -e
                          # Containers run inside the Colima VM, so mount the guest
                          # docker.sock — not the host path under ~/.colima/...
                          docker run --rm \
                            -v /var/run/docker.sock:/var/run/docker.sock \
                            -v steadyrx-trivy-cache:/root/.cache \
                            -v "$PWD/reports:/reports" \
                            aquasec/trivy:0.69.3 image --scanners vuln \
                            --format json --output /reports/trivy-image.json \
                            "$REGISTRY/$IMAGE:$IMAGE_TAG" || true
                          docker run --rm \
                            -v /var/run/docker.sock:/var/run/docker.sock \
                            -v steadyrx-trivy-cache:/root/.cache \
                            aquasec/trivy:0.69.3 image --scanners vuln \
                            --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
                            "$REGISTRY/$IMAGE:$IMAGE_TAG"
                        '''
                    }
                }
                stage('Secrets and IaC') {
                    steps {
                        echo 'Trivy scans the repository for secrets and Dockerfile misconfiguration.'
                        sh '''
                          set -e
                          docker run --rm \
                            -v steadyrx-trivy-cache:/root/.cache \
                            -v "$PWD:/src" \
                            aquasec/trivy:0.69.3 fs --scanners secret,misconfig \
                            --skip-dirs /src/reports \
                            --format json --output /src/reports/trivy-repo.json /src || true
                          docker run --rm \
                            -v steadyrx-trivy-cache:/root/.cache \
                            -v "$PWD:/src" \
                            aquasec/trivy:0.69.3 fs --scanners secret,misconfig \
                            --skip-dirs /src/reports \
                            --severity HIGH,CRITICAL --exit-code 1 /src
                        '''
                    }
                }
            }
        }

        stage('Deploy') {
            steps {
                echo "Deploying ${IMAGE_TAG} to the staging environment with Docker Compose"
                sh 'bash ci/deploy.sh staging "$IMAGE_TAG" "$VERSION"'
                echo 'Post-deployment smoke tests against staging'
                sh '''
                  docker run --rm \
                    -e BASE_URL=http://host.docker.internal:8001 \
                    -e EXPECTED_VERSION="$VERSION" \
                    -v "$PWD/reports:/app/reports" \
                    "steadyrx-test:$IMAGE_TAG" \
                    pytest tests/smoke --junitxml=reports/smoke-staging.xml
                '''
            }
            post {
                always { junit testResults: 'reports/smoke-staging.xml', allowEmptyResults: true }
            }
        }

        stage('Release') {
            steps {
                echo "Promoting ${IMAGE_TAG} to production as release v${VERSION}"
                sh '''
                  set -e
                  docker tag "$REGISTRY/$IMAGE:$IMAGE_TAG" "$REGISTRY/$IMAGE:v$VERSION"
                  docker tag "$REGISTRY/$IMAGE:$IMAGE_TAG" "$REGISTRY/$IMAGE:stable"
                  docker push "$REGISTRY/$IMAGE:v$VERSION"
                  docker push "$REGISTRY/$IMAGE:stable"
                '''
                sh 'bash ci/deploy.sh production "v$VERSION" "$VERSION"'
                sh '''
                  docker run --rm \
                    -e BASE_URL=http://host.docker.internal:8000 \
                    -e EXPECTED_VERSION="$VERSION" \
                    -v "$PWD/reports:/app/reports" \
                    "steadyrx-test:$IMAGE_TAG" \
                    pytest tests/smoke --junitxml=reports/smoke-production.xml
                '''
                sh 'git -c user.name=Jenkins -c user.email=jenkins@steadyrx.local tag -f -a "v$VERSION" -m "SteadyRx release v$VERSION (Jenkins build $BUILD_NUMBER)" || true'
                sh 'bash ci/release-notes.sh "$VERSION" "$IMAGE_TAG"'
                script {
                    try {
                        withCredentials([usernamePassword(credentialsId: 'github-push',
                                usernameVariable: 'GH_USER', passwordVariable: 'GH_TOKEN')]) {
                            sh 'git push "https://${GH_USER}:${GH_TOKEN}@github.com/s225175506/steadyrx-devops.git" "v${VERSION}" || true'
                        }
                    } catch (err) {
                        echo "Git tag v${env.VERSION} created locally. Remote push skipped: ${err.getMessage()}"
                    }
                }
            }
            post {
                always { junit testResults: 'reports/smoke-production.xml', allowEmptyResults: true }
            }
        }

        stage('Monitoring') {
            steps {
                echo 'Starting Prometheus, Alertmanager, Grafana and the team alert channel.'
                sh 'bash ci/monitoring.sh'
                script {
                    if (params.SIMULATE_INCIDENT == null || params.SIMULATE_INCIDENT) {
                        sh 'bash ci/simulate-incident.sh brute-force'
                    }
                    if (params.CHAOS_API_DOWN) {
                        sh 'bash ci/simulate-incident.sh api-down'
                    }
                }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: true
        }
        success {
            echo "Release v${env.VERSION} is live. API http://localhost:8000/docs, Grafana http://localhost:3000/d/steadyrx, alerts http://localhost:9095/"
            sh 'bash ci/notify.sh SUCCEEDED info "Release v${VERSION} deployed to production" || true'
        }
        failure {
            sh 'bash ci/notify.sh FAILED "Pipeline failed for ${IMAGE_TAG}" critical || true'
        }
        cleanup {
            sh 'docker image prune -f || true'
        }
    }
}
