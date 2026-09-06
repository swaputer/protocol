# Responsible disclosure

1. Stop testing when real funds, third-party systems or unintended data may be affected.
2. Send a private report using the configured security contact; if none is configured, do not
   publish the exploit and use the project owner's existing private coordination channel.
3. Include the affected tag/commit, minimal local/testnet PoC, logs and impact without secrets.
4. Preserve relevant transaction hashes, Events payloads and deterministic inputs.
5. Coordinate an embargo while the team reproduces, deploys a replacement World when necessary,
   and prepares user migration instructions.
6. Disclose publicly only after mutual coordination or when required by law.

Never send seed phrases, private keys, RPC credentials or `wallet.txt`. The immutable protocol has
no emergency pause; disclosure coordination cannot promise that third parties will stop interacting
with an affected World.
