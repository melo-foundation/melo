# Contributing

Bug fixes can go straight to a pull request. For a new feature, open a
[feature request](https://github.com/melo-foundation/melo/issues/new?template=feature_request.yml)
first and wait for a yes before you build it; a large pull request nobody asked
for may be closed without review.

## Building

Build from source as in the [README](README.md#build-from-source). After a QML
change, restart melo. After a C++ change, run `cmake --build build` first.

Test with a scratch config:

```
MELO_CONFIG_DIR=$(mktemp -d) ./build/melo
```

To run a second window on the same config, set `MELO_ALLOW_SECOND_INSTANCE=1`.
Both windows then save to the same `library.v2.json` and `settings.v2.json`, and
the last save wins.

## Checks

CI runs these on every pull request. Run them before you push:

```
cmake --build build -j"$(nproc)" && ctest --test-dir build
pnpm -C sidecar typecheck && pnpm -C sidecar test
scripts/qmllint-plugins.sh
MELO_CONFIG_DIR=$(mktemp -d) QT_QPA_PLATFORM=offscreen ./build/melo --smoke
```

`--smoke` exits non-zero if the window loads with any QML error.

## Pull requests

- One change per pull request.
- Say what was wrong and what the change does. Add a screenshot or a short
  recording for anything visible.
- Add a test for logic that can fail: a branch, a parser, anything that touches
  files or the user's data.
- Comments explain why the code does something.
- A commit message names what broke, what the user saw, and how you checked the
  fix. Include measurements when you have them.

## Style

- A setting shows its label, its value and its options, with no sentence
  explaining it; if a label needs one, rename the label.
- Docs say what to do. Reasons go in code comments and commit messages.
- Sizes go through `Theme`: `Theme.fs()` for text; `Theme.sp()`, `gap()`,
  `ctl()`, `art()` or `bar()` for everything else.
- A change to what a plugin can reach needs a test in
  `tests/cpp/tst_plugincontainment.cpp` or `sidecar/src/plugins/host.test.ts`,
  and a line in `docs/plugins.md`.

## Licence

melo is GPL-3.0-or-later. By opening a pull request you agree your change is
released under it. Submit only code you wrote or have the right to submit; for
code from elsewhere, name its source and licence in the commit message.

## Reporting bugs

Use the
[bug report form](https://github.com/melo-foundation/melo/issues/new?template=bug_report.yml)
and attach the log:

```
journalctl --user -b _COMM=melo -o cat
```

or the output of melo run from a terminal. Report security problems privately,
as described in [SECURITY.md](SECURITY.md).
