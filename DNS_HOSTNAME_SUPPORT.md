# DNS Hostname Resolution Support

## Summary

Added DNS hostname resolution support to XMAVLink.Router, allowing the use of DNS hostnames (FQDNs) in addition to IP addresses in connection strings. This enables XMAVLink to work seamlessly in Kubernetes, Docker, and other cloud-native environments where service discovery relies on DNS.

## Changes Made

### 1. New Function: `XMAVLink.Utils.resolve_address/1`

Added a new public function in `lib/mavlink/utils.ex` that resolves both IP addresses and DNS hostnames to IP address tuples:

```elixir
@spec resolve_address(binary()) :: {:ok, tuple()} | {:error, atom()}
def resolve_address(address) when is_binary(address)
```

**Implementation Details:**
- Uses Erlang's `:inet.getaddr/2` for resolution
- Handles both IP addresses and DNS hostnames transparently
- Returns `{:ok, ip_tuple}` on success
- Returns `{:error, reason}` on failure (e.g., `:nxdomain` for unresolvable hostnames)
- Supports IPv4 addresses (IPv6 support can be added in the future)

**Example Usage:**
```elixir
iex> XMAVLink.Utils.resolve_address("127.0.0.1")
{:ok, {127, 0, 0, 1}}

iex> XMAVLink.Utils.resolve_address("localhost")
{:ok, {127, 0, 0, 1}}

iex> XMAVLink.Utils.resolve_address("service.namespace.svc.cluster.local")
{:ok, {10, 96, 0, 123}}  # Example Kubernetes ClusterIP

iex> XMAVLink.Utils.resolve_address("invalid-hostname.example")
{:error, :nxdomain}
```

### 2. Updated `XMAVLink.Router.validate_address_and_port/1`

Modified the router's validation function in `lib/mavlink/router.ex` to:
- Use `resolve_address/1` instead of `parse_ip_address/1`
- Provide better error messages that include the resolution failure reason
- Maintain backward compatibility with existing IP address usage

**Before:**
```elixir
case {parse_ip_address(address), parse_positive_integer(port)} do
  {{:error, :invalid_ip_address}, _} ->
    raise ArgumentError, message: "invalid ip address #{address}"
  # ...
end
```

**After:**
```elixir
case {resolve_address(address), parse_positive_integer(port)} do
  {{:error, reason}, _} ->
    raise ArgumentError, message: "invalid address #{address}: #{inspect(reason)}"
  # ...
end
```

### 3. Comprehensive Test Coverage

Added new tests in `test/mavlink_utils_test.exs`:
- Test IP address resolution
- Test DNS hostname resolution (using `localhost`)
- Test invalid hostname handling

Added new test file `test/mavlink_router_test.exs` with 7 tests:
- Accepts IP addresses in UDP and TCP connections (backward compatibility)
- Accepts DNS hostnames in UDP and TCP connections (new functionality)
- Properly rejects invalid hostnames with descriptive errors
- Properly rejects invalid and negative port numbers

All tests pass successfully.

## Benefits

### Kubernetes/Container Environments
```elixir
config :xmavlink,
  dialect: APM.Dialect,
  connections: [
    "udpout:router-service.rpiuav.svc.cluster.local:14550",
    "tcpout:gcs-service.default.svc.cluster.local:5760"
  ]
```

### Development Environments
```elixir
config :xmavlink,
  dialect: APM.Dialect,
  connections: [
    "udpout:localhost:14550",
    "tcpout:localhost:5760"
  ]
```

### Cloud-Native Deployments
- Works with dynamic IP addresses
- Leverages existing DNS infrastructure
- Follows cloud-native best practices
- Compatible with service mesh architectures

## Backward Compatibility

✅ **Fully backward compatible** - All existing code using IP addresses continues to work without any changes:

```elixir
# Still works exactly as before
config :xmavlink,
  dialect: Common,
  connections: [
    "udpout:192.168.1.100:14550",
    "tcpout:127.0.0.1:5760"
  ]
```

## Error Handling

Invalid hostnames are caught during router initialization and provide clear error messages:

```elixir
# Invalid hostname
config :xmavlink, connections: ["udpout:invalid-host.example:14550"]

# Results in:
** (ArgumentError) invalid address invalid-host.example: :nxdomain
```

This fail-fast behavior ensures configuration errors are caught immediately rather than silently failing.

## Technical Notes

### DNS Resolution Timing
- DNS resolution happens once at router initialization
- For long-running applications where DNS records might change, a future enhancement could add periodic re-resolution
- Current implementation is optimal for containerized environments where DNS names are stable after initial resolution

### IPv6 Support
The current implementation uses `:inet.getaddr(address, :inet)` which resolves to IPv4 addresses. IPv6 support can be added by:
- Using `:inet6` family for IPv6-only resolution
- Using `:inet.getaddrs/2` for both IPv4 and IPv6
- Adding configuration options to prefer IPv4 or IPv6

### Performance
DNS resolution adds minimal overhead (typically <10ms) during router initialization. Once resolved, the IP address is used directly for all subsequent connections, so there is zero runtime performance impact.

## Testing

Run the test suite:

```bash
# Test DNS resolution utilities
mix test test/mavlink_utils_test.exs

# Test router DNS hostname support
mix test test/mavlink_router_test.exs

# Run all tests
mix test
```

All tests pass with 0 failures.

## Migration Guide

No migration needed! This is a backward-compatible enhancement. To use DNS hostnames:

1. Simply replace IP addresses with hostnames in your connection strings
2. Ensure DNS resolution works in your environment (`nslookup` or `dig` can verify)
3. Restart your XMAVLink application

Example:

```elixir
# Before
config :xmavlink, connections: ["udpout:10.96.0.123:14550"]

# After
config :xmavlink, connections: ["udpout:router-service.default.svc.cluster.local:14550"]
```

## Future Enhancements

Potential improvements for future versions:
- IPv6 support
- Periodic DNS re-resolution for long-running applications
- DNS caching with TTL support
- Support for SRV records for service discovery
- Health checks and automatic failover for multi-A record hostnames
