// Load test (pouw-deploy#44): a scenario of pouw-workload against a test copy of
// the network with the :main images from GHCR (make test-load). The report is
// in the artifacts (reports/load: Markdown summary, CSV per operation, last
// status of the generator) and in Tests (suite load, one test per operation).
// Started by hand with "Build with Parameters".
//
// The agent cannot reach staging (network jenkins only, PR code runs on it).
// For the panels of PoUW · Load test in the Grafana of staging, run
// `make load SCENARIO=...` on the server.

pipeline {
    agent { label 'docker' }

    parameters {
        choice(name: 'SCENARIO', choices: ['devnet', 'smoke', 'soak'],
            description: 'devnet: reads of the real devnet (1 min); smoke: chain head (90 s); soak: 1 hour')
    }

    options {
        timeout(time: 120, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    environment {
        TEST_PROJECT = "pouw-load-${env.EXECUTOR_NUMBER}"
    }

    stages {
        stage('Load test') {
            steps {
                script {
                    currentBuild.description = "scenario ${params.SCENARIO}"
                }
                sh "make test-load SCENARIO=${params.SCENARIO}"
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'reports/load/*.xml'
            archiveArtifacts artifacts: 'reports/load/**', allowEmptyArchive: true
        }
        unsuccessful {
            sh 'docker compose -p $TEST_PROJECT logs --no-color --tail=300 > logs.txt || true'
            archiveArtifacts artifacts: 'logs.txt', allowEmptyArchive: true
        }
        cleanup {
            sh 'make test-down || true'
            cleanWs()
        }
    }
}
