# Fast DataWave integration testing

This opt-in workflow loads locally built DataWave ingest and web artifacts into
an existing local Kubernetes stack. It does not build, load, or publish a
container image. It can also render and reload chart-managed web and ingest
configuration through a separate writable layer. The normal charts and
image-based deployment remain the default.

The intended edit/build/reload loop is under five minutes after Maven
dependencies and the local build cache are warm. A first full build can take
longer because it must populate the Maven repository and cache.

## Why an artifact overlay

Host-path JAR mounts look simple, but Minikube exposes host files differently
for Docker, Podman, VM, and remote drivers. They also couple Helm values to one
developer's checkout path. Mounting individual `target` directories can leave a
process with a mixture of old and new transitive dependencies.

When explicitly enabled, these charts instead create a pod-local `emptyDir`,
initialize it from the normal image, and mount it over the application's
artifact directory. The helper script then transfers a complete local artifact
set with `kubectl`:

- Web: atomically stages the assembled EAR, restarts only the container in the
  same pod, and waits for the `.deployed` marker and health endpoint.
- Ingest: stops the ingest processes, replaces the assembled library trees,
  refreshes the Accumulo VFS classpath and MapReduce job cache in HDFS, and
  restarts ingest.

This makes the image the reproducible baseline while keeping the fast path
independent of the Minikube driver and host filesystem layout.

## One-time setup

Prerequisites are the same working DataWave Maven setup used for a normal local
build, including JDK 11, plus `kubectl`, `helm`, `yq`, and a running stack. The
helper fails early if Maven is using another JDK; set `JAVA_HOME` to JDK 11 in
that case. By default, the chart repository and DataWave repository are
expected to be siblings.

Create a combined values file:

```bash
cd datawave-helm-charts
yq ea '. as $item ireduce ({}; . * $item)' \
  datawave-stack/values.yaml \
  datawave-stack/values-fast-development.yaml \
  > /tmp/datawave-fast-development.yaml
```

Deploy with `datawave-driver.sh` and enter
`/tmp/datawave-fast-development.yaml` when prompted for the values file. The
driver uses local charts by default and no longer prompts for chart mode. For
an existing release, use the same combined values file in its normal
local-chart upgrade process.

Confirm that both workloads have the overlay:

```bash
./development/fast-datawave.sh status
```

Use `-n NAME` if the release is not in the `default` namespace, and `--context
NAME` when the desired cluster is not the current context.

## Daily workflow

To demonstrate the entire browser-visible loop, run:

```bash
./development/demo-fast-web-iteration.sh
```

The guided demo opens with the application URL, changes the DataWave root web
page, builds and hot-deploys the result, and tells the user when to refresh.
It preserves the original source beside the page until
`./development/demo-fast-web-iteration.sh reset` is run.

To demonstrate an ingest Java edit, focused JAR build, runtime reload, and
verification of the changed class in the running pod, run:

```bash
./development/demo-fast-ingest-iteration.sh
```

The ingest demo targets `warehouse/ingest-json`, refreshes the Hadoop job cache,
and confirms that the timestamped class marker in the deployed JAR exactly
matches the source change. Restore its source backup with
`./development/demo-fast-ingest-iteration.sh reset`.

The first focused ingest build may spend about a minute installing its reactor
dependencies, including test-classifier artifacts required by DataWave's Maven
model. Later edits package only `ingest-json`; the helper disables Maven's
reactor-wide build-cache checksum calculation for that single-module command.

For `web-services/web-root`, the helper builds only that WAR and inserts it into
a copy of the EAR already running in the pod. This avoids rebuilding every EAR
dependency and keeps the unchanged libraries aligned with the baseline image.
The helper deliberately restarts the web container after staging the EAR. A
WildFly hot deployment briefly retains both 300 MB applications and can exhaust
the development container's heap. The artifact overlay is pod-local and
survives a container restart, so the fresh JVM loads the local EAR without a
Docker build, image pull, Helm release, or replacement pod.

For a web change:

```bash
./development/fast-datawave.sh web
```

For an ingest change:

```bash
./development/fast-datawave.sh ingest
```

For an `ingest-json` change, select the module to use the focused JAR path and
avoid assembling the full ingest distribution:

```bash
./development/fast-datawave.sh \
  --module warehouse/ingest-json \
  ingest
```

For the shortest incremental build, name the Maven module containing the
change. The script installs that module and its prerequisites, then assembles
only the deployable application:

```bash
./development/fast-datawave.sh \
  --module warehouse/ingest-json \
  ingest
```

Artifact transfer and reload can be repeated without rebuilding:

```bash
./development/fast-datawave.sh \
  --module web-services/web-root \
  --skip-build \
  web
```

`DATAWAVE_SOURCE=/path/to/datawave` changes the source checkout. Set
`MAVEN_COMMAND` if Maven is installed under a nonstandard command name.

## Fast configuration reloads

`values-fast-development.yaml` enables writable runtime copies of the
chart-managed configuration. The chart ConfigMaps remain the source used to
render the files; the writable copies avoid modifying Kubernetes' read-only
`subPath` mounts.

After editing local web chart values or `datawaveRuntimeConfig.additions`,
render and reload `runtime-config.cli` with:

```bash
./development/fast-datawave.sh \
  --namespace datawave-fast-dev \
  web-config
```

After editing local ingest chart values under `config`, reload the general,
datatype, flag-maker, ingest, and ingest-environment configuration with:

```bash
./development/fast-datawave.sh \
  --namespace datawave-fast-dev \
  ingest-config
```

Use `config` to perform both reloads. An additional root-stack values file can
be tested without changing chart defaults:

```bash
./development/fast-datawave.sh \
  --namespace datawave-fast-dev \
  --values /path/to/change.yaml \
  config
```

The helper starts with the Helm release's explicitly supplied values, merges
each `--values` file in command-line order, and renders the local child chart.
It applies only the relevant ConfigMaps. Web restarts in the same pod. Ingest
processes stop, the exact ConfigMap data is copied into the writable overlay,
the Hadoop job cache is refreshed, and ingest restarts. Every copied file is
checksum-verified before success is reported.

This path covers configuration produced by the web and ingest child charts. It
does not reload Secrets, certificates, Hadoop/Accumulo ConfigMaps, pod
environment variables, image entrypoint files, or changes to volume/layout
definitions; those still use the normal Helm deployment workflow.

These fast ConfigMap applications intentionally do not create a Helm revision.
A later Helm upgrade reconciles them from its values. Keep repeatable changes
in chart defaults or a checked-in values file and pass that same file to the
normal deployment workflow.

## Behavior and recovery

The overlay is intentionally ephemeral. A container restart in the same pod
retains it, while a replacement pod is initialized from the configured image
again. Run the helper after a pod replacement to reload local code.

To return to an image-only deployment, remove
`values-fast-development.yaml` from the values merge and run the normal Helm
upgrade. No image, registry, or DataWave source changes need to be reverted.

Keep the image and source checkout on compatible DataWave versions. The ingest
workflow replaces the complete assembled library trees to prevent duplicate
DataWave versions, but it cannot make an older operating-system/Hadoop/WildFly
image compatible with source that requires a different runtime.

The first phase supports Java artifact and chart-managed configuration changes
in monolith web and ingest. Changes to image packages, operating-system
libraries, or configuration layout still require the existing image build and
deployment workflow. Microservice reloads can use the same pattern later.

## Ingest-query-audit smoke test

The standalone smoke test creates a unique `myjson` event, places it in the
live HDFS ingest directory, waits until an `EventQuery` returns the exact
marker, submits an audit for that query through DataWave, and scans
`QueryAuditTable` for the same marker:

```bash
./development/smoke-test.sh --namespace datawave-fast-dev
```

The required audit and compatible local Hadoop runtime changes are opt-in.
Install a fresh local chart with both the normal values and
`datawave-stack/values-smoke-testing.yaml`. For a new driver deployment, this
is automated with the driver's default local chart mode:

```bash
RUN_DATAWAVE_SMOKE_TEST=true ./datawave-driver.sh
```

To deploy the published chart instead, explicitly opt into remote chart mode:

```bash
DATAWAVE_CHART_MODE=remote ./datawave-driver.sh
```

With `RUN_DATAWAVE_SMOKE_TEST` unset, the smoke-specific values are not applied
and every existing chart default remains unchanged. The standalone script can
be rerun without Helm and returns a nonzero status on an ingest, query, audit
API, or audit-table failure. Use `--timeout`, `--user-cert`, and `--user-key`
for common overrides; its help lists the complete `DATAWAVE_*` and `SMOKE_*`
override surface.

The smoke values run the local Hadoop components on the chart's 3.3.6 image.
That is binary-compatible with the Hadoop 3.3.x clients mounted by the current
DataWave ingest image and prevents the YARN application-master
`NoSuchMethodError` produced by mixing those clients with Hadoop 3.4.1. This
runtime override is intentionally confined to smoke testing.

The same profile overrides the `myjson` default marking to `PUBLIC` for only
the synthetic smoke event. Normal datatype markings and non-smoke chart values
remain unchanged.

It also enables protobuf's documented legacy-gencode compatibility switch in
the local Accumulo JVM. DataWave's current UID protobuf classes predate the
protobuf version in the Accumulo 2.1.4 image; without this smoke-only switch,
index scans reject those classes before a query can return.

Apply the smoke values when creating the local stack. An HDFS volume already
written by Hadoop 3.4 cannot be downgraded in place; purge that disposable
Minikube deployment before recreating it with the smoke profile. This does not
affect a stack that was initially created with the smoke profile.

## Replacing server and user certificates

Certificate material has two explicit roles:

- `certificates-secret` contains `keystore.p12`, `truststore.jks`, and their
  passwords. Every TLS-enabled DataWave service mounts this server secret.
- `datawave-user-certificates` contains the PEM certificate and private key
  used by the smoke-test client. It is not mounted into server pods.

Update both identities throughout an existing namespace with one command:

```bash
./development/apply-certificates.sh \
  --namespace datawave-fast-dev \
  --server-keystore /path/to/server-keystore.p12 \
  --server-truststore /path/to/server-truststore.jks \
  --keystore-password secret \
  --truststore-password secret \
  --user-cert /path/to/user.crt.pem \
  --user-key /path/to/user.key.pem
```

The command applies both secrets, discovers all Deployments, StatefulSets, and
DaemonSets that mount the server secret, restarts those workloads, and waits
for their rollouts. Keep the passwords aligned with the Helm configuration;
the optional `datawave-stack/values-certificates-example.yaml` centralizes the
monolith and microservice password settings in one root-stack values file. Use
`--no-restart` when Helm will perform the rollout. The driver calls the same
script during setup, so paths can also be supplied noninteractively with
`DATAWAVE_SERVER_KEYSTORE`, `DATAWAVE_SERVER_TRUSTSTORE`,
`DATAWAVE_KEYSTORE_PASSWORD`, `DATAWAVE_TRUSTSTORE_PASSWORD`,
`DATAWAVE_USER_CERT`, and `DATAWAVE_USER_KEY`.

The default smoke client certificate represents DataWave's server/proxy
identity and supplies the configured test user through the proxied-entity
headers. For a direct end-user certificate, set the user certificate/key and
clear `SMOKE_PROXY_SUBJECT` only when that certificate's subject and issuer are
configured in `configuration/configMapFiles/authorization.yml`.
