# Tracedown installer

The interactive install script served at **https://tracedown.dev/install.sh**:

```bash
curl -fsSL https://tracedown.dev/install.sh | bash
```

It can stand up the [monolith](https://tracedown.dev/install/monolith/)
(everything in one container, plus Postgres and Redis), the full
[per-service stack](https://tracedown.dev/install/deploy/) from the published
release artifacts, or connect a probe agent to an existing stack. Docker with
the Compose plugin is the only prerequisite; prompts come from the terminal
even when the script is piped, and every prompt can be pre-answered with a
`TD_*` environment variable (documented in the script header) for unattended
installs.

The wiki serves `/install.sh` as a redirect to this repository's `main`, so a
merge here is live immediately — no site rebuild. That also means `main` IS
production for everyone piping the script: changes go through PR review, and
`bash -n` plus a real run of the touched mode are the minimum bar.

## License

Apache 2.0 — see [LICENSE](LICENSE).
