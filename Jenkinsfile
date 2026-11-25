// Whole-network test: services are built from main of their repositories and
// started in a test copy of the network, the devnet with 3 nodes and a genesis
// of its own. Then the smoke tests (e2e/smoke.sh), a backup with a trial
// restore, the e2e tests of the devnet (e2e/test_devnet.py) and the e2e tests
// of every service. Runs on push and PR, every evening on main (from scratch,
// without Docker cache) and manually via "Build Now". Individual test results
// are in Tests on the build page (suites smoke, devnet, pouw-*), service
// commits in the build description.
//
// After successful tests, the evening build of main deploys the same versions
// to staging. If tests or the deploy fail, staging stays on the previous
// version and an e-mail goes to NOTIFY_EMAIL (main only, PRs show on GitHub).

// Build with Parameters picks the test groups (SMOKE, BACKUP, DEVNET,
// SERVICE_E2E), the services and the pytest tests (TESTS, a -k expression),
// see jenkins/tests.groovy. Push, PR and the evening build run everything;
// only such a full run of main deploys to staging. Branches of the services
// are tried in Jenkins → PouwZK-dev (jenkins/dev.Jenkinsfile).

// The selection (jenkins/tests.groovy), set in the stage Devnet tests
selection = null

// E-mail for builds of main, only when SMTP is configured. Without SMTP the build just logs that it skipped it.
def sendNotification(String subject, String body) {
    if (env.BRANCH_NAME != 'main') {
        return
    }
    if (!env.SMTP_HOST) {
        echo "SMTP is not configured, e-mail not sent: ${subject}"
        return
    }
    emailext to: env.NOTIFY_EMAIL, subject: subject, body: body
}

pipeline {
    agent { label 'docker' }

    options {
        // The nightly build alone takes about 50 minutes without Docker cache,
        // the tests 10-15 more; 60 aborted the nightly of 23 and 24 Nov
        timeout(time: 120, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    environment {
        // Two builds on one agent must not share a compose project or images
        TEST_PROJECT = "pouw-test-${env.EXECUTOR_NUMBER}"
        IMAGE_TAG = "ci-${env.EXECUTOR_NUMBER}"
        NOTIFY_EMAIL = 'alglivecompany@gmail.com'
    }

    triggers {
        cron(env.BRANCH_NAME == 'main' ? 'TZ=Europe/Bratislava\nH 21 * * *' : '')
    }

    parameters {
        booleanParam(name: 'SMOKE', defaultValue: true, description: 'Smoke tests (e2e/smoke.sh)')
        booleanParam(name: 'BACKUP', defaultValue: true, description: 'A dump of the test copy and a trial restore of it')
        booleanParam(name: 'DEVNET', defaultValue: true, description: 'e2e tests of the devnet (e2e/test_devnet.py)')
        booleanParam(name: 'SERVICE_E2E', defaultValue: true, description: 'e2e tests of the services (their e2e/run.sh)')
        string(name: 'SERVICES', defaultValue: '', trim: true,
            description: 'Only the e2e of these services, e.g. node,indexer (empty = all)')
        string(name: 'TESTS', defaultValue: '', trim: true,
            description: 'Only the pytest tests that match this -k expression, e.g. "height or transfer" (empty = all)')
    }

    stages {
        stage('Config check') {
            steps {
                sh 'make check'
            }
        }
        stage('Build services') {
            environment {
                NO_CACHE = "${currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause') ? '1' : ''}"
            }
            steps {
                sh 'make images'
                script {
                    currentBuild.description = readFile('build/versions.txt').trim()
                }
            }
        }
        stage('Devnet tests') {
            steps {
                script {
                    def tests = load 'jenkins/tests.groovy'
                    selection = tests.selection(params)
                    if (!selection.full) {
                        currentBuild.description = (currentBuild.description ?: '') + '\n' + tests.describe(selection)
                    }
                    tests.run(selection)
                }
            }
        }
        stage('Deploy to staging') {
            when {
                branch 'main'
                triggeredBy 'TimerTrigger'
                expression { selection?.full }
            }
            steps {
                withCredentials([usernamePassword(credentialsId: 'github-app',
                        usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
                    sh './scripts/gh-deploy.sh staging deploy "$GIT_COMMIT"'
                }
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'reports/*.xml'
            archiveArtifacts artifacts: 'build/versions.txt', allowEmptyArchive: true
        }
        // both FAILURE and ABORTED
        unsuccessful {
            sh 'docker compose -p $TEST_PROJECT logs --no-color --tail=300 > logs.txt || true'
            archiveArtifacts artifacts: 'logs.txt', allowEmptyArchive: true
            script {
                sendNotification('[PoUW Jenkins] FAILED: ${PROJECT_NAME} #${BUILD_NUMBER}',
                    'Build failed, staging stays on the previous version.\n\n' +
                    '${BUILD_URL}\n\nService commits:\n' + (currentBuild.description ?: '-') +
                    '\n\nTests: ${TEST_COUNTS, var="fail"} failed out of ${TEST_COUNTS, var="total"}\n' +
                    '${FAILED_TESTS, showStack=false, maxTests=20}\n\n' +
                    'End of log:\n${BUILD_LOG, maxLines=50}')
            }
        }
        fixed {
            script {
                sendNotification('[PoUW Jenkins] FIXED: ${PROJECT_NAME} #${BUILD_NUMBER}',
                    'Build of main passed after a previous failure.\n\n${BUILD_URL}\n\n' +
                    'Service commits:\n' + (currentBuild.description ?: '-'))
            }
        }
        // cleanup runs after the other post blocks, otherwise the logs would already be gone
        cleanup {
            sh 'make test-down || true'
            sh 'docker image prune -f || true'
            cleanWs()
        }
    }
}
