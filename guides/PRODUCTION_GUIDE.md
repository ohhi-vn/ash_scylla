# Production Guide: AshScylla with ScyllaDB Cluster

> Deploying AshScylla applications against multi-node ScyllaDB clusters for production workloads.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Cluster Topology](#cluster-topology)
4. [Podman Compose Cluster Setup (Staging)](#podman-compose-cluster-setup-staging)
5. [Kubernetes Deployment](#kubernetes-deployment)
6. [Repo Configuration](#repo-configuration)
7. [Connection Pool Tuning](#connection-pool-tuning)
8. [Consistency Levels in Production](#consistency-levels-in-production)
9. [Multi-Datacenter Setup](#multi-datacenter-setup)
10. [Monitoring and Observability](#monitoring-and-observability)
11. [Backup and Recovery](#backup-and-recovery)
12. [Rolling Upgrades](#rolling-upgrades)
13. [Production Checklist](#production-checklist)

---

## Overview

This guide covers running AshScylla in production against a ScyllaDB cluster. Topics include:

- Multi-node cluster deployment (Podman Compose for staging, Kubernetes for production)
- Connection pool sizing for high throughput
- Consistency level trade-offs across failure domains
- Multi-datacenter replication strategies
- Monitoring with Prometheus/Grafana
- Backup, recovery, and rolling upgrades

**Assumptions:**
- Familiarity with ScyllaDB concepts (nodes, racks, datacenters, vnodes)
- Basic Kubernetes knowledge (for the K8s section)
- Ash Framework basics (see [USAGE_GUIDE.md](USAGE_GUIDE.md))

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ BEAM VM  │  │ BEAM VM  │  │ BEAM VM  │  │ BEAM VM  │        │
│  │  Node 1  │  │  Node 2  │  │  Node 3  │  │  Node N  │        │
│  │          │  │          │  │          │  │          │        │
│  │ Xandra   │  │ Xandra   │  │ Xandra   │  │ Xandra   │        │
│  │  Pool    │  │  Pool    │  │  Pool    │  │  Pool    │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │              │              │              │              │
│       └──────────────┴──────┬───────┴──────────────┘              │
│                             │ CQL (9042)                          │
└─────────────────────────────┼─────────────────────────────────────┘
                              │
┌─────────────────────────────┼─────────────────────────────────────┐
│                     ScyllaDB Cluster                              │
│                             │                                     │
│  ┌──────────────────────────┼──────────────────────────────────┐  │
│  │  Datacenter: dc-east     │                                  │  │
│  │                          │                                  │  │
│  │  ┌─────────┐  ┌─────────┼─┐  ┌─────────┐  ┌─────────┐    │  │
│  │  │  Rack 1 │  │  Rack 2  │  │  Rack 3 │  │  Rack N │    │  │
│  │  │         │  │          │  │         │  │         │    │  │
│  │  │ Node 1  │  │  Node 2  │  │ Node 3  │  │ Node N  │    │  │
│  │  │ :9042   │  │  :9042   │  │ :9042   │  │ :9042   │    │  │
│  │  └─────────┘  └──────────┘  └─────────┘  └─────────┘    │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Datacenter: dc-west  (optional, for multi-DC)             │  │
│  │  ...                                                       │  │
│  └────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

Each BEAM node runs a Xandra connection pool. Xandra uses ScyllaDB's shard-aware routing to send queries directly to the node owning the data, minimizing cross-node hops.

---

## Cluster Topology

### Recommended Topology

| Environment | Nodes | Replication Factor | Datacenters | Racks |
|-------------|-------|-------------------|-------------|-------|
| Development | 1 | 1 | 1 | 1 |
| Staging | 3 | 3 | 1 | 1-3 |
| Production | 5+ | 3 | 1-3 | 3 |
| Multi-DC | 6+ | 3 per DC | 2+ | 3 per DC |

### Keyspace Replication Strategies

```elixir
# Single datacenter
MyApp.Repo.create_keyspace("my_app_prod", replication: [
  strategy: "SimpleStrategy",
  replication_factor: 3
])

# Multi-datacenter
MyApp.Repo.create_keyspace("my_app_prod", replication: [
  strategy: "NetworkTopologyStrategy",
  dc_east: 3,
  dc_west: 3
])
```

---

## Podman Compose Cluster Setup (Staging)

Use this for staging environments that mirror production topology:

```yaml
# podman-compose.cluster.yml
version: "3.8"

x-scylla-common: &scylla-common
  image: docker.io/scylladb/scylla:5.4
  command: >
    --smp 2
    --memory 4G
    --overprovisioned 0
    --developer-mode 0
  healthcheck:
    test: ["CMD-SHELL", "cqlsh -e 'SELECT now() FROM system.local'"]
    interval: 15s
    timeout: 10s
    retries: 20

services:
  # --- Seed nodes (start first) ---
  scylla-seed-1:
    <<: *scylla-common
    container_name: scylla-seed-1
    hostname: scylla-seed-1
    ports:
      - "9042:9042"
    volumes:
      - scylla-seed-1-data:/var/lib/scylla
    command: >
      --smp 2 --memory 4G
      --seeds scylla-seed-1
      --listen-address scylla-seed-1
      --rpc-address scylla-seed-1
      --api-address 0.0.0.0

  scylla-seed-2:
    <<: *scylla-common
    container_name: scylla-seed-2
    hostname: scylla-seed-2
    volumes:
      - scylla-seed-2-data:/var/lib/scylla
    depends_on:
      scylla-seed-1:
        condition: service_healthy
    command: >
      --smp 2 --memory 4G
      --seeds scylla-seed-1
      --listen-address scylla-seed-2
      --rpc-address scylla-seed-2
      --api-address 0.0.0.0

  # --- Data nodes (join after seeds are healthy) ---
  scylla-node-3:
    <<: *scylla-common
    container_name: scylla-node-3
    hostname: scylla-node-3
    volumes:
      - scylla-node-3-data:/var/lib/scylla
    depends_on:
      scylla-seed-1:
        condition: service_healthy
      scylla-seed-2:
        condition: service_healthy
    command: >
      --smp 2 --memory 4G
      --seeds scylla-seed-1,scylla-seed-2
      --listen-address scylla-node-3
      --rpc-address scylla-node-3
      --api-address 0.0.0.0

  scylla-node-4:
    <<: *scylla-common
    container_name: scylla-node-4
    hostname: scylla-node-4
    volumes:
      - scylla-node-4-data:/var/lib/scylla
    depends_on:
      scylla-seed-1:
        condition: service_healthy
      scylla-seed-2:
        condition: service_healthy
    command: >
      --smp 2 --memory 4G
      --seeds scylla-seed-1,scylla-seed-2
      --listen-address scylla-node-4
      --rpc-address scylla-node-4
      --api-address 0.0.0.0

  scylla-node-5:
    <<: *scylla-common
    container_name: scylla-node-5
    hostname: scylla-node-5
    volumes:
      - scylla-node-5-data:/var/lib/scylla
    depends_on:
      scylla-seed-1:
        condition: service_healthy
      scylla-seed-2:
        condition: service_healthy
    command: >
      --smp 2 --memory 4G
      --seeds scylla-seed-1,scylla-seed-2
      --listen-address scylla-node-5
      --rpc-address scylla-node-5
      --api-address 0.0.0.0

  # --- Application ---
  app:
    image: ${ELIXIR_IMAGE:-docker.io/elixir:1.17-alpine}
    depends_on:
      scylla-seed-1:
        condition: service_healthy
      scylla-seed-2:
        condition: service_healthy
      scylla-node-3:
        condition: service_healthy
      scylla-node-4:
        condition: service_healthy
      scylla-node-5:
        condition: service_healthy
    volumes:
      - .:/workspace
    working_dir: /workspace
    command: sleep infinity
    environment:
      - MIX_ENV=staging

volumes:
  scylla-seed-1-data:
  scylla-seed-2-data:
  scylla-node-3-data:
  scylla-node-4-data:
  scylla-node-5-data:
```

### Starting the Cluster

```bash
# Start all nodes
podman-compose -f podman-compose.cluster.yml up -d

# Watch the cluster form
podman-compose -f podman-compose.cluster.yml logs -f scylla-seed-1

# Verify cluster status (from inside the app container)
podman-compose -f podman-compose.cluster.yml exec app \
  sh -c 'cqlsh scylla-seed-1 -e "SELECT peer, data_center, rack, tokens FROM system.peers"'
```

### Creating the Keyspace

```bash
# From inside the app container
podman-compose -f podman-compose.cluster.yml exec app \
  sh -c 'cqlsh scylla-seed-1 -e "
    CREATE KEYSPACE IF NOT EXISTS my_app_staging
    WITH REPLICATION = {
      'class': 'NetworkTopologyStrategy',
      'dc1': 3
    }
    AND DURABLE_WRITES = true;
  "'
```

---

## Kubernetes Deployment

For production, deploy ScyllaDB on Kubernetes using the [Scylla Operator](https://operator.docs.scylladb.com/).

### 1. Install the Scylla Operator

```bash
kubectl apply -f https://raw.githubusercontent.com/scylladb/scylla-operator/master/examples/common/operator.yaml
```

### 2. Define the ScyllaCluster

```yaml
# k8s/scylla-cluster.yaml
apiVersion: scylla.scylladb.com/v1
kind: ScyllaCluster
metadata:
  name: my-app-scylla
  namespace: production
spec:
  version: 5.4.0
  agentVersion: 3.2.0
  developerMode: false
  datacenter:
    name: dc1
    racks:
      - name: rack-a
        members: 2
        storage:
          capacity: 500Gi
          storageClassName: scylladb-local-xfs
        resources:
          requests:
            cpu: "4"
            memory: 16Gi
          limits:
            cpu: "4"
            memory: 16Gi
      - name: rack-b
        members: 2
        storage:
          capacity: 500Gi
          storageClassName: scylladb-local-xfs
        resources:
          requests:
            cpu: "4"
            memory: 16Gi
          limits:
            cpu: "4"
            memory: 16Gi
      - name: rack-c
        members: 1
        storage:
          capacity: 500Gi
          storageClassName: scylladb-local-xfs
        resources:
          requests:
            cpu: "4"
            memory: 16Gi
          limits:
            cpu: "4"
            memory: 16Gi
  repairs:
    - name: weekly-repair
      intensity: "100"
      interval: "7d"
  backups:
    - name: daily-backup
      location: ["s3:my-scylla-backups"]
      interval: "24h"
      retention: 30
```

### 3. Application Deployment

```yaml
# k8s/app-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: my-registry/my-app:latest
          ports:
            - containerPort: 4000
          env:
            - name: SCYLLA_NODES
              valueFrom:
                configMapKeyRef:
                  name: scylla-config
                  key: nodes
            - name: SCYLLA_KEYSPACE
              value: "my_app_prod"
            - name: SCYLLA_POOL_SIZE
              value: "50"
            - name: SCYLLA_REQUEST_TIMEOUT
              value: "300000"
            - name: SCYLLA_CONSISTENCY
              value: "quorum"
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: scylla-credentials
                  key: url
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
          readinessProbe:
            exec:
              command:
                - /app/bin/my_app
                - eval
                - "MyApp.Repo.query(\"SELECT now() FROM system.local\")"
            initialDelaySeconds: 30
            periodSeconds: 10
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: scylla-config
  namespace: production
data:
  nodes: "my-app-scylla-dc1-rack-a-0.my-app-scylla:9042,my-app-scylla-dc1-rack-a-1.my-app-scylla:9042,my-app-scylla-dc1-rack-b-0.my-app-scylla:9042"
```

---

## Repo Configuration

### Production Config

```elixir
# config/runtime.exs
import Config

config :my_app, MyApp.Repo,
  nodes: System.get_env("SCYLLA_NODES", "localhost:9042")
           |> String.split(",")
           |> Enum.map(&String.trim/1),
  keyspace: System.get_env("SCYLLA_KEYSPACE", "my_app_prod"),
  pool_size: String.to_integer(System.get_env("SCYLLA_POOL_SIZE", "50")),
  request_timeout: 300_000,
  connect_timeout: 10_000,
  # TLS (recommended for production)
  ssl: true,
  ssl_opts: [
    verify: :verify_peer,
    cacertfile: "/etc/ssl/certs/scylla-ca.crt",
    certfile: "/etc/ssl/certs/client.crt",
    keyfile: "/etc/ssl/private/client.key"
  ]

# Note: consistency is configured per-resource in the ash_scylla DSL,
# not as a connection option. See per-resource overrides below.
```

### Per-Resource Overrides

```elixir
defmodule MyApp.CriticalTransaction do
  use Ash.Resource, data_layer: AshScylla.DataLayer

  scylla do
    consistency :all        # Strongest consistency for financial data
    lwt true                # Lightweight transactions for conditional writes
  end
end

defmodule MyApp.AnalyticsEvent do
  use Ash.Resource, data_layer: AshScylla.DataLayer

  scylla do
    consistency :one        # Fastest writes for analytics
    ttl 86_400              # Auto-expire after 24 hours
  end
end
```

---

## Connection Pool Tuning

### Pool Size Formula

```
pool_size = (concurrent_requests_per_node × 1.5) + burst_headroom
```

| Scenario | Concurrent Requests | Recommended Pool Size |
|----------|--------------------|-----------------------|
| Low traffic (< 100 req/s) | 5-10 | 10-15 |
| Medium traffic (100-1000 req/s) | 10-50 | 25-75 |
| High traffic (1000-10000 req/s) | 50-200 | 100-300 |
| Very high traffic (> 10000 req/s) | 200+ | 300+ |

### Xandra-Specific Tuning

```elixir
config :my_app, MyApp.Repo,
  # Core pool settings
  pool_size: 50,
  # Request handling
  request_timeout: 300_000,      # 5 minutes for complex queries
  connect_timeout: 10_000,       # 10 seconds for initial connection

  # TCP options (passed to :gen_tcp / :ssl)
  transport_options: [
    keepalive: true,
    nodelay: true,
    send_timeout: 30_000,
    send_timeout_close: true
  ]
```

### Monitoring Pool Health

```elixir
# In IEx or a telemetry handler
:telemetry.attach(
  "pool-monitor",
  [:my_app, :repo, :query],
  fn event, measurements, metadata, _config ->
    duration = System.convert_time_unit(measurements.duration, :native, :millisecond)
    if duration > 1000 do
      Logger.warning("Slow query: #{metadata.query} took #{duration}ms")
    end
  end,
  nil
)
```

---

## Consistency Levels in Production

### Decision Matrix

| Operation Type | Recommended Level | Reason |
|---------------|-------------------|--------|
| User authentication | `:quorum` | Must read latest password hash |
| Financial transactions | `:quorum` + LWT | Prevent double-spending |
| Analytics writes | `:one` | Speed matters more than immediate consistency |
| Cache writes | `:one` | Can tolerate stale reads |
| Session data | `:one` | Low cardinality, fast access |
| Leaderboards | `:quorum` | Must be accurate |
| Social feeds | `:local_quorum` | Multi-DC: fast local reads |

### Per-Action Consistency

```elixir
defmodule MyApp.Order do
  use Ash.Resource, data_layer: AshScylla.DataLayer

  scylla do
    # Default consistency for most operations
    consistency :quorum

    # Per-action overrides
    per_action_consistency [
      read: :one,        # Reads can be fast
      create: :quorum,   # Writes must be consistent
      update: :quorum,
      destroy: :all      # Deletes must be strongly consistent
    ]
  end
end
```

### Lightweight Transactions (LWT)

Use LWT for operations that require linearizable consistency:

```elixir
defmodule MyApp.Inventory do
  use Ash.Resource, data_layer: AshScylla.DataLayer

  scylla do
    lwt true  # Enables IF NOT EXISTS / IF conditions
  end

  actions do
    create :reserve do
      argument :quantity, :integer, allow_nil?: false

      change fn changeset, _context ->
        # This generates: INSERT INTO inventory ... IF NOT EXISTS
        Ash.Changeset.before_transaction(fn changeset ->
          # Atomic inventory check-and-reserve
          changeset
        end)
      end
    end
  end
end
```

> **Warning:** LWT operations are 4-8x slower than regular writes due to the Paxos protocol. Use sparingly.

---

## Multi-Datacenter Setup

### Topology

```
┌─────────────────────────────┐     ┌─────────────────────────────┐
│     Datacenter: dc-east     │     │     Datacenter: dc-west     │
│                             │     │                             │
│  ┌───────┐ ┌───────┐ ┌─────┐│     │ ┌───────┐ ┌───────┐ ┌─────┐│
│  │Node 1 │ │Node 2 │ │Node 3││     │ │Node 4 │ │Node 5 │ │Node 6││
│  │ Rack A│ │ Rack B│ │Rack C││     │ │ Rack A│ │ Rack B│ │Rack C││
│  └───────┘ └───────┘ └─────┘│     │ └───────┘ └───────┘ └─────┘│
│         RF = 3               │     │         RF = 3               │
└─────────────────────────────┘     └─────────────────────────────┘
         │                                   │
         └────────── Sync Replication ───────┘
```

### Keyspace Creation

```elixir
# Multi-DC keyspace with NetworkTopologyStrategy
MyApp.Repo.create_keyspace("my_app_prod", replication: [
  strategy: "NetworkTopologyStrategy",
  dc_east: 3,
  dc_west: 3
])
```

### Application-Level DC Awareness

```elixir
# config/runtime.exs
local_dc = System.get_env("LOCAL_DATacenter", "dc_east")

config :my_app, MyApp.Repo,
  nodes: scylla_nodes_for_dc(local_dc),
  consistency: :local_quorum  # Read/write to local DC only

defp scylla_nodes_for_dc("dc_east") do
  ["scylla-east-1:9042", "scylla-east-2:9042", "scylla-east-3:9042"]
end

defp scylla_nodes_for_dc("dc_west") do
  ["scylla-west-1:9042", "scylla-west-2:9042", "scylla-west-3:9042"]
end
```

### Consistency Levels for Multi-DC

| Level | Behavior | Latency |
|-------|----------|---------|
| `:one` | Any node in any DC | Lowest |
| `:local_one` | Any node in local DC | Low |
| `:quorum` | Majority of all nodes across all DCs | High |
| `:local_quorum` | Majority of nodes in local DC | Medium |
| `:each_quorum` | Majority in every DC | Highest |
| `:all` | All nodes in all DCs | Highest |

---

## Monitoring and Observability

### Telemetry Events

AshScylla emits telemetry events that integrate with any observability backend:

```elixir
# Attach to query events
:telemetry.attach_many(
  "ash-scylla-telemetry",
  [
    [:ash_scylla, :query, :start],
    [:ash_scylla, :query, :stop],
    [:ash_scylla, :query, :exception],
    [:ash_scylla, :batch, :start],
    [:ash_scylla, :batch, :stop]
  ],
  fn event, measurements, metadata, _config ->
    case event do
      [:ash_scylla, :query, :stop] ->
        duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
        :telemetry.execute([:my_app, :scylla, :query], %{duration: duration_ms}, %{
          operation: metadata.operation,
          resource: metadata.resource
        })

      [:ash_scylla, :query, :exception] ->
        Logger.error("ScyllaDB query failed: #{inspect(metadata)}")

      _ ->
        :ok
    end
  end,
  nil
)
```

### Prometheus Integration

```elixir
# In your application supervision tree
children = [
  # ... other children
  {TelemetryMetricsPrometheus, metrics: scylla_metrics()}
]

defp scylla_metrics do
  [
    counter("scylla.query.count",
      event_name: [:ash_scylla, :query, :stop],
      tags: [:operation, :resource]
    ),
    distribution("scylla.query.duration",
      event_name: [:ash_scylla, :query, :stop],
      tags: [:operation, :resource],
      unit: {:native, :millisecond},
      reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
    ),
    counter("scylla.query.errors",
      event_name: [:ash_scylla, :query, :exception],
      tags: [:operation, :resource]
    ),
    counter("scylla.batch.count",
      event_name: [:ash_scylla, :batch, :stop],
      tags: [:operation]
    )
  ]
end
```

### Health Checks

```elixir
# lib/my_app/health/checks/scylla.ex
defmodule MyApp.Health.Checks.Scylla do
  @moduledoc "ScyllaDB health check for Kubernetes probes."

  def check do
    case MyApp.Repo.query("SELECT now() FROM system.local") do
      {:ok, _} ->
        :ok

      {:error, %Xandra.ConnectionError{reason: reason}}:
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, %Xandra.Error{reason: reason}}:
        {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  def cluster_status do
    {:ok, result} = MyApp.Repo.query("SELECT peer, rpc_address, data_center, rack, tokens FROM system.peers")

    peers = Enum.map(result.rows, fn [peer, rpc_address, dc, rack, _tokens] ->
      %{
        peer: to_string(peer),
        rpc_address: to_string(rpc_address),
        datacenter: to_string(dc),
        rack: to_string(rack),
        status: if(peer != rpc_address, do: :up, :down)
      }
    end)

    %{peers: peers, peer_count: length(peers)}
  end
end
```

### Key Metrics to Monitor

| Metric | Warning Threshold | Critical Threshold |
|--------|------------------|-------------------|
| Query p99 latency | > 50ms | > 200ms |
| Query error rate | > 0.1% | > 1% |
| Connection pool utilization | > 70% | > 90% |
| Pending requests (queue) | > 100 | > 1000 |
| ScyllaDB node load | > 70% CPU | > 90% CPU |
| Compaction pending tasks | > 20 | > 100 |

---

## Backup and Recovery

### Automated Backups with Scylla Manager

```yaml
# scylla-manager backup task
apiVersion: scylla.scylladb.com/v1alpha1
kind: ScyllaBackupTask
metadata:
  name: daily-backup
  namespace: production
spec:
  task:
    name: daily-full-backup
    cron: "0 2 * * *"  # 2 AM daily
    dc: ["dc1"]
    location: ["s3:my-scylla-backups"]
    rateLimit: ["100M"]
    retention: 30  # Keep 30 days
    keyspace: ["my_app_prod"]
```

### Point-in-Time Recovery

```bash
# Restore from backup
sctool restore --cluster my-app-scylla \
  --location s3:my-scylla-backups \
  --snapshot-tag sm_20240612_020000UTC \
  --keyspace my_app_prod
```

---

## Rolling Upgrades

### ScyllaDB Rolling Upgrade

```bash
# 1. Upgrade one node at a time
kubectl drain scylla-dc1-rack-a-0 --ignore-daemonsets

# 2. Update the ScyllaCluster CR to new version
kubectl patch scyllacluster my-app-scylla \
  --type merge \
  -p '{"spec":{"version":"5.4.1"}}'

# 3. Wait for the node to rejoin
kubectl rollout status statefulset/my-app-scylla-dc1-rack-a

# 4. Run nodetool upgradesstables on the upgraded node
kubectl exec my-app-scylla-dc1-rack-a-0 -- nodetool upgradesstables

# 5. Repeat for each node
```

### Application Rolling Upgrade

```bash
# Kubernetes rolling update
kubectl set image deployment/my-app my-app=my-registry/my-app:v2.0.0

# Monitor the rollout
kubectl rollout status deployment/my-app

# Verify ScyllaDB connectivity from new pods
kubectl exec deploy/my-app -- \
  /app/bin/my_app eval "MyApp.Repo.query(\"SELECT now() FROM system.local\")"
```

---

## Production Checklist

### Before Going Live

- [ ] **Cluster topology**: Minimum 3 nodes, RF=3
- [ ] **Connection pool**: Sized for peak load + 50% headroom
- [ ] **Consistency levels**: Appropriate per resource/action
- [ ] **TLS**: Enabled for all connections
- [ ] **Authentication**: Username/password or certificate-based
- [ ] **Backups**: Automated daily backups configured
- [ ] **Monitoring**: Telemetry + Prometheus + Grafana dashboards
- [ ] **Alerting**: PagerDuty/Slack alerts for critical metrics
- [ ] **Health checks**: Kubernetes liveness/readiness probes
- [ ] **Resource limits**: CPU/memory limits on all containers
- [ ] **Disaster recovery**: Tested restore procedure
- [ ] **Load testing**: Verified performance under expected load
- [ ] **Schema review**: All tables have appropriate primary keys
- [ ] **Index review**: Secondary indexes are necessary and performant
- [ ] **TTL review**: Data expiration policies are set

### Connection Configuration Template

```elixir
# config/runtime.exs — production template
import Config

# Parse node list from environment
nodes =
  case System.get_env("SCYLLA_NODES") do
    nil ->
      raise "SCYLLA_NODES environment variable is required"

    nodes ->
      nodes
      |> String.split(",")
      |> Enum.map(&String.trim/1)
  end

config :my_app, MyApp.Repo,
  nodes: nodes,
  keyspace: System.fetch_env!("SCYLLA_KEYSPACE"),
  pool_size: String.to_integer(System.get_env("SCYLLA_POOL_SIZE", "50")),
  request_timeout: 300_000,
  connect_timeout: 10_000,
  consistency: :quorum,
  ssl: true,
  ssl_opts: [
    verify: :verify_peer,
    cacertfile: System.fetch_env!("SCYLLA_CA_CERT"),
    certfile: System.fetch_env!("SCYLLA_CLIENT_CERT"),
    keyfile: System.fetch_env!("SCYLLA_CLIENT_KEY")
  ]
```
