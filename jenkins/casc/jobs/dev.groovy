// PouwZK-dev: branches in the whole network before their PR is merged, and the
// dev network on the server (explorer-dev.<domain>, grafana-dev.<domain>).
//
// pouw-<repository>  BRANCH of that repository + main of the others: build, test,
//                    deploy to the dev network (jenkins/dev.Jenkinsfile)
// all                a branch per repository, for a change across repositories
// load               the default load of the dev network (jenkins/load.Jenkinsfile)
// load-test          a graded load test in a test copy (jenkins/load-test.Jenkinsfile)
//
// The parameters are defined here and not in the Jenkinsfiles, so Build with
// Parameters has them from the first build.
folder('PouwZK-dev') {
    displayName('PouwZK-dev')
    description('Try a branch in the whole network: push it to PoUW-ZK, then Build with Parameters in the job of its repository. ' +
        'When all tests pass, it is deployed to the shared dev network (the last deploy wins).')
}

def fromMain(String script) {
    return {
        cpsScm {
            scm {
                git {
                    remote { url('https://github.com/PoUW-ZK/pouw-deploy.git') }
                    branch('*/main')
                }
            }
            scriptPath(script)
            lightweight(true)
        }
    }
}

// The same test parameters as the Jenkinsfile of pouw-deploy (jenkins/tests.groovy)
def testParameters(context) {
    context.booleanParam('SMOKE', true, 'Smoke tests (e2e/smoke.sh)')
    context.booleanParam('BACKUP', true, 'A dump of the test copy and a trial restore of it')
    context.booleanParam('DEVNET', true, 'e2e tests of the devnet (e2e/test_devnet.py)')
    context.booleanParam('SERVICE_E2E', true, 'e2e tests of the services (their e2e/run.sh)')
    context.stringParam('SERVICES', '', 'Only the e2e of these services, e.g. node,indexer (empty = all)')
    context.stringParam('TESTS', '', 'Only the pytest tests that match this -k expression, e.g. "height or transfer" (empty = all)')
    context.booleanParam('DEPLOY', true,
        'Deploy to the dev network when the tests pass. Only a run of all tests deploys.')
}

['pouw-node', 'pouw-indexer', 'pouw-workload', 'pouw-dashboard', 'pouw-deploy'].each { repo ->
    pipelineJob("PouwZK-dev/${repo}") {
        displayName(repo)
        description("A branch of ${repo} with main of the other repositories: build, test, deploy to the dev network")
        parameters {
            stringParam('BRANCH', 'main', "Branch of ${repo}, pushed to PoUW-ZK (forks are not built)")
            testParameters(delegate)
        }
        definition fromMain('jenkins/dev.Jenkinsfile')
    }
}

pipelineJob('PouwZK-dev/all') {
    displayName('all')
    description('A branch per repository, for a change across repositories: build, test, deploy to the dev network')
    parameters {
        stringParam('NODE_BRANCH', 'main', 'Branch of pouw-node')
        stringParam('INDEXER_BRANCH', 'main', 'Branch of pouw-indexer')
        stringParam('WORKLOAD_BRANCH', 'main', 'Branch of pouw-workload')
        stringParam('DASHBOARD_BRANCH', 'main', 'Branch of pouw-dashboard')
        stringParam('DEPLOY_BRANCH', 'main', 'Branch of pouw-deploy (compose, tests, scripts)')
        testParameters(delegate)
    }
    definition fromMain('jenkins/dev.Jenkinsfile')
}

pipelineJob('PouwZK-dev/load') {
    displayName('load')
    description('Switch the default load of the dev network: SCENARIO again and again, off = no load')
    parameters {
        choiceParam('SCENARIO', ['transfers-steady', 'transfers-spike', 'transfers', 'devnet', 'smoke', 'soak', 'off'],
            'steady: low constant multi-node load (the default); spike: alternating high/low load; transfers: full 20 tx/s stress; off: no load')
    }
    definition fromMain('jenkins/load.Jenkinsfile')
}

// Load test of pouw-deploy#44, started by hand with a scenario of pouw-workload
pipelineJob('PouwZK-dev/load-test') {
    displayName('load-test')
    description('pouw-workload scenario against a test copy of the network; report in the artifacts and in Tests (suite load)')
    definition fromMain('jenkins/load-test.Jenkinsfile')
}
