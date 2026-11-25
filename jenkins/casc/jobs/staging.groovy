// PouwZK-staging: main of every repository and the staging network.
//
// Every PoUW-ZK repository that has a Jenkinsfile gets its own multibranch job
// in PoUW-ZK. A build starts on push and PR (GitHub App webhook) or manually in
// the UI; the nightly build of main of pouw-deploy deploys to staging.
//
// Jenkins does not build PRs from forks: the repositories are public and
// foreign code would run on our server. To get Jenkins on your branch, push it to PoUW-ZK.
folder('PouwZK-staging') {
    displayName('PouwZK-staging')
    description('main of every repository: CI on push and PR, the nightly build of pouw-deploy deploys to staging')
}

organizationFolder('PouwZK-staging/PoUW-ZK') {
    displayName('PoUW-ZK')
    description('PoUW-ZK repositories that have a Jenkinsfile')
    organizations {
        github {
            repoOwner('PoUW-ZK')
            apiUri('https://api.github.com')
            credentialsId('github-app')
            traits {
                gitHubBranchDiscovery {
                    // branches that are not PRs
                    strategyId(1)
                }
                gitHubPullRequestDiscovery {
                    // PR merged with target branch
                    strategyId(1)
                }
            }
        }
    }
    projectFactories {
        workflowMultiBranchProjectFactory {
            scriptPath('Jenkinsfile')
        }
    }
    orphanedItemStrategy {
        discardOldItems {
            daysToKeep(7)
        }
    }
    triggers {
        periodicFolderTrigger {
            interval('1d')
        }
    }
}

// The default load of staging (workload-driver), jenkins/load.Jenkinsfile
pipelineJob('PouwZK-staging/load') {
    displayName('load')
    description('Switch the default load of staging: SCENARIO again and again, off = no load. Watch it in Grafana: PoUW · Load test')
    parameters {
        choiceParam('SCENARIO', ['transfers-steady', 'transfers-spike', 'transfers', 'devnet', 'smoke', 'soak', 'off'],
            'steady: low constant multi-node load (the default); spike: alternating high/low load; transfers: full 20 tx/s stress; off: no load')
    }
    definition {
        cpsScm {
            scm {
                git {
                    remote { url('https://github.com/PoUW-ZK/pouw-deploy.git') }
                    branch('*/main')
                }
            }
            scriptPath('jenkins/load.Jenkinsfile')
            lightweight(true)
        }
    }
}
