# Backlog

## Presentation experience

- Hide the nono update banner and the Node `EnvHttpProxyAgent` warning in the
  saved log as well (they are already absent from the presenter view).
- Generate a final expected-versus-observed capability table.
- Prepare a split terminal/GitHub layout and a one-click recorded fallback.

## Operator experience

- Let `scripts/check-ready.sh` test the model key and token expiry without exposing them.
- Add an explicit `rehearse`, `live`, and `cleanup` command surface.

## Security and evidence

- Add an independent Kubernetes or VPC egress control around the workload.
- Sign the image, verify it at admission, publish an SBOM, and scan the image
  and custom guest kernel.
- Re-run the live adversarial profile suite after every Pi, nono, Kata, kernel,
  Kubernetes, or `gh` upgrade.
- Replace the sentinel-domain workaround when nono provides a first-class
  deny-all mode compatible with credential routes.
- Consider separate GitHub identities and separate Kata guests for a
  production-strength variant.
