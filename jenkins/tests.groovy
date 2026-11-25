// Test selection of Build with Parameters, shared by Jenkinsfile (PouwZK-staging)
// and jenkins/dev.Jenkinsfile (PouwZK-dev): load 'jenkins/tests.groovy'.
//
// The parameters SMOKE, BACKUP, DEVNET, SERVICE_E2E pick the test groups,
// SERVICES the e2e of some services and TESTS the pytest tests (a -k
// expression). On the first build of a branch the parameters do not exist yet
// (null), that counts as everything.

// [suites, services, tests: the make test variables, full: everything selected]
def selection(params) {
    def picked = []
    if (params.SMOKE != false) { picked.add('smoke') }
    if (params.BACKUP != false) { picked.add('backup') }
    if (params.DEVNET != false) { picked.add('devnet') }
    if (params.SERVICE_E2E != false) { picked.add('services') }
    def suites = picked.join(',')
    def services = (params.SERVICES ?: '').trim()
    def tests = (params.TESTS ?: '').trim()
    if (!suites) {
        error 'No test group selected'
    }
    if (!(services ==~ /[a-z,\- ]*/)) {
        error "SERVICES: comma-separated names, e.g. node,indexer (got: ${services})"
    }
    if (!(tests ==~ /[A-Za-z0-9_ .()\[\]\-]*/)) {
        error "TESTS: a pytest -k expression of names, and/or/not and brackets (got: ${tests})"
    }
    return [suites: suites, services: services.replace(' ', ''), tests: tests,
            full: suites == 'smoke,backup,devnet,services' && !services && !tests]
}

// One line for the build description, empty for a full run
def describe(t) {
    return t.full ? '' : "suites: ${t.suites}" + (t.services ? " · services: ${t.services}" : '') +
        (t.tests ? " · tests: ${t.tests}" : '')
}

// make test with the selection, as environment, so the values never pass
// through a shell command line
def run(t) {
    withEnv(["SUITES=${t.suites}", "SERVICES=${t.services}", "TESTS=${t.tests}"]) {
        sh 'make test'
    }
}

return this
