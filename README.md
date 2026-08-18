# Tracedown installer

The interactive install script served at **https://tracedown.dev/install.sh**:

```bash
curl -fsSL https://tracedown.dev/install.sh | bash
```

It can stand up the [monolith](https://tracedown.dev/install/monolith/)
(everything in one container, plus Postgres and Redis), the full
[per-service stack](https://tracedown.dev/install/deploy/) from the published
release artifacts (optionally writing and enabling the host nginx vhost),
connect a probe agent to an existing stack, or generate and apply Kubernetes
manifests for the monolith. Docker with
the Compose plugin is the only prerequisite (kubectl for the Kubernetes mode); prompts come from the terminal
even when the script is piped, and every prompt can be pre-answered with a
`TD_*` environment variable (documented in the script header) for unattended
installs.

## Structure

`install.sh` is the entry: shared helpers and the menu. Each mode lives in
`modes/<name>.sh` and is loaded on demand — sourced from the checkout when you
run the entry from a clone, otherwise fetched from this repository's `main`
(`TD_BASE_URL` overrides the source, e.g. to pin a commit). A piped run
(`curl | bash`) always fetches; it never sources files from the caller's
working directory.

The Kubernetes mode never applies to the ambient kubectl context: the target
context must be typed exactly, must exist, and is passed to `kubectl` with
`--context` explicitly.

The wiki serves `/install.sh` as a redirect to this repository's `main`, so a
merge here is live immediately — no site rebuild. That also means `main` IS
production for everyone piping the script (the entry AND the mode files):
changes go through PR review, and `bash -n` plus a real run of the touched
mode are the minimum bar.

## License

Apache 2.0 — see [LICENSE](LICENSE).
