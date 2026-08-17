# Python API on Amazon EKS

A production platform for Python services on managed Kubernetes. You get the
cluster, the network, the container registry, the database, the delivery pipeline
and the security gates as one working system in your own AWS account — and you
write the application code.

## What problem this solves

Getting one Python container onto EKS is a weekend. Getting it there *safely*,
repeatably, and in a way a second engineer can operate is several weeks: node
groups and IAM roles, subnet tagging so the load balancer can be placed, secret
encryption, probes that actually gate traffic, migrations that run before the new
pods serve, a pipeline that refuses to ship vulnerable images, and a teardown that
does not leave orphaned load balancers holding your VPC hostage.

That work is done here, and it has been through the same validators the platform
runs against everything it builds.

## Who it is for

- Teams putting an internal or public Python API into production on Kubernetes.
- Data and machine-learning services that need to scale horizontally and survive
  an availability-zone loss.
- Services outgrowing single-VM hosting that want CI/CD and security gates from
  day one rather than bolted on later.

## What you inherit

**Platform**

- EKS control plane with API, audit, authenticator, controller-manager and
  scheduler logs streaming to CloudWatch.
- Managed node group across two availability zones, drained one node at a time
  during upgrades.
- VPC with public subnets for the nodes and load balancer, private subnets for the
  database, and no NAT gateway to pay for.
- Kubernetes Secrets encrypted with a KMS key created for this project, with
  rotation enabled.
- ECR repository with scan-on-push and a lifecycle policy that keeps the last
  twenty images.

**Delivery**

- Thirteen-stage GitHub Actions pipeline rendered from `.udap/pipeline.yaml`.
- Rolling updates with `maxUnavailable: 0`, readiness-gated traffic, and uvicorn's
  graceful shutdown draining in-flight requests so a release never drops one.
- Horizontal Pod Autoscaler on CPU, with the metrics server installed by the
  deploy.
- PodDisruptionBudget so node drains cannot take the last pod.
- Teardown that deletes the Kubernetes load balancer before running
  `terraform destroy`, which is the difference between a clean destroy and a VPC
  that refuses to delete.

**Security and compliance, enforced in the pipeline**

| Gate | Tool | Blocks the deploy when |
| --- | --- | --- |
| Coding standards | Ruff (`E`,`F`,`I`,`B`,`UP`,`S`,`C4`,`SIM`,`RET`) | any lint error |
| Formatting | Ruff format | never — advisory, prints the fix |
| Unit tests | pytest | any test fails |
| SAST | Semgrep (`p/default`, `p/owasp-top-ten`, `p/python`) | an ERROR-severity finding |
| Secret scanning | Gitleaks | a credential is committed |
| Licence compliance | pip-licenses | a runtime dependency falls outside the reviewed allowlist |
| SBOM | CycloneDX | generation fails |
| IaC security | Trivy config, Checkov | Trivy reports a CRITICAL misconfiguration |
| Image security | Trivy | a fixable HIGH or CRITICAL vulnerability in the image |

There is no separate Bandit stage on purpose: Ruff's `S` rules *are* Bandit's
checks, and they run in the blocking coding-standards gate.

Every gate also publishes an artefact — SARIF reports, a licence CSV, and two
CycloneDX SBOMs (dependency tree and built image) — attached to the workflow run
for audit.

The scanners are wired to **report first, then fail**: each writes its report,
uploads it, and only then does a separate step decide whether to block, printing
every finding with its file, line and rule id. A gate that dies before it can tell
you what it found is worse than no gate at all.

### The licence allowlist includes LGPL-3.0, deliberately

`psycopg`, the Postgres driver, is LGPL-3.0-only. The LGPL's copyleft attaches to
modifications of the library itself, not to an application that merely uses an
unmodified copy, so it is on the allowlist with this note attached. Everything
else in the runtime tree is permissive. Widen the list only the same way — with a
reason written down.

The gate installs the runtime dependencies into a throwaway virtualenv and points
`pip-licenses` at that, so the tooling's own dependencies never reach the
allowlist. Without that separation the scan fails over copyleft packages that
never ship.

## The landing page

`/` serves the UDAP welcome page — the same branded page every project the
platform builds shows on its first deploy. It is a real page a person can open,
which the `verify` stage depends on, and it carries the project name, cloud,
target, region and the deployed release. The status line and the release tile are
read live from `/health`, so the page cannot claim the service is online while it
is not.

Replace it with your own UI when you have one: it is a single static file, named
in the page's own footer. Note that on the scaffold path the platform treats
removing this branding as a plan-gated feature; a blueprint has no way to enforce
that, so the decision sits with whoever edits the file.

## Database migrations

The blueprint owns **when** migrations run. Your project owns **how**.

What the blueprint provides, and expects to keep:

- The `db-migrate` Kubernetes Job, running on the image just built, in the
  `configure` stage, **before** the new Deployment is applied — so a failed
  migration stops the deploy instead of half-releasing it. The step always prints
  the migration log, on success and on failure.
- `bin/migrate` as the seam. The Job runs `sh bin/migrate` and nothing else, so
  changing the tool never means editing a manifest or the pipeline.
- Skipping cleanly when there is no database: with `database=none` there is no
  `DATABASE_URL`, the step says so, and the deploy continues.

What is yours:

- **The tool.** Replace the single `exec` line in `bin/migrate` with
  `alembic upgrade head`, `yoyo apply --batch`, `python -m django migrate` —
  whatever you use.
- **The schema.** The default runner (`app/migrate.py`) applies numbered `.sql`
  files from `db/migrations/`, once each, in filename order, each in its own
  transaction, tracked in a `schema_migrations` table under a Postgres advisory
  lock so concurrent deploys cannot race. Because runs are tracked a migration can
  be a plain `ALTER TABLE`. If you bring your own tool, `app/migrate.py` and
  `db/migrations/` are yours to delete.

One rule the rolling update imposes: releases run old and new pods at the same
time (`maxUnavailable: 0`), so **every migration must be backwards compatible with
the currently running code**. Expand, then contract: add a nullable column and
deploy code that writes it; drop the old column in a later release once nothing
reads it. A migration that renames or drops something the running pods still use
takes the service down mid-rollout, and no gate can catch that for you.

## The database choice

The `database` module decides what gets built:

- **`postgres`** (default) — RDS Postgres, encrypted at rest, in private subnets,
  reachable only from the cluster's security group, with seven days of backups.
  The connection string is generated by Terraform and delivered to the pods as a
  Kubernetes Secret; it is never written to a file or a job output. In transit the
  connection is TLS-**verified**: `PGSSLMODE=verify-full` and `PGSSLROOTCERT`
  point libpq at the Amazon RDS CA bundle baked into the image, because RDS uses a
  private CA and the alternative — accepting any certificate — is encryption
  without authentication.
- **`none`** — no database. The service runs statelessly and its readiness probe
  reports `not configured` instead of checking a database. Nothing else changes.

## What you are expected to write

The blueprint ships a working FastAPI service with `/health`, `/ready`,
`/api/info`, interactive docs at `/api/docs` and the UDAP welcome page at `/`. Those
exist because the pipeline verifies them. Everything else is yours:

- Routes and business logic under `app/`.
- Database schema in `db/migrations/`, or your own migration tool behind
  `bin/migrate`.
- Application-specific environment variables and Kubernetes configuration.

## What not to rewrite

These files are the blueprint. Each one encodes a deploy failure that has already
been diagnosed and fixed, so a fresh version of it tends to reintroduce the
original problem:

| File | Rewriting it costs you |
| --- | --- |
| `Dockerfile` | `apt-get upgrade` and the pip removal in the runtime stage — without them the image scan blocks on CVEs in the base image and in pip's vendored dependencies |
| `.dockerignore` | the exclusion list the image relies on, now that the Dockerfile copies the whole tree |
| `infra/*.tf` | security groups with no `egress 0.0.0.0/0` rule, plain-text AWS descriptions (an apostrophe in one is rejected at apply time and invisible to `terraform validate`), the provider pin, and the empty S3 backend the platform's state contract requires |
| `.udap/pipeline.yaml` | the apt Trivy install, the report-then-fail scanner wiring, the isolated licence and SBOM environments, and the poll-based waits that print the real error |
| `.trivyignore` | every accepted finding and the reason it is accepted |
| `app/db.py` | TLS verification through libpq against the RDS CA bundle |
| `k8s/db-migrate-job.yaml` and the migration step | migrations running before the Deployment, and a step that reports the real failure instead of a wait timeout |

Extending them is fine and expected. Replacing them wholesale is what turns a
verified blueprint back into a first draft.

## Cost

Roughly £135–£215 a month for the defaults: the EKS control plane is about £58
regardless of load, two `t3.medium` nodes, a `db.t4g.micro` Postgres instance with
20 GB of gp3 storage, and one network load balancer. Choosing `database=none`
removes about £18. Data transfer and CloudWatch retention beyond the free tier are
extra. Scaling the node count is the main lever.

## Deliberate trade-offs

These were decisions, not oversights, and each is a one-line change if your
situation differs:

- **Nodes run in public subnets.** No NAT gateway to pay for or fail; inbound
  access is still restricted to the cluster security group, and the load balancer
  is the only intended entry point. Add private subnets and a NAT gateway when
  egress must be filtered.
- **The Kubernetes API endpoint is public.** CI runners have no fixed egress
  address, so an allowlist would break every deploy. Access is IAM-authenticated
  and fully audit-logged. Recorded in `.trivyignore` with its reasoning.
- **A `LoadBalancer` Service, not an Ingress.** EKS provisions the network load
  balancer through the cloud controller it already runs, so there is no ingress
  controller to install, upgrade or debug. Move to the AWS Load Balancer
  Controller when you need TLS termination, host routing or WAF.
- **The ECR repository allows tag overwrites.** A retried deploy pushes the same
  commit-sha tag, and an immutable repository would reject it, turning every retry
  into a failed build.
- **Dependencies use compatible-release pins (`~=`), not a lockfile.** A rebuild
  picks up patch releases, which is what keeps the image scan passing months from
  now. Run `pip-compile` into a `requirements.lock` and install from that if
  byte-identical rebuilds matter more to you.
- **The AWS provider is pinned below 5.83.0.** From that release the provider
  treats `aws_db_instance.password` as write-only, which breaks reading the
  generated password back out for the application secret.
- **Trivy blocks on CRITICAL for infrastructure, HIGH for images.** A newly
  published infrastructure rule should not stop a deploy before a human has looked
  at it; a fixable HIGH in a shipping container should.
- **Trivy is installed from Aqua's apt repository, never `curl … | sh`.** Old
  Trivy releases get pruned from GitHub, so a pinned installer stops working after
  a few months — and piping a remote script into a shell is itself an
  ERROR-severity SAST finding, which means the security gate would block on its
  own installer.

## Deploying

Provide nothing. The platform supplies `PROJECT_NAME`, `TF_STATE_BUCKET` and the
AWS credentials as pipeline secrets; the database password is generated by
Terraform and never leaves the state file and the Kubernetes Secret. First deploy
takes 20–28 minutes, most of it the EKS control plane. Redeploys are 6–10 minutes.
