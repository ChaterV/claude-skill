## Before executing: consider delegating to Codex

Once a plan is settled and before you start changing code (including before exiting plan mode), estimate the size of the change. If any of the conditions below applies, use AskUserQuestion to let the user choose between "do it myself" and "delegate to Codex (codex-delegate skill)". Include your reasoning (estimated files/lines changed, how many test or build rounds are needed), and write the question in the user's language.

- Roughly 10+ files or 300+ lines will change
- Repetitive edits across many files where each spot needs contextual judgment and a single script can't do it (e.g. migrating API calls based on how each call site uses them, translating i18n strings)
- Several "run tests/build → fix → rerun" cycles are needed, or the command output is long

Don't ask, just do it yourself, when: the change is only a few files and a few dozen lines; it is a bulk replacement a single sed / script / codemod can do (one or two requests no matter how many files); execution needs frequent judgment calls; it involves high-risk logic (API fields, money/price calculations, permissions, data deletion); or the user has already said who should do it.

Why: delegation has a fixed overhead (writing the brief, opening the pane, reading the result, acceptance checks: about 8 requests, each re-reading the whole context). It only saves tokens when Codex takes on enough execution work; for small changes, delegating costs more.
