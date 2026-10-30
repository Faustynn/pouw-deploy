# pouw-deploy

[![Jenkins](https://jenkins.147-175-151-18.sslip.io/buildStatus/icon?job=PoUW-ZK%2Fpouw-deploy%2Fmain&subject=nightly)](https://jenkins.147-175-151-18.sslip.io/job/PoUW-ZK/job/pouw-deploy/job/main/)

Deployment of the whole PoUW-ZK network: Docker Compose for the services,
monitoring (Prometheus, Grafana), Jenkins for whole-network tests and the
nightly deploy to the staging server.

| Service | Staging URL |
|---|---|
| Jenkins | <https://jenkins.147-175-151-18.sslip.io> |
| Grafana | <https://grafana.147-175-151-18.sslip.io> |

## Quick start (local)

Requirements: Docker with Compose v2.24+, `make`, `openssl`, `ssh-keygen`.

```bash
cp .env.example .env
make up            # Postgres, Hasura on http://localhost:8081,
                   # Prometheus on http://localhost:9090, Grafana on http://localhost:3000
make test          # network tests in a separate copy, results in reports/
make test-down
make down
```

Grafana login: `admin` / `.secrets/grafana_admin_password`.
Hasura admin secret: `.secrets/hasura_admin_secret`. Postgres has no port on
the host: `docker compose exec postgres psql -U pouw`.

## The whole network from your working copies

With the service repositories cloned next to this one (`../pouw-node`,
`../pouw-indexer`, `../pouw-workload`, `../pouw-dashboard`, e.g. by
`.github/scripts/sync-repos.sh`):

```bash
make dev           # builds every service from ../pouw-* (uncommitted changes too)
                   # as :local images and starts the whole network
make dev-test      # the same images, smoke and e2e tests in a separate copy
make down          # stops everything, data is kept
```

`make dev` = `make images up SRC=..`: the images are built from whatever
branch each working copy is on (listed in `build/versions.txt`) and the
`network` profile is added, so node-1, indexer, workload and dashboard run too.
Fixture blocks for the explorer: `make seed`.

Without `SRC` the services come from GHCR (`:main`). They stay in the
`network` profile until their images exist there. When a service gets its
image, delete its `profiles` line in `compose.yml`, from then on `make up`,
the nightly test and staging run it.

## Jenkins locally

Set `COMPOSE_PROFILES=jenkins` and `JENKINS_LOCAL_BRANCH=<your pushed branch>`
in `.env`, then `make up` and open <http://localhost:8080>
(`admin` / `.secrets/jenkins_admin_password`).

## Staging

Changes reach the server only through `main`: every evening Jenkins tests the
services from `main` and, if the tests pass, the Deploy workflow deploys the
same versions. Manual deploy, rollback, restart and status: GitHub → Actions →
Deploy. Details (server setup, passwords, troubleshooting) are in
[pouw-docs → Server](https://pouw-zk.github.io/pouw-docs/server/).

## Commands

```text
make help       List of commands
make dev        Build the services from ../pouw-* and start the whole network locally
make dev-test   Build the services from ../pouw-* and test them in a separate copy
make secrets    Prepare secrets (random locally, from pass on the server)
make up         Start services according to COMPOSE_PROFILES
make down       Stop services of all profiles (data is kept)
make restart    Restart services, e.g. after a password change in pass
make seed       Load the fixture blocks of pouw-indexer into the running network
make ps         Service status
make logs       Logs, e.g. make logs s=jenkins
make check      Validate compose for all profiles and the Prometheus config
make images     Build service images from main (or SRC=..), e.g. make images test IMAGE_TAG=local
make test       Smoke and e2e tests in a separate copy of the network (results in reports/)
make test-down  Remove the test copy of the network
```

Passwords never go into git or `.env`, and Jenkins is configured only through
`jenkins/casc/` (changes in the UI are lost on restart).
