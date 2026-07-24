# Security Policy

Gjallarhorn is a web framework. A flaw here is not a flaw in one program — it is a
flaw in every service someone builds on it. We treat reports accordingly, and we
ask you to as well.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion for a security problem.**
A public report is a working exploit against every deployment until a fix ships.

Report privately, either way:

- **GitHub** — open a private advisory on the repository: *Security → Report a
  vulnerability*. This is the preferred path; it keeps the report, the fix, and
  the disclosure in one place.
- **Email** — `mail@johnodonnell.xyz`. Say "Gjallarhorn security" in the subject.
  If you want to encrypt the report, ask for a key in a first, contentless
  message.

A useful report includes:

- the affected component (server, PostgreSQL wire client, Mímir, Loom, sessions,
  the outbound `fetch` client, the CLI) and the commit or AUR version;
- what an attacker can do with it — the impact, not just the defect;
- the smallest reproduction you can manage: a request, a payload, a short handler,
  or a failing test;
- your assessment of severity, and any suggested fix if you have one.

Good-faith security research is welcome. Reporting a flaw is never itself a
violation of the project's community standards, and we will not pursue a reporter
who acts in good faith and gives us a chance to fix the problem before disclosing
it.

## What to expect

- **Acknowledgement** within 3 business days that the report reached a human.
- **An initial assessment** — severity, whether we can reproduce it, and a rough
  fix timeline — within 7 days.
- **A fix developed in private**, with a regression test that would have caught
  the flaw, on a branch that is not publicly linked to the report.
- **Coordinated disclosure.** We aim to ship a patched build and a public advisory
  together, and to credit you by name unless you ask us not to. The target is a
  fix within 90 days of the report; we will tell you if something forces that to
  move, and we would rather coordinate a date with you than surprise you.

If a report goes quiet on our end past these windows, send a reminder — a missed
reply is an oversight, not a decision.

## Supported versions

Gjallarhorn is pre-1.0 and has no tagged releases yet. Security fixes land on the
`main` branch and publish to the AUR (`gjallarhorn-git`) on the next push.

Until a `1.0` tag exists, **only the latest `main` commit is supported.** If you
run it in production, vendor a specific commit you have reviewed and track `main`
for security fixes. When tagged releases begin, this section will name the
versions that receive backported fixes.

## Scope

**In scope** — anything in this repository: the HTTP/1.1 server, routing and
middleware ("runes"), sessions and wards, the hand-rolled PostgreSQL v3 wire
client and SCRAM-SHA-256 auth, the Mímir ORM, the Loom template engine, the
outbound `fetch` client, and the CLI.

**Out of scope** — application code you write on top of the framework; your
deployment, reverse proxy, and TLS termination; the Odin toolchain and the C
libraries behind opt-in backends (`libsqlite3` under `-define:GJ_SQLITE`, the TLS
backend under `-define:GJ_TLS`) — report those to their own projects. Resource
limits an operator is expected to set (see hardening, below) are a shared
responsibility: report a case where the framework makes a documented limit
impossible to enforce, not the absence of a limit you did not configure.

## Security posture

The framework is built from primitives on purpose, so the whole surface can be
read and audited. What that has produced so far:

- multiple full-repository audits, with the findings and their fixes in the public
  commit history — a defect found, a fix, and a test added, each traceable;
- AddressSanitizer sweeps over the feature surface, last clean after the most
  recent round of fixes;
- defensive defaults where they belong: parameterized queries throughout Mímir,
  HTML auto-escaping on by default in Loom, Argon2id for passwords, constant-time
  verification of signed sessions, CR/LF stripping at the header and cookie write,
  request-smuggling defenses in the framer (CL+TE rejected, non-canonical lengths
  rejected), and a refuse-to-start guard on a missing or default session secret.

What it has **not** had: an independent third-party audit. Treat the project as
what it is — a young, self-audited framework whose author publishes his own
findings. That transparency is the point; it is not a substitute for external
review, and these reports help close that gap.

## Deployment hardening

Guidance for running Gjallarhorn on an untrusted network. Most of these are the
operator's call, not the framework's default:

- **Terminate TLS at a reviewed reverse proxy.** The built-in TLS path is
  experimental and gated behind `-define:GJ_TLS`; it is not the recommended way to
  face the public internet. Let a proxy you trust handle TLS and pass through.
- **Put a proxy in front for timeouts and connection limits.** The worker pool is
  bounded, which is not by itself a defense against slow or abusive clients. Set
  request timeouts and connection caps at the edge.
- **Set a request body limit** (`Config.max_body`) sized to what your handlers
  actually accept, and validate untrusted input before you parse it.
- **Treat outbound `fetch` targets as untrusted.** The client does not restrict
  loopback, link-local, metadata, or private address ranges. Never pass a
  user-controlled URL to it without your own allowlist.
- **Keep the OpenAPI docs off in production** — they are disabled by default. If
  you expose `/api-docs` or `/metrics`, authenticate them at the proxy: they are
  not behind your route guards.
- **Serve static files from a directory that holds only what you mean to publish.**
  Be aware of symlinks and dotfiles inside that root.

## Recognition

Reporters who follow this policy are credited by name in the advisory and the
release notes for the fix, unless they ask to remain anonymous. There is no paid
bounty program. What we offer is a fast, honest response and public credit for
making the framework — and everything built on it — safer.
