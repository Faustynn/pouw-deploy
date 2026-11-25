// PouwZK-dev: a branch in the whole network, before its PR is merged.
//
// Job pouw-<repository>: BRANCH of that repository, main of the others.
// Job all: a branch per repository (NODE_BRANCH, ..., DEPLOY_BRANCH) for a
// change across repositories.
//
// The branch must be pushed to PoUW-ZK: Jenkins does not build forks, and
// docker.yml publishes :sha-xxxxxxx of every branch pushed there. The job
// builds the images (make images REFS=...), tests them in a test copy of the
// network with the selection of jenkins/tests.groovy and, when everything was
// selected and passed and DEPLOY is on, deploys the same commits to the dev
// network on the server (explorer-dev.<domain>) after their images are in
// GHCR. The dev network is shared: the last deploy wins.

// Repository -> branch, from the parameters of this job
def branches() {
    if (env.JOB_BASE_NAME == 'all') {
        return ['pouw-node': params.NODE_BRANCH, 'pouw-indexer': params.INDEXER_BRANCH,
                'pouw-workload': params.WORKLOAD_BRANCH, 'pouw-dashboard': params.DASHBOARD_BRANCH,
                'pouw-deploy': params.DEPLOY_BRANCH]
    }
    return [(env.JOB_BASE_NAME): params.BRANCH]
}

refs = [:]
selection = null
deploySha = ''

pipeline {
    agent { label 'docker' }

    options {
        // as the Jenkinsfile: a cold build, the tests and the wait for GHCR
        timeout(time: 120, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
        skipDefaultCheckout()
    }

    environment {
        // Two builds on one agent must not share a compose project or images
        TEST_PROJECT = "pouw-test-${env.EXECUTOR_NUMBER}"
        IMAGE_TAG = "ci-${env.EXECUTOR_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    refs = branches().collectEntries { repo, branch ->
                        def b = (branch ?: 'main').trim()
                        if (!(b ==~ /[A-Za-z0-9._\/-]+/) || b.contains('..')) {
                            error "Branch of ${repo}: a branch name like feature/x (got: ${b})"
                        }
                        [(repo): b]
                    }
                    // pouw-deploy itself from its branch (job pouw-deploy or all), else main
                    checkout([$class: 'GitSCM',
                        branches: [[name: "refs/heads/${refs['pouw-deploy'] ?: 'main'}"]],
                        userRemoteConfigs: [[url: 'https://github.com/PoUW-ZK/pouw-deploy.git']]])
                    deploySha = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    selection = load('jenkins/tests.groovy').selection(params)
                }
            }
        }
        stage('Config check') {
            steps {
                sh 'make check'
            }
        }
        stage('Build services') {
            steps {
                script {
                    def services = refs.findAll { repo, branch -> repo != 'pouw-deploy' }
                        .collect { repo, branch -> "${repo}=${branch}" }.join(' ')
                    withEnv(["REFS=${services}"]) {
                        sh 'make images'
                    }
                    def tests = load 'jenkins/tests.groovy'
                    currentBuild.displayName = "#${env.BUILD_NUMBER} " +
                        refs.collect { repo, branch -> branch == 'main' ? null : "${repo - 'pouw-'}:${branch}" }
                            .findAll { it }.join(' ')
                    currentBuild.description = readFile('build/versions.txt').trim() +
                        "\npouw-deploy ${deploySha.take(7)} (${refs['pouw-deploy'] ?: 'main'})" +
                        (selection.full ? '' : '\n' + tests.describe(selection))
                }
            }
        }
        stage('Tests') {
            steps {
                script {
                    load('jenkins/tests.groovy').run(selection)
                }
            }
        }
        stage('Images in GHCR') {
            when { expression { params.DEPLOY && selection?.full } }
            steps {
                sh './scripts/ghcr-wait.sh build/versions.env'
            }
        }
        stage('Deploy to dev') {
            when { expression { params.DEPLOY && selection?.full } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'github-app',
                        usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
                    withEnv(["DEPLOY_SHA=${deploySha}"]) {
                        sh './scripts/gh-deploy.sh dev deploy "$DEPLOY_SHA"'
                    }
                }
                script {
                    currentBuild.description += '\ndeployed to the dev network'
                }
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'reports/*.xml'
            archiveArtifacts artifacts: 'build/versions.txt', allowEmptyArchive: true
        }
        unsuccessful {
            sh 'docker compose -p $TEST_PROJECT logs --no-color --tail=300 > logs.txt || true'
            archiveArtifacts artifacts: 'logs.txt', allowEmptyArchive: true
        }
        // cleanup runs after the other post blocks, otherwise the logs would already be gone
        cleanup {
            sh 'make test-down || true'
            sh 'docker image prune -f || true'
            cleanWs()
        }
    }
}
