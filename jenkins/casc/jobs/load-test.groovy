// Load test of pouw-deploy#44: jenkins/load-test.Jenkinsfile from main, started
// by hand with a scenario of pouw-workload (Build with Parameters).
pipelineJob('pouw-load-test') {
    displayName('Load test')
    description('pouw-workload scenario against a test copy of the network; report in the artifacts and in Tests (suite load)')
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('https://github.com/PoUW-ZK/pouw-deploy.git') }
                    branch('*/main')
                }
            }
            scriptPath('jenkins/load-test.Jenkinsfile')
            lightweight(true)
        }
    }
}
