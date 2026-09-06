# Incident response without pause or upgrade

Swaputer Worlds are immutable and administrator-free. Incident response is an operational response,
not a hidden control plane.

## Executable actions

1. Preserve chain/RPC responses, receipts, Events payloads, indexer database and software versions.
2. Privately contact the reporter and future independent auditor; classify the incident.
3. Stop the official UI and stop recommending the official Router/manifest for the affected World.
4. Publish a signed security notice and mark the manifest/World `deprecated` in official discovery.
5. Stop official new liquidity; when feasible, withdraw only project-owned LP positions.
6. Remove the World from indexer/UI recommended views while retaining canonical/raw/orphan history.
7. Deploy a fixed, separately sealed new World and publish independently verifiable commitments.
8. Publish migration and sell-exit instructions; monitor old and replacement Worlds.

## Explicit non-capabilities

- The project cannot freeze third-party accounts or LP positions.
- It cannot prevent direct calls to immutable PoolManager/Hook/Router/Kernel contracts.
- It cannot upgrade or patch an old World and cannot guarantee third-party LP withdrawal.
- Stopping an official UI/indexer does not pause the protocol.
- No communication may claim an emergency pause exists.

If safe migration cannot be provided, state that plainly. Every replacement requires a new release
identity; never rewrite rc2 or an existing World manifest.
