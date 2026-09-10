# promovolve chart

A Helm chart for [Promovolve](https://github.com/promovolve/promovolve).

## Why this exists

Upstream ships a kustomize base under `k8s/`. The base is good and its comments
are the best documentation the project has — but it carries GKE-shaped
decisions in the manifests themselves:

```
Service type            LoadBalancer          Docker Desktop puts it on localhost
imagePullSecrets        regcred               the images are in private repos
db                      a bundled StatefulSet
db-secret               committed literals    POSTGRES_PASSWORD=promovolve
init-db.sql             ../docker/init-db.sql needs --load-restrictor
imagePullPolicy         Always                right for a mutable :dev tag
```

Deploying anywhere else means a new overlay per target, and `k8s-local/` is
what that looks like: three patches whose only job is to undo three decisions.
Its comments even record forgetting the third one and getting
`ImagePullBackOff` for it.

So the decisions are values here.

## What the chart derives rather than asks for

This is the part worth reading. Upstream's base repeatedly says "change these
together":

> If you change the member count, set this to the new majority ⌊total/2⌋+1.

An instruction that can be followed can be forgotten, and this one fails
quietly: set the bootstrap quorum below a majority and two pods that cannot see
each other each form a cluster of one. Both serve. Both accept writes. Nothing
reports a problem until the state has diverged.

So `PEKKO_BOOTSTRAP_REQUIRED_CONTACT_POINTS` is not a value. It is computed
from `api.replicas`.

| `api.replicas` | contact points |
|---|---|
| 1 | 1 |
| 2 | 2 |
| 3 | 2 |
| 5 | 3 |

The same applies to single-node mode. Upstream spreads it over five places —
replicas, the `-Dconfig.file` overlay, the bootstrap quorum, anti-affinity, and
the PodDisruptionBudget. Here:

```yaml
singleNode: true
```

## Deliberate departures from upstream

**`DATABASE_URL` moved from the ConfigMap to the Secret.** Upstream puts it in
`platform-config` with the password embedded. Read access to ConfigMaps is
granted far more freely than read access to Secrets.

**The chart creates no Secrets.** It reads the names of Secrets that already
exist. A chart that generated them would either repeat upstream's committed
literals or take passwords through `values.yaml` — which ends up in a Git
repository and in `helm get values`.

**`imagePullPolicy: IfNotPresent`, not `Always`.** `Always` is right for a
mutable `:dev` tag and wrong once a tag or a digest is pinned.

**Validation fails the render.** Missing `trackingBaseUrl`, `rpId`,
`rpOrigins`, `allowedOrigin` or `cdnBaseUrl` is an error rather than a default.
Promovolve itself refuses to boot without its object store and its LLM key for
the same reason: the alternative to a loud failure is not a working deployment,
it is one whose symptoms point somewhere else. A wrong `trackingBaseUrl` means
ads render and nothing is recorded.

## If this is ever offered upstream

Nothing here is tied to the cluster it was written for. Checked rather than
assumed: the chart contains no address, no StorageClass name, no `hostPath`, no
CNI or node-OS assumption. `api.persistence.storageClass` is empty, which means
"whatever this cluster's default is".

What would need changing, and what is worth arguing about:

**Fork identity.** `image.registry` / `image.repository` default to this fork's
GHCR namespace, and `Chart.yaml` names its maintainer. Both are values or
metadata; upstream would set its own.

**`postgresql.bundled` defaults to false.** Upstream's base bundles the
database, so `true` would be the smaller diff and the friendlier first
install. It is `false` because of how the two fail. Forget `postgresql.host`
with `bundled: false` and the render stops with a message naming the value;
forget `bundled: false` with a default of `true` and a second database comes
up, the application talks to it, and the symptom is that the data is missing.
The louder failure was preferred. This is a defensible default either way.

**`api.service.type` defaults to ClusterIP, not LoadBalancer.** Charts
conventionally do, and a LoadBalancer on a cluster with no controller stays
Pending with no other symptom. But it does change upstream's Docker Desktop
workflow, where LoadBalancer is what puts the port on localhost.

**Resource names ignore the release name.** `promovolve.fullname` returns the
chart name, so resources are `promovolve-api` and not `<release>-api`. That
keeps the names the base produces — useful when moving an existing deployment
across — at the cost of the Helm convention, and two releases in one namespace
would collide. Upstream may well prefer the convention.

**Rendering fails on missing configuration.** Some maintainers want
`helm install` with no values to produce something; this refuses. The argument
for refusing is in the section above.

**`config.trackingBaseUrl` must end in `/v1`.** The browser-facing routes live
under `pathPrefix("v1")` and upstream's own value includes it, so the check
should hold — but it is a constraint the chart invents, and it would be wrong
the day the API is mounted somewhere else.

**Migration note.** `DATABASE_URL` moves from `platform-config` to the platform
Secret, so anyone coming from the base has to add it there. A deployment that
misses this starts and then cannot reach the database.

**Demo values carried over.** `floorObservationIntervalSeconds: 60` and
`gemini.tokensPerMinute: 1000` are upstream's base values, and upstream's own
comments say production wants 900 (with tick counts recalibrated) and that 1000
targets a paid key. Keeping them matches the base rather than improving on it.

**Chart appVersion and image tags have to move together.** With no
`image.*.tag` set, the tag is `.Chart.AppVersion`. Whatever publishes the
images must bump it, or the default points at a tag that was never pushed.

## Not ported

**The singleton tier.** Upstream keeps a dedicated `[singleton, entity]` pod at
`replicas: 0` for real multi-node infrastructure. There is deliberately no
`singleton.enabled` value that quietly does nothing.

**Ingress and Certificate.** The deployment this chart is aimed at reaches the
cluster through a tunnel, so there is no ingress controller and no
cert-manager. Add them in a wrapper chart or alongside.

## The files/ directory

Helm cannot read outside a chart directory, so `files/` holds copies of things
whose originals live elsewhere in this repository. Upstream avoided copies by
having kustomize reference the originals in place — which is why its base needs
`--load-restrictor LoadRestrictionsNone`.

Copies drift, so `charts/sync-files.sh` plus a CI step makes drift loud:

```sh
./charts/sync-files.sh
git diff --exit-code charts/promovolve/files/
```

## Install

```sh
helm install promovolve oci://ghcr.io/t0m0h1de/charts/promovolve \
  -n promovolve --create-namespace \
  -f my-values.yaml
```

Minimum values:

```yaml
config:
  cdnBaseUrl: https://cdn.example.org
  trackingBaseUrl: https://ads.example.org/v1   # the /v1 is required
  bannerScriptUrl: https://cdn.example.org/js/expandable-magazine-banner.<hash>.js
  allowedOrigin: https://promovolve.example.org
  rpId: promovolve.example.org                  # permanent; passkeys bind to it
  rpOrigins: https://promovolve.example.org

postgresql:
  host: 10.0.0.10
```

To try it on kind with nothing prepared but the two Secrets:

```yaml
singleNode: true
postgresql:
  bundled: true
api:
  persistence:
    enabled: false
```
