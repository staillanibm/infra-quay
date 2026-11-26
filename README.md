# Quay on OpenShift (Red Hat Quay Operator)

Fully managed Quay registry deployed via the Red Hat Quay Operator on OpenShift Container Platform.

---

## Architecture

```
quay namespace
├── quay-operator            OLM-managed operator — reconciles QuayRegistry CRs
├── quay-quay-app-xxx        Quay application pods (replicated)
├── quay-clair-app-xxx       Clair vulnerability scanner
├── quay-quay-database-xxx   PostgreSQL (Quay metadata)
├── quay-clair-postgres-xxx  PostgreSQL (Clair vulnerability DB)
├── quay-quay-redis-xxx      Redis cache
└── quay-quay-mirror-xxx     Repository mirroring workers
```

Object storage is provided by OpenShift Data Foundation (NooBaa) via an
`ObjectBucketClaim` that the operator creates automatically.

### Key design decisions

| Choice | Rationale |
|---|---|
| **OwnNamespace install mode** | Operator scoped to `quay` only — no cluster-wide watch |
| **All components managed** | No external Postgres / Redis / S3 needed; operator owns lifecycle |
| **OCS NooBaa object storage** | Native ODF integration; no separate S3 credentials to manage |
| **restricted-v2 SCC** | No privileged containers, no root — operator handles service account setup |
| **stable-3.17 channel** | Latest stable channel; `Automatic` approval upgrades patch releases |
| **`configBundleSecret`** | Declarative config overrides merged by the operator — never patch operator-managed secrets directly |
| **monitoring: false** | Monitoring component requires AllNamespaces install mode; disabled in OwnNamespace |

### Endpoints

After deployment the registry is reachable at the route created by the operator:

```bash
oc -n quay get quayregistry quay -o jsonpath='{.status.registryEndpoint}'
```

---

## Prerequisites

- `oc` configured against the target OpenShift cluster (`oc whoami` must succeed)
- `make`
- OpenShift Data Foundation (ODF/OCS) installed and healthy — the operator
  needs NooBaa to provision the object bucket
- The `quay-operator` package must be available in the `redhat-operators`
  catalog source (standard on any connected OCP cluster)

---

## Makefile

All operations are available via `make`. Run `make help` for the full reference.

```
Cluster lifecycle:
  deploy       Install Quay operator + registry instance
  smoke-test   Push and pull a test image (requires QUAY_USER= QUAY_PASS=)
  teardown     Delete the registry, operator, and namespace
  status       Show current state of the registry

Variables:
  QUAY_USER    Robot account name  (org+robotname)
  QUAY_PASS    Robot account token
  QUAY_ORG     Organisation for the test image (default: smoketest)
```

---

## Installation

```bash
make deploy
```

The target performs the following steps:

1. Creates the `quay` namespace
2. Applies the `OperatorGroup` and `Subscription` — OLM installs the operator
3. Waits for the operator CSV to reach `Succeeded`
4. Applies the `quay-config-bundle` Secret and the `QuayRegistry` CR
5. Waits for the registry to reach `Available`

Expected duration: **5–10 minutes** depending on image pull speed.

### Verify the installation

```bash
make status
```

---

## First login

The operator does **not** generate a superuser automatically in 3.17.
The `quay-config-bundle` Secret in [`registry.yaml`](registry.yaml) declares
`quayadmin` as a superuser — the account must be created with that exact
username to receive admin privileges.

**From the UI (interactive):**

1. Open the registry URL in a browser
2. Click **Create Account** and register with username `quayadmin`
3. The account is immediately a superuser because it matches `SUPER_USERS` in
   the config bundle

**Non-interactively (CI / first-time bootstrap):**

```bash
QUAY_POD=$(oc -n quay get pod -l quay-component=quay-app -o jsonpath='{.items[0].metadata.name}')
DB_POD=$(oc -n quay get pod -l quay-component=postgres -o jsonpath='{.items[0].metadata.name}')

HASH=$(oc -n quay exec "${QUAY_POD}" -- python3 -c "
import bcrypt
print(bcrypt.hashpw(b'<your-password>', bcrypt.gensalt(12)).decode())
")

oc -n quay exec "${DB_POD}" -- psql -U quay-quay-database -d quay-quay-database -c "
INSERT INTO \"user\" (username, password_hash, email, verified, organization, robot,
  invoice_email, invalid_login_attempts, last_invalid_login, removed_tag_expiration_s,
  enabled, creation_date)
VALUES ('quayadmin', '${HASH}', 'admin@quay.local', true, false, false,
  false, 0, NOW(), 1209600, true, NOW())
ON CONFLICT (username) DO NOTHING;
"
```

> **Note:** `FEATURE_USER_CREATION: true` is set in the config bundle so the
> UI registration flow works out of the box.  Set it to `false` after creating
> the admin account if you want to disable self-registration.

---

## Configuration overrides

All Quay config overrides belong in [`registry.yaml`](registry.yaml) under the
`quay-config-bundle` Secret's `config.yaml` key. The operator merges this into
its own generated config on every reconciliation.

**Never patch operator-managed secrets directly** — the operator will overwrite
them on the next reconciliation loop.

---

## Testing

```bash
make smoke-test QUAY_USER=smoketest+robot QUAY_PASS=<robot-token>
```

Prerequisites (done once via the Quay UI):

1. Create organisation `smoketest`
2. Create a robot account in that org with **Write** permission on repository `smoke`
3. Copy the robot token

The job uses `skopeo` to copy `busybox:latest` into `smoketest/smoke:v1` and
inspect it back — no Docker daemon, no root, runs under restricted-v2.

---

## Adding a robot account

Robot accounts belong to the application that uses them.  Create them via the
Quay UI or API after deployment.  Grant the minimum permission needed:

- **Read** — image consumer (CI pull, runtime)
- **Write** — CI pipeline pushing to one repository
- **Admin** — only if the account must manage the repository itself

---

## Upgrade

> Always check the [Quay upgrade path documentation](https://docs.redhat.com/en/documentation/red_hat_quay)
> before jumping more than one minor version.

With `installPlanApproval: Automatic` the operator self-upgrades on patch
releases. For minor version upgrades, update the `channel` field in
[`operator.yaml`](operator.yaml) and re-apply:

```bash
# Edit operator.yaml: channel: stable-3.17 → stable-3.18
oc apply -f operator.yaml
```

---

## Known issues

### NooBaa endpoint OOMKilled on large image pushes

The `objectstorage` component is delegated to NooBaa/ODF (see [`registry.yaml`](registry.yaml)).
Every layer Quay uploads goes through the `noobaa-endpoint` pod in
`openshift-storage`, which buffers S3 multipart upload parts in memory. ODF's
default endpoint limit (2Gi) is too small for large image pushes — the pod
gets OOMKilled mid-transfer and the push fails.

Fix: raise the `noobaa-endpoint` resource limits via the `StorageCluster` CR
(this lives in `openshift-storage`, not in a Quay-operator-managed resource,
so it can't be set via `registry.yaml`):

```bash
make fix-noobaa
```

**Patch the `StorageCluster`, not the `NooBaa` CR directly.** On ODF external
mode the `NooBaa` CR (`openshift-storage/noobaa`) is owned by the
`StorageCluster` (`ocs-external-storagecluster`) — `ocs-operator` resyncs
`NooBaa.spec.endpoints` from `StorageCluster.spec.multiCloudGateway.endpoints`
on every reconcile (roughly every 10s) and silently reverts any direct edit
to the `NooBaa` CR within seconds, with no error surfaced. This bit us once:
`oc patch noobaa noobaa` reported success and the Deployment briefly showed
the new limits, but reverted back to the ODF default before the pod was even
ready.

This applies [`noobaa-endpoint-resources.yaml`](noobaa-endpoint-resources.yaml)
(`limits: 2 CPU / 8Gi`, `requests: 1 CPU / 4Gi`, up from the ODF default of
`999m` CPU / `2Gi` memory) to `StorageCluster.spec.multiCloudGateway.endpoints.resources`
and waits for the `noobaa-endpoint` deployment to roll — then re-checks the
live resources after a short delay to confirm they stuck. Requires
`cluster-admin`-level access to `openshift-storage` (separate from the `quay`
namespace this repo otherwise manages).

If pushes are still failing after this, check current usage before raising
the limits further:

```bash
oc -n openshift-storage adm top pod -l noobaa-s3=noobaa
```

### NooBaa PV-pool backing-store OOMKilled (or single point of failure) on large blob writes

The endpoint fix above is not the whole story: with the `objectstorage`
component backed by a NooBaa PV-pool (the default when no external S3 is
configured), the actual write path for a blob goes through the **backing
store agent pod(s)** (`noobaa-default-backing-store-noobaa-pod-*`), not just
the endpoint. This has two independent failure modes, both fixed by the same
target:

1. **OOM.** ODF sizes each backing-store pod at `400Mi` by default, and it
   gets OOMKilled mid-write on a large layer — independently of the endpoint
   fix. This does **not** surface as an OOM message; `podman`/`skopeo`
   reports it as a generic transport failure instead:

   ```
   time="..." level=fatal msg="writing blob: uploading layer chunked: blob upload invalid"
   Error: failed to upload ...: exit status 1
   ```

   Confirm before assuming it's something else (auth, network):

   ```bash
   oc -n openshift-storage get pod -l pool=noobaa-default-backing-store \
     -o jsonpath='{.items[*].status.containerStatuses[0].lastState}'
   # look for "reason": "OOMKilled"
   ```

2. **Single point of failure.** ODF defaults `spec.pvPool.numVolumes` to
   `1` — exactly one agent pod. That pod gets replaced periodically as part
   of its normal lifecycle (a *clean* restart, not a crash — no `OOMKilled`
   in its history, just a plain `Killing`/`Started` pair in `oc get events`).
   If a large, multi-minute push lands on top of one of these restarts, the
   in-flight multipart upload loses its connection and fails with the exact
   same `blob upload invalid` error, even though nothing actually crashed.
   We hit this ourselves: raising only the memory limit (`numVolumes` still
   `1`) fixed the OOM push failures, then a *different* large image still
   failed the same way, with a healthy pod and no OOM anywhere in the
   events — traced to a pod replacement 56 seconds before the failure.

Fix:

```bash
make fix-noobaa-backingstore
```

This applies [`noobaa-backingstore-resources.yaml`](noobaa-backingstore-resources.yaml)
(`limits: 1 CPU / 4Gi`, `requests: 200m CPU / 1Gi`, up from the ODF default of
`100m` CPU / `400Mi` memory, **and** `numVolumes: 2` for redundancy — while
one agent restarts, the other keeps serving in-flight requests) directly to
the `BackingStore` CR (`noobaa-default-backing-store`). `numVolumes: 2` needs
a second 50Gi PVC on `ocs-external-storagecluster-ceph-rbd`. Unlike the
endpoint, this CR is not resynced from `StorageCluster` on every reconcile,
so a direct patch sticks — still requires `cluster-admin`-level access to
`openshift-storage`.

Run **both** `make fix-noobaa` and `make fix-noobaa-backingstore` before
pushing large images; either one alone can still fail on the other
component.

---

## Uninstallation

```bash
make teardown
```

Deletes in order: QuayRegistry → operator (Subscription + OperatorGroup) → namespace.

> The operator does **not** delete the `ObjectBucketClaim` or its backing
> NooBaa bucket when the registry is removed.  Delete it manually to reclaim
> storage:
>
> ```bash
> oc -n quay delete objectbucketclaim --all
> ```
