# Contributing to Gjallarhorn

Gjallarhorn is a batteries-included web framework written in Odin, built directly
on `core:net` with the load-bearing parts hand-rolled: the HTTP/1.1 server, the
PostgreSQL wire client, the ORM (Mímir), and the template engine (Loom). The point
of the project is that you can read the whole thing and trust it because you read
it. Contributions are held to that standard.

Before you start, read two documents:

- **`COMMUNITY.md`** — how we work together and what's expected.
- **`SECURITY.md`** — how to report a vulnerability. **Security bugs do not go in
  issues or pull requests.** If a change has security impact, that's the front
  door.

## Before you build

You will need:

- **Odin.** The project is pre-1.0 and tracks a specific toolchain; Odin ships
  breaking changes, so build against the version the repo targets (the pin in
  `.odin-version` when present) rather than whatever is newest. Uncompiled code is
  untested — say so if you haven't run it.
- **PostgreSQL**, to run the full test suite. Tests that need a live database skip
  cleanly when none is present, so you can work without it — but a change to the
  wire client, Mímir, or anything touching SQL is not verified until it has run
  against real Postgres.

The authoritative list of build and test commands is the CI workflow under
`.github/workflows`. Match locally what CI runs; if your change passes there, it
passes. In broad strokes:

- build the sample app in debug and release (`odin build .`, and again with
  `-o:speed`);
- run the tests (`odin test .`), and again with `-define:GJ_SQLITE=true` — CI runs
  both, so both must be green;
- for anything touching memory, lifetimes, or the arena, sweep it with
  `-sanitize:address` before you send it. This project has shipped a
  use-after-free that only ASan caught; the sweep is not optional for that class
  of change.

## The rule that matters most: dependencies

**The default build has zero dependencies, and that is a feature people rely on.**
Adding one is a design decision, not a convenience — the burden is on the change to
justify the dependency, not on the reviewer to justify refusing it.

If a dependency is genuinely warranted, the right shape is almost always an
**opt-in, compile-gated backend**, the way SQLite lives behind
`-define:GJ_SQLITE=true` and TLS behind `-define:GJ_TLS`. The default build stays
clean; the dependency is something a user chooses, loudly, with a flag. Propose it
in an issue before you build on it.

This follows from DDI's engineering standards (`DDI-ENG-001`): a third-party
dependency is itself exception-worthy. When in doubt, hand-roll it or ask.

## Code conventions

Odin has hard constraints. These are not style preferences — the language enforces
most of them, and the framework's design is shaped around them:

- **No methods, no UFCS.** Free procedures that take their data explicitly by
  pointer: `get(app: ^App, ...)`, never `app.Get(...)`.
- **No closures.** Thread callback state through a struct — the way the middleware
  cursor rides on the Bifrost.
- **Errors are values.** Multiple returns with `or_return` / `or_else`. No
  exceptions, no panic-as-control-flow.
- **Memory is lifetimes, managed by hand.** Prefer arenas. The per-request arena is
  the worker's `temp_allocator`, reclaimed with `free_all`. If you allocate
  something that outlives the request, know exactly where it's freed.
- **One directory is one package.**
- **Make illegal states unrepresentable.** Enums and tagged unions over
  stringly-typed data.

Naming:

- procedures and variables `snake_case`; types `Ada_Case`; packages lowercase;
- follow the Google style guides, per `DDI-ENG-001`;
- **stay in the Norse lexicon.** New infrastructure names come from the same well.
  The request/response object is the **Bifrost** — never "Context." The current
  vocabulary:

  | Name | What it is |
  |---|---|
  | Gjallarhorn | the framework (Heimdall's horn) |
  | Bifrost | the request/response object |
  | rune | middleware / module registration |
  | ward | a route auth guard / validation |
  | Loom | the template engine |
  | Mímir | the ORM |
  | Well / `query_well` | database access |
  | hail | static file serving |

  If you add a component, name it on-theme and say why in the pull request.

## Security expectations for every change

The framework owns the trust boundary, so every contributor works with a security
lens on:

- **Parameterized queries, always.** Never assemble SQL from untrusted strings.
- **Leave Loom's auto-escaping on.** Disabling it anywhere needs a written
  justification in the code.
- **Validation is where trust starts. Encryption is not authentication.** Don't
  conflate the two.
- **Don't fabricate.** Never invent an Odin API, claim a behavior you haven't
  compiled and run, or assert a security property you haven't checked. An honest
  "I haven't verified this yet" is worth more than a confident guess.

## Tests

- **A fix ships with the test that would have caught it.** A feature ships with the
  test that proves it works. "Passes on my machine" is not a state anyone else can
  reproduce.
- Run the suite in both default and `GJ_SQLITE` modes. Both are green in CI and
  must stay that way.
- Put tests in `tests/`, named for what they cover (the repo's existing
  `*_test.odin` files are the pattern).
- A change to SQL types, the wire client, or Mímir needs to round-trip against real
  Postgres, not just synthetic rows.

## Commits and pull requests

**Small, honest history beats a tidy lie.** A commit series that shows a defect
found, a fix, and a test added is worth more than one squashed commit that hides
the reasoning. The audit-and-remediation history of this project is public on
purpose — it is the strongest evidence the framework has that it can be trusted,
and your commits become part of that record. Don't flatten the story out of it.

For a pull request:

- **One logical change per PR.** Unrelated cleanups go in their own.
- **Explain the why, not just the what.** The diff shows what changed; the
  description is for the reasoning, the alternatives you rejected, and how you
  verified it. Link the issue it closes.
- **Show that it runs.** Note the build modes you compiled, the tests you ran, and
  the ASan result if the change warrants it.
- Keep the working tree clean — no stray generated files, no commented-out code
  left as a monument.
- Propose anything large — a new subsystem, a change to a public API, a new
  dependency — in an issue first. A PR is the wrong place to discover the design is
  contested.

## Filing issues

- **Bugs:** the smallest reproduction you can manage, the commit or AUR version, the
  build mode, and what you expected versus what happened.
- **Features and design changes:** open an issue and make the case before writing
  the code. It saves you building something the project won't take.
- **Security problems:** not here. See `SECURITY.md`.

## Scope and the maintainer's call

Gjallarhorn is a small project with a clear direction. The maintainers decide what
is in scope, and "no, and here's why" is a legitimate and common answer — usually
about keeping the framework small and readable, not about the quality of your work.
Disagree with reasons; accept the decision once it's made. The goal is a framework
that stays small enough that one person can still hold all of it in their head.

## Licensing

Contributions are made under the repository's `LICENSE`. By opening a pull request,
you confirm you wrote the change (or have the right to contribute it) and are
offering it under that license.
