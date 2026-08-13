# Fast DataWave integration testing

This opt-in workflow loads locally built DataWave ingest and web artifacts into
an existing local Kubernetes stack. It does not build, load, or publish a
container image. The normal charts and image-based deployment remain the
default.

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

Deploy with `datawave-driver.sh`, select `local` chart mode, and enter
`/tmp/datawave-fast-development.yaml` when prompted for the values file. For an
existing release, use the same combined values file in its normal local-chart
upgrade process.

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

The first phase supports Java artifact changes in monolith web and ingest.
Changes to image packages, operating-system libraries, WildFly configuration,
or ingest shell/configuration layout still require the existing image build and
deployment workflow. Microservice artifact reloads can use the same pattern in
a later phase.
