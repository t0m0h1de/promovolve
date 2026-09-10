{{/*
Names and labels.
*/}}
{{- define "promovolve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "promovolve.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "promovolve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "promovolve.labels" -}}
helm.sh/chart: {{ include "promovolve.chart" . }}
app.kubernetes.io/name: {{ include "promovolve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.

app and tier rather than the app.kubernetes.io/ set, and deliberately. The
Pekko pods discover each other through the Kubernetes API by label selector,
and `tier: app` is what separates the pods that serve HTTP from the ones that
do not. Changing these is not cosmetic -- it changes who joins the cluster.
*/}}
{{- define "promovolve.api.selectorLabels" -}}
app: {{ include "promovolve.fullname" . }}-api
{{- end -}}

{{- define "promovolve.platform.selectorLabels" -}}
app: {{ include "promovolve.fullname" . }}-platform
{{- end -}}

{{/*
Images.

A digest wins over a tag. Deploying by digest is the only way to know what is
running.
*/}}
{{- define "promovolve.api.image" -}}
{{- $img := .Values.image.api -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository $img.name -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $base $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $base (default .Chart.AppVersion $img.tag) -}}
{{- end -}}
{{- end -}}

{{- define "promovolve.platform.image" -}}
{{- $img := .Values.image.platform -}}
{{- $base := printf "%s/%s/%s" .Values.image.registry .Values.image.repository $img.name -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $base $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $base (default .Chart.AppVersion $img.tag) -}}
{{- end -}}
{{- end -}}

{{/*
Effective api replica count.

singleNode wins. The whole point of that value is that the pieces cannot come
apart, so it is read here rather than trusted to every call site.
*/}}
{{- define "promovolve.api.replicas" -}}
{{- if .Values.singleNode -}}1{{- else -}}{{ .Values.api.replicas }}{{- end -}}
{{- end -}}

{{/*
PEKKO_BOOTSTRAP_REQUIRED_CONTACT_POINTS.

Derived, never configured. This is the number of management contact points
Cluster Bootstrap must discover before it will form a NEW cluster, and the
correct value is a majority of the members: floor(n/2)+1.

Upstream states the rule in a comment -- "If you change the member count, set
this to the new majority" -- which means the two numbers can disagree, and the
failure when they do is not an error. Set it too low and two pods that cannot
see each other each form a cluster of one; both serve, both accept writes,
and nothing reports a problem until their state has diverged.

Deriving it removes the opportunity.

  replicas 1 -> 1     replicas 2 -> 2     replicas 3 -> 2     replicas 5 -> 3
*/}}
{{- define "promovolve.api.requiredContactPoints" -}}
{{- $n := int (include "promovolve.api.replicas" .) -}}
{{- add (div $n 2) 1 -}}
{{- end -}}

{{/*
Effective anti-affinity.

singleNode wins here too. Anti-affinity over a single replica cannot spread
anything, and the hard form would additionally require a node the one pod is
not already on -- so it is a rule that either does nothing or refuses to
schedule. Read through this rather than from the value directly.
*/}}
{{- define "promovolve.api.antiAffinity" -}}
{{- if .Values.singleNode -}}none{{- else -}}{{ .Values.api.antiAffinity }}{{- end -}}
{{- end -}}

{{/*
Which HOCON overlay the api loads.

application-single.conf puts every role on one pod and is upstream's supported
answer for a one-member cluster: no peers to lose, no split-brain decision to
make, no shard coordinator to migrate.
*/}}
{{- define "promovolve.api.configFile" -}}
{{- if .Values.singleNode -}}application-single.conf{{- else -}}application-app.conf{{- end -}}
{{- end -}}

{{/*
JAVA_TOOL_OPTIONS for the api and singleton tiers.

JAVA_TOOL_OPTIONS rather than launcher arguments because the JVM honours it
directly and nothing depends on how the sbt-native-packager script parses its
own command line.
*/}}
{{- define "promovolve.api.javaToolOptions" -}}
{{- $v := .Values -}}
{{- $opts := list
  (printf "-Dconfig.file=/conf/%s" (include "promovolve.api.configFile" .))
  (printf "-XX:MaxRAMPercentage=%v" $v.api.maxRAMPercentage)
  (printf "-Dpekko.cluster.shutdown-after-unsuccessful-join-seed-nodes=%s" $v.api.bootstrap.shutdownAfterUnsuccessfulJoinSeedNodes)
  (printf "-Dpekko.management.cluster.bootstrap.contact-point.probing-failure-timeout=%s" $v.api.bootstrap.probingFailureTimeout)
  (printf "-Dpekko.management.cluster.bootstrap.contact-point.probe-interval=%s" $v.api.bootstrap.probeInterval)
  (printf "-Dpekko.management.cluster.bootstrap.contact-point-discovery.stable-margin=%s" $v.api.bootstrap.stableMargin)
  "-Dpekko.cluster.sharding.waiting-for-state-timeout=10s"
  "-Dpekko.cluster.sharding.distributed-data.majority-min-cap=2"
-}}
{{- if $v.api.debugLogging -}}
{{- $opts = append $opts "-Dlogback.configurationFile=/conf/logback-debug.xml" -}}
{{- end -}}
{{- join " " $opts -}}
{{- end -}}

{{/*
The api's HOCON overlay, as it is mounted.

Appends the durable-DData override when there is no volume to write to, rather
than passing it as a system property: Typesafe Config reads system properties
as strings, so -Dpekko.cluster.distributed-data.durable.keys=[] sets the string
"[]" where Pekko wants a list, and the process fails on a type error at
startup. A HOCON file is the only place a list can be emptied.

The three durable keys -- shard-*, exhausted-campaigns and serve-views-* -- are
all reconstructible, with the permanent data in Postgres. So emptying the list
is an accurate description of a deployment without a volume, not a workaround
for one.
*/}}
{{- define "promovolve.api.appConf" -}}
{{- .Files.Get (printf "files/%s" (include "promovolve.api.configFile" .)) }}
{{- if not .Values.api.persistence.enabled }}

# Appended by the chart: api.persistence.enabled is false, so there is no
# volume for durable DData and nothing may ask for one.
pekko.cluster.distributed-data.durable.keys = []
{{- end }}
{{- end -}}

{{/*
Where PostgreSQL is.
*/}}
{{- define "promovolve.postgresql.host" -}}
{{- if .Values.postgresql.bundled -}}
{{- printf "%s-db" (include "promovolve.fullname" .) -}}
{{- else -}}
{{- required "postgresql.host is required when postgresql.bundled is false" .Values.postgresql.host -}}
{{- end -}}
{{- end -}}

{{- define "promovolve.jdbcUrl" -}}
{{- printf "jdbc:postgresql://%s:%v/%s" (include "promovolve.postgresql.host" .) .Values.postgresql.port .Values.postgresql.database -}}
{{- end -}}

{{/*
Validation.

These fail the render rather than deploying something that starts and then
misbehaves quietly. Promovolve itself refuses to boot without its object store
and its LLM key for the same reason -- the alternative to a loud failure here
is not a working deployment, it is one whose symptoms point somewhere else.

  trackingBaseUrl wrong or empty  ads render, nothing is recorded
  rpId wrong                      passkeys register against a hostname that is
                                  not the one users will visit, permanently
  allowedOrigin empty             the BFF falls back to Access-Control-Allow-
                                  Origin: *, which is the local-development
                                  behaviour and not a deployment's
*/}}
{{- define "promovolve.validate" -}}
{{- if not .Values.config.trackingBaseUrl -}}
{{- fail "config.trackingBaseUrl is required. It is embedded into every served banner; empty means ads render and no tracking events are ingested. Include the /v1 prefix." -}}
{{- end -}}
{{- if not (hasSuffix "/v1" (trimSuffix "/" .Values.config.trackingBaseUrl)) -}}
{{- fail (printf "config.trackingBaseUrl must end in /v1 (got %q). The browser-facing routes live under pathPrefix(\"v1\") and upstream's own value includes it." .Values.config.trackingBaseUrl) -}}
{{- end -}}
{{- if not .Values.config.rpId -}}
{{- fail "config.rpId is required. Passkeys are bound to it permanently; there is no safe default." -}}
{{- end -}}
{{- if not .Values.config.rpOrigins -}}
{{- fail "config.rpOrigins is required and must match the origin the dashboard is served from." -}}
{{- end -}}
{{- if not .Values.config.allowedOrigin -}}
{{- fail "config.allowedOrigin is required. Empty makes the BFF fall back to Access-Control-Allow-Origin: *." -}}
{{- end -}}
{{- if not .Values.config.cdnBaseUrl -}}
{{- fail "config.cdnBaseUrl is required. It is where the viewer's browser fetches creative assets from." -}}
{{- end -}}
{{- if not (has .Values.api.antiAffinity (list "soft" "hard" "none")) -}}
{{- fail (printf "api.antiAffinity must be soft, hard or none (got %q)." .Values.api.antiAffinity) -}}
{{- end -}}
{{- if and (eq .Values.api.antiAffinity "hard") (gt (int (include "promovolve.api.replicas" .)) 1) -}}
{{- /* Not a failure: it is a legitimate choice on real multi-node infrastructure. */ -}}
{{- end -}}
{{- if gt (int .Values.platform.replicas) 1 -}}
{{- fail "platform.replicas above 1 does not work: in-flight WebAuthn ceremony state is held in process memory, so a ceremony started on one pod cannot be finished on another. Moving it to a database table is the prerequisite." -}}
{{- end -}}
{{- end -}}
