# python-eks1

A Python API running on Amazon EKS, provisioned by Terraform and shipped by a
security-gated GitHub Actions pipeline.

> Built from the UDAP `python-eks` production blueprint. The long-form description
> of the platform lives in [.udap/docs/README.md](.udap/docs/README.md).

## Layout

| Path | What it holds |
| --- | --- |
| `app/` | The FastAPI service: `main.py` routes, `db.py` optional Postgres, `migrate.py` migration runner |
| `static/` | The UDAP welcome page served at `/` |
| `db/migrations/` | Numbered SQL migrations, applied once each before every release |
| `bin/migrate` | The migration entrypoint the deploy calls — point it at your tool |
| `tests/` | pytest suite |
| `infra/` | All Terraform: VPC, EKS, node group, ECR, KMS, RDS |
| `k8s/` | Deployment, Service, HPA, PodDisruptionBudget, ServiceAccount, migration Job |
| `.udap/architecture.d2` | The architecture diagram, in the UDAP D2 profile |
| `.udap/pipeline.yaml` | The pipeline spec — CI workflow files are rendered from it |
| `modules/db-none/` | Overlay applied when the database module choice is `none` |

## Endpoints

| Route | Purpose |
| --- | --- |
| `GET /` | UDAP welcome page, with the status line read live from `/health` |
| `GET /health` | Liveness. Never touches the database, so a database outage cannot restart healthy pods |
| `GET /ready` | Readiness. Checks Postgres when one is configured |
| `GET /api/info` | Runtime and build facts |
| `GET /api/docs` | Interactive OpenAPI documentation |
| `GET /api/echo` | Sample route to replace with your own |

## Running it locally

```bash
python -m venv .venv && . .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --port 8000        # http://localhost:8000
```

With a database:

```bash
# A local Postgres with no TLS: opt out explicitly.
PGSSLMODE=disable \
DATABASE_URL='postgres://user:password@localhost:5432/appdb' \
  uvicorn app.main:app --port 8000
```

Without `DATABASE_URL` the service starts anyway and reports
`database: not configured` — the same behaviour as a deploy with the `none`
database module.

In the cluster no flag is needed: the image carries the Amazon RDS CA bundle at
`certs/rds-global-bundle.pem`, and the manifests set `PGSSLMODE=verify-full` and
`PGSSLROOTCERT` so the connection is verified rather than merely encrypted.
Verification is never disabled silently — `PGSSLMODE=disable` is the only way to
turn TLS off, and it is visible in the manifest when you do.

The gates the pipeline runs, in local form:

```bash
ruff check .              # blocking in CI
ruff format .             # writes the fixes (advisory in CI)
python -m pytest          # unit tests
docker build -t app .     # the image the pipeline builds
```

**If you add or change a dependency**, edit `requirements.txt` (runtime) or
`requirements-dev.txt` (tooling). The licence gate and the SBOM read
`requirements.txt` only, so anything that ships belongs there.

## Database migrations

The deploy runs `sh bin/migrate` as a Kubernetes Job before the new Deployment is
applied. A failure stops the deploy, with the migration log printed.

`bin/migrate` is the seam — change what it runs and nothing else needs editing:

```sh
exec python -m app.migrate     # the default: plain SQL files
exec alembic upgrade head
exec yoyo apply --batch
```

The default runner applies numbered `.sql` files from `db/migrations/` exactly once
each, in filename order, inside a transaction, recorded in a `schema_migrations`
table:

```bash
db/migrations/001_init.sql        # shipped as an example
db/migrations/002_add_orders.sql  # yours
```

Locally:

```bash
PGSSLMODE=disable \
DATABASE_URL='postgres://user:password@localhost:5432/appdb' sh bin/migrate
```

Because a rolling update runs old and new pods together, **a migration must work
with the code already running**. Add a nullable column and ship the code that
writes it, then drop the old column in a later release.

## How a deploy runs

Seven gates run in parallel — coding standards, unit tests, Semgrep SAST, Gitleaks
secret scanning, licence compliance, SBOM generation and Terraform security
scanning. All of them must pass before any AWS resource is touched. Then Terraform
applies `infra/`, the image is built, pushed to ECR and scanned by Trivy, schema
migrations run as a Job, the manifests in `k8s/` are applied, the rollout is
watched, and the load balancer is health-checked before the deploy is called green.

The pipeline is defined once in `.udap/pipeline.yaml`. Change it there and let the
platform re-render the workflows — never edit `.github/workflows/*` by hand,
because the next render will overwrite it.

## Two kinds of placeholder

| Form | Substituted | By |
| --- | --- | --- |
| `__UDAP_*__` | Once, when the project was created from the blueprint | The blueprint materialiser |
| `%%IMAGE%%`, `%%IMAGE_TAG%%`, `%%NAMESPACE%%` | On every deploy | The configure stage, with `sed` |

Both are already resolved in a live project; the second set stays in the committed
manifests on purpose, because the image tag changes every deploy.

## Configuration

Nothing needs to be set by hand. The platform provides these as repository secrets
at deploy time:

| Secret | Used for |
| --- | --- |
| `PROJECT_NAME` | Resource prefix, Kubernetes namespace, ECR repository name, Terraform state key |
| `TF_STATE_BUCKET` | Terraform remote state bucket |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Provisioning and cluster access |

The Postgres password is generated by Terraform, stays in the state file, and
reaches the pods only as the `app-database` Kubernetes Secret.

## Finding the application URL

The deploy prints it three times: in the **Wait for the load balancer** step, in
the **Health check** step (`Service is healthy at …`), and in the workflow run's
**Summary** panel as a clickable link. The platform also scrapes it from the log to
enable the "open the app" link on the project.

Any time afterwards:

```bash
aws eks update-kubeconfig --name "$PROJECT_NAME-eks" --region "$AWS_REGION"
kubectl get svc api -n "$PROJECT_NAME"      # EXTERNAL-IP column
```

If the link does not open immediately after a first deploy, that is DNS: a newly
created load balancer resolves from inside AWS before it resolves everywhere else,
which is why the health check can pass while a browser still cannot find it. Give
it a few minutes. It stops resolving permanently once the project is destroyed —
the load balancer goes with it.

## Operating it

```bash
aws eks update-kubeconfig --name "$PROJECT_NAME-eks" --region "$AWS_REGION"

kubectl get pods -n "$PROJECT_NAME"
kubectl logs -n "$PROJECT_NAME" -l app.kubernetes.io/name=api --tail=100
kubectl rollout undo deployment/api -n "$PROJECT_NAME"      # roll back one release
kubectl get svc api -n "$PROJECT_NAME"                      # public hostname
```

## Accepted security findings

`.trivyignore` records every infrastructure finding this project accepts, each with
the reason. A finding that is not listed there is a real one — fix it rather than
adding a line. The reasoning behind each entry is in
[.udap/docs/README.md](.udap/docs/README.md).
