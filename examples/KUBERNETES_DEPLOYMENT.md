# Kubernetes Deployment Example

This example shows how to deploy XMAVLink in a Kubernetes cluster using DNS-based service discovery.

## Prerequisites

- Kubernetes cluster (v1.19+)
- kubectl configured
- Elixir application using XMAVLink

## Example Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌──────────────┐         ┌──────────────┐                 │
│  │              │         │              │                 │
│  │   MAVLink    │         │  Ground      │                 │
│  │   Router     │◄───────►│  Control     │                 │
│  │   Service    │  UDP    │  Station     │                 │
│  │              │  14550  │  Service     │                 │
│  └──────────────┘         └──────────────┘                 │
│         ▲                                                    │
│         │ TCP 5760                                          │
│         ▼                                                    │
│  ┌──────────────┐                                           │
│  │              │                                           │
│  │   ArduPilot  │                                           │
│  │   SITL       │                                           │
│  │   Service    │                                           │
│  │              │                                           │
│  └──────────────┘                                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### 1. XMAVLink Application Config

Update your `config/config.exs` or `config/runtime.exs` to use Kubernetes DNS names:

```elixir
# config/runtime.exs
import Config

# Get configuration from environment or use defaults
namespace = System.get_env("NAMESPACE", "default")

config :xmavlink,
  dialect: APM.Dialect,
  system_id: 255,
  component_id: 1,
  connections: [
    # Connect to Ground Control Station service
    "udpout:gcs-service.#{namespace}.svc.cluster.local:14550",
    
    # Connect to ArduPilot SITL service
    "tcpout:sitl-service.#{namespace}.svc.cluster.local:5760",
    
    # Listen for incoming UDP connections
    "udpin:0.0.0.0:14551"
  ]
```

### 2. Kubernetes Service Definitions

#### Ground Control Station Service

```yaml
# gcs-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: gcs-service
  namespace: default
spec:
  selector:
    app: ground-control-station
  ports:
    - protocol: UDP
      port: 14550
      targetPort: 14550
  type: ClusterIP
```

#### ArduPilot SITL Service

```yaml
# sitl-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: sitl-service
  namespace: default
spec:
  selector:
    app: ardupilot-sitl
  ports:
    - protocol: TCP
      port: 5760
      targetPort: 5760
  type: ClusterIP
```

#### MAVLink Router Service

```yaml
# router-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: router-service
  namespace: default
spec:
  selector:
    app: mavlink-router
  ports:
    - name: udp-in
      protocol: UDP
      port: 14551
      targetPort: 14551
  type: ClusterIP
```

### 3. Deployment Example

```yaml
# router-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mavlink-router
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mavlink-router
  template:
    metadata:
      labels:
        app: mavlink-router
    spec:
      containers:
        - name: router
          image: your-registry/mavlink-router:latest
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - containerPort: 14551
              protocol: UDP
              name: udp-in
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
```

## Deployment Steps

1. **Apply the service definitions:**

```bash
kubectl apply -f gcs-service.yaml
kubectl apply -f sitl-service.yaml
kubectl apply -f router-service.yaml
```

2. **Deploy your application:**

```bash
kubectl apply -f router-deployment.yaml
```

3. **Verify DNS resolution (optional):**

```bash
# Exec into the pod
kubectl exec -it <pod-name> -- /bin/sh

# Test DNS resolution
nslookup gcs-service.default.svc.cluster.local
nslookup sitl-service.default.svc.cluster.local
```

## Multi-Namespace Support

If your services are spread across different namespaces:

```elixir
# config/runtime.exs
config :xmavlink,
  dialect: APM.Dialect,
  connections: [
    # Service in same namespace
    "udpout:gcs-service.#{namespace}.svc.cluster.local:14550",
    
    # Service in different namespace
    "tcpout:sitl-service.simulation.svc.cluster.local:5760",
    
    # External service (using external DNS)
    "udpout:ground-station.example.com:14550"
  ]
```

## ConfigMap Example

For easier management, use a ConfigMap:

```yaml
# mavlink-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: mavlink-config
  namespace: default
data:
  connections: |
    udpout:gcs-service.default.svc.cluster.local:14550
    tcpout:sitl-service.default.svc.cluster.local:5760
    udpin:0.0.0.0:14551
```

Then in your deployment:

```yaml
spec:
  containers:
    - name: router
      envFrom:
        - configMapRef:
            name: mavlink-config
```

And in your Elixir config:

```elixir
# Parse connections from environment
connections = 
  System.get_env("connections", "")
  |> String.split("\n", trim: true)

config :xmavlink,
  dialect: APM.Dialect,
  connections: connections
```

## Troubleshooting

### DNS Resolution Issues

If you encounter DNS resolution errors:

1. **Check CoreDNS is running:**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

2. **Verify service exists:**
```bash
kubectl get svc gcs-service
```

3. **Test DNS from pod:**
```bash
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup gcs-service.default.svc.cluster.local
```

### Connection Issues

Check XMAVLink logs:

```bash
kubectl logs -f <pod-name>
```

Look for messages like:
- `Opened udpout:10.96.0.123:14550` (successful connection)
- `invalid address hostname: :nxdomain` (DNS resolution failed)

### Service Discovery

Verify services are reachable:

```bash
# From within a pod
kubectl exec -it <pod-name> -- nc -zv gcs-service.default.svc.cluster.local 14550
```

## Benefits in Kubernetes

1. **Dynamic IP Management**: Services can move between nodes without config changes
2. **Service Discovery**: Automatic discovery using Kubernetes DNS
3. **Namespace Isolation**: Services in different namespaces can be accessed via FQDN
4. **Scalability**: Easy to add/remove services without updating IP addresses
5. **GitOps Friendly**: Configuration is declarative and version-controlled

## Best Practices

1. **Use FQDNs**: Always use fully qualified domain names in production:
   - ✅ `service.namespace.svc.cluster.local`
   - ❌ `service` (might not resolve correctly across namespaces)

2. **Health Checks**: Implement readiness probes to ensure connections are established:
```yaml
readinessProbe:
  tcpSocket:
    port: 14551
  initialDelaySeconds: 5
  periodSeconds: 10
```

3. **Resource Limits**: Set appropriate resource limits to prevent DNS resolution timeout

4. **Logging**: Enable debug logging during initial deployment to catch DNS issues early

## See Also

- [Kubernetes DNS Documentation](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [XMAVLink README](../README.md)
- [DNS Hostname Support Documentation](DNS_HOSTNAME_SUPPORT.md)
