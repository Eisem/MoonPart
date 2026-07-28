# Contributing to MoonPart

MoonPart welcomes focused fixes, tests, documentation, and API proposals.

## Development setup

Install a stable MoonBit toolchain, clone the repository, and run:

```sh
moon info
moon fmt
moon check --target all
moon build --target all
moon test --target all
moon coverage analyze
```

The runnable example is available through `moon run cmd/main`; native benchmark
baselines are available through `moon bench --target native`.

## Change workflow

1. Open an Issue for behavior changes or public API proposals.
2. Keep each commit meaningful and describe the user-visible reason.
3. Add black-box tests for public behavior and white-box tests only for
   implementation details that cannot be covered through the public API.
4. Run `moon info && moon fmt` last. Generated `.mbti` files must only change
   when the public interface intentionally changes.
5. Update the README, design notes, and changelog when behavior or boundaries
   change.
6. Open a pull request using the repository template and include the commands
   used to verify the change.

## Compatibility and security

Public interface changes require a SemVer assessment. Parsing changes must
cover fragmented input, binary data, malformed syntax, and configured resource
limits. Do not weaken strict validation without documenting the interoperability
case and its security impact.

Report suspected vulnerabilities according to [SECURITY.md](SECURITY.md).

Contributions are accepted under the repository's Apache-2.0 license.
