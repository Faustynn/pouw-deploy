// The default load of a network on the server: workload-driver runs SCENARIO
// of pouw-workload again and again, off = no load (make load-start / load-stop).
// PouwZK-staging/load switches staging, PouwZK-dev/load the dev network; both
// go through the Deploy workflow (scripts/gh-deploy.sh → remote.sh load).
// Watch it in Grafana: PoUW · Load test.

pipeline {
    agent { label 'docker' }

    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }

    stages {
        stage('Switch the default load') {
            steps {
                script {
                    def network = env.JOB_NAME.startsWith('PouwZK-dev/') ? 'dev' : 'staging'
                    currentBuild.description = "${network}: ${params.SCENARIO}"
                    withCredentials([usernamePassword(credentialsId: 'github-app',
                            usernameVariable: 'GH_APP', passwordVariable: 'GH_TOKEN')]) {
                        withEnv(["NETWORK=${network}"]) {
                            sh './scripts/gh-deploy.sh "$NETWORK" load "$SCENARIO"'
                        }
                    }
                }
            }
        }
    }

    post {
        cleanup {
            cleanWs()
        }
    }
}
