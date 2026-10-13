# pouw-deploy

[![Jenkins](https://jenkins.147-175-151-18.sslip.io/buildStatus/icon?job=PoUW-ZK%2Fpouw-deploy%2Fmain&subject=nightly)](https://jenkins.147-175-151-18.sslip.io/job/PoUW-ZK/job/pouw-deploy/job/main/)

Deployment of the whole PoUW-ZK network: 

Docker Compose for the services,
Monitoring stack (Prometheus, Grafana), Jenkins for whole-network tests and the
nightly deploy to the staging server.

| Service | Staging URL |
|---|---|
| Jenkins | <https://jenkins.147-175-151-18.sslip.io> |
| Grafana | <https://grafana.147-175-151-18.sslip.io> |

## Quick start (local)

Requirements: Docker with Compose v2.24+, `make`, `openssl`, `ssh-keygen`.

```bash
cp .env.example .env
make up            # Prometheus on http://localhost:9090, Grafana on http://localhost:3000
make test          # network tests in a separate copy, results in reports/smoke.xml
make test-down
```

Grafana login: `admin` / `.secrets/grafana_admin_password`.

To also run Jenkins locally, set `COMPOSE_PROFILES=jenkins` and
`JENKINS_LOCAL_BRANCH=<your pushed branch>` in `.env`, then `make up` and open
<http://localhost:8080> (`admin` / `.secrets/jenkins_admin_password`).

## Commands

```text
make help       List of commands
make secrets    Prepare secrets (random locally, from pass on the server)
make up         Start services according to COMPOSE_PROFILES
make down       Stop services (data is kept)
make restart    Restart services, e.g. after a password change in pass
make ps         Service status
make logs       Logs, e.g. make logs s=jenkins
make check      Validate compose for all profiles and the Prometheus config
make images     Build service images from main, e.g. make images test IMAGE_TAG=local
make test       Smoke tests in a separate copy of the network (results in reports/)
make test-down  Remove the test copy of the network
```

Passwords never go into git or `.env`, and Jenkins is configured only through
`jenkins/casc/` (changes in the UI are lost on restart).
