# Container stop safety

Container grouping remains a best-effort display feature. A **Stop Container** action requires
local ownership evidence, not merely a matching port number or Docker context.

- Discovery identifies a known forwarder executable and its runtime-specific local Unix socket.
  The canonical socket path, filesystem identity, Engine daemon ID and full 64-character
  container ID remain pinned through review and execution. The global Docker context and
  `DOCKER_*` environment variables are never used for these operations.
- Docker Desktop and recognized OrbStack helper paths are supported. Colima requires a
  profile-specific forwarder path. Unknown helpers, generic Lima/gvproxy processes, remote
  contexts, missing sockets and unprovable profiles stay runtime-only rows. This intentionally
  favors refusing an action over guessing which daemon owns a listener.
- Only TCP mappings can own a scanned TCP listener. Normalized bind addresses must match;
  multiple possible container owners, including ambiguous wildcard listeners, remain unresolved.
  A native process on the same numeric port is never given container metadata.
- The review is an immutable inspection, including name, image, all published TCP/UDP/SCTP
  bindings, restart policy and start time. Unknown restart policy is shown as a warning.
- Confirmation takes a fresh scan, revalidates the selected forwarder and socket, then reinspects
  the same daemon/container immediately before one `docker --host … stop <full-ID>` call.
  Missing metadata, replaced IDs, renamed/restarted containers or changed impact require a new
  review. Cancellation before execution sends no stop command.
- Verification uses a successful scan started after the stop. The selected TCP port is always
  included, even if container metadata has disappeared. A failed scan means verification is
  unavailable, not that a port is free. A reused port remains a warning regardless of its new
  owner. UDP/SCTP mappings are shown as stop impact but are not claimed free by a TCP-only scan.

As with other inspect-then-act interfaces, Docker does not offer a transactional conditional stop.
The immutable ID prevents a removed container's name from selecting a replacement; final checks
minimize the remaining interval for changes to the same container. No runtime forwarder is
signaled by this action.

## Verification

`swift test --filter ContainerSafetyTests` runs deterministic parser, ownership, backoff,
inspection, cancellation and post-stop verification fixtures, without requiring a local daemon.
`swift test` additionally checks the existing core/app behavior. Both require macOS because the
package uses Darwin, Network and AppKit/SwiftUI.

Before merging, run the full macOS CI matrix and a manual smoke test on the runtimes you support:

1. Open a TCP container listener and verify the review shows the full ID, explicit local socket,
   image and all published bindings, including UDP siblings.
2. Cancel the review. Confirm the container is still running.
3. Confirm an unchanged review. Confirm exactly that container stops; the runtime keeps running.
4. With a review open, rename/restart the container or change its restart policy. Confirmation
   must refuse and ask for a new review.
5. If Docker's active context points elsewhere, local discovery/stop must still use the displayed
   socket. Unresolved ownership must never fall back to a remote context.

Use disposable local test containers. Do not use production containers for destructive checks.
