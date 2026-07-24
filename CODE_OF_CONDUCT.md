# Gjallarhorn — Community Standards

Gjallarhorn is a web framework built from primitives: a hand-rolled HTTP/1.1
server, a PostgreSQL wire client, an ORM, and a template engine, with no
dependencies in the default build. People trust it because they can read every
line. That trust is the thing these standards exist to protect — in the code and
in the people who work on it.

This document covers how we treat each other and how we treat the code. It is
short on purpose. If a rule here needs a paragraph of interpretation, it is the
wrong rule.

## Who and where this applies

These standards apply to everyone who takes part in the project — maintainers,
contributors, and anyone passing through — across every official space:

- the GitHub repository: issues, pull requests, discussions, code review, and
  commit messages;
- the AUR package page and its comments;
- the Odin Discord and any other forum when you are discussing or representing
  Gjallarhorn;
- private channels used for project business, including security reports.

If you are speaking as part of this project, you are inside these standards.

## What we value

**Read it before you trust it.** The whole point of a from-primitives framework
is that no claim has to be taken on faith. Hold contributions — including your
own — to that bar. Show the code, show the test, show the run.

**Security is the default, not a feature.** This is a web framework; a careless
change is a vulnerability in someone else's production system. Treat the trust
boundary as real. Parameterized queries always. Validation is where trust
starts. Encryption is not authentication.

**Say what is true, including "I don't know."** Uncompiled code is untested — say
so. An unverified benchmark is not a result — label it. Never invent an API,
attribute a behavior you haven't confirmed, or state a security property you
haven't checked. Fabrication is the one technical failure that erodes trust
faster than a bug.

**Competence comes at every level.** The people who work on this range from
self-taught to career systems engineers. Explain your reasoning, define terms,
and assume good faith about what someone doesn't know yet. A question is not a
failing. Condescension is.

**Write the decision down.** If a choice matters, it belongs in the pull request,
the issue, or a design note — not only in someone's head. Disagreement is
resolved in writing, on the substance.

## Expected conduct

- Engage with the argument, not the person. Technical disagreement is welcome
  and expected; make it about the code.
- Give review that a person can act on: specific, reasoned, and aimed at the
  work.
- Credit others' contributions plainly.
- Respect the maintainers' final call on scope and direction, even when you'd
  have chosen differently. Push back with reasons; accept the decision once
  it's made.
- Keep public spaces usable for the next person reading them.

## Unacceptable conduct

- Harassment, discrimination, or personal attacks — including slurs, sexualized
  language or attention, threats, sustained disruption, or deliberate
  intimidation.
- Publishing someone's private information without their explicit consent.
- Dishonest technical conduct: knowingly submitting insecure code as safe,
  concealing a change's real effect, fabricating benchmarks or API behavior, or
  misrepresenting the project's security posture.
- **Introducing a vulnerability or backdoor on purpose, in any form, under any
  justification.** There is no research framing, test, or lesson that makes this
  acceptable in this project. It is grounds for an immediate and permanent ban.

## Security has its own front door

Because a bug here can be an exploit in a downstream deployment, security
reports do not go through the normal issue tracker.

**Do not open a public issue, pull request, or discussion for a vulnerability
that could be exploited.** A public report is a public exploit before there is a
fix.

Report it privately: use GitHub's private vulnerability reporting on the
repository (Security → Report a vulnerability), or email the maintainer at
`mail@johnodonnell.xyz`. Expect an
acknowledgement, a fix developed in private, and public credit once a patched
release ships — unless you ask to stay anonymous. Full process and disclosure
timeline live in `SECURITY.md`.

Good-faith security research is welcome and valued. Reporting a flaw is never
itself a conduct violation.

## Contributing in good faith

The technical bar is set in `CONTRIBUTING.md`; the parts that are also community
norms:

- **A new dependency is a design decision, not a convenience.** The default
  build has none, and that is a feature people rely on. Propose and discuss any
  dependency before you build on it — an optional, gated backend (the SQLite and
  TLS pattern) is usually the right shape when one is justified at all.
- **Follow the language's grain.** Odin's conventions are the house style: free
  procedures with explicit pointers, errors as values, no closures, arenas for
  lifetimes, and the Norse lexicon for anything new (Bifrost, rune, Loom, Mímir,
  ward). Names stay on-theme.
- **Tests travel with the change.** A fix includes the test that would have
  caught it. A feature includes the test that proves it. "Passes on my machine"
  is not a state anyone else can verify.
- **Small, honest history beats a tidy lie.** A commit series that shows a defect
  found, a fix, and a test added is worth more than a single squashed commit that
  hides the reasoning. The audit and remediation history is public on purpose —
  it is the strongest evidence the project has, and your commits are part of it.

## Reporting a conduct problem

If someone's behavior breaks these standards, tell the maintainer:

- email `mail@johnodonnell.xyz, or
- direct message a maintainer in the Odin Discord.

Reports stay as private as handling them allows. Say what happened, where, and
when; links or screenshots help. Reports are read in good faith, and reporting in
good faith never counts against you — even if, after review, no action follows.

## Enforcement

The maintainers are responsible for these standards and for what happens when
they're broken. This is a small project, so the process is small and direct.
Depending on severity and pattern:

1. **A private word** — a note explaining what was out of line and what to do
   differently. Most things end here.
2. **A warning** — a formal notice, with a defined period of no contact with the
   people involved. Breaking it escalates.
3. **A temporary restriction** — time away from project spaces.
4. **A permanent ban** — for severe conduct, or for continuing after warnings.
   Deliberately introducing a vulnerability, harassment, and threats can start
   here.

Enforcement decisions are recorded privately so that patterns are visible and
handling stays consistent. Maintainers who break these standards are held to
them more strictly, not less.

## Attribution

These standards draw on common open-source community norms, including the
lineage of the Contributor Covenant, adapted to a security-focused systems
project. They are a living document: propose changes the same way you'd propose
a change to the code — in the open, with reasons.
