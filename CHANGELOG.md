# Changelog

All notable changes to MoonPart are documented here. The project follows
Semantic Versioning.

## [Unreleased]

### Added

- Streaming multipart parsing with arbitrary chunk boundaries.
- Binary-preserving `Bytes` events and whole-body decoding.
- Strict multipart header and Content-Disposition validation.
- Configurable body, part, header, field, and file limits.
- In-memory form collection with repeated-field support.
- Sink-oriented file streaming and an end-to-end streaming form decoder.
- Per-field size limits and allowed-field validation.
- Runnable example, benchmark baselines, multi-backend tests, and CI.

### Changed

- Seal parser, collector, and decoder state behind their public methods.
- Parse and cache form-part metadata once per part instead of once per chunk.

### Security

- Reject ambiguous duplicate `Content-Disposition` headers.
- Reject duplicate `Content-Type` headers and repeated MIME parameters such as
  `boundary`, `name`, and `filename`.
- Reject malformed quoted and unquoted MIME parameter syntax.
- Reject malformed header names, values, and line folding.
- Strip submitted filename path components through an explicit helper.

[Unreleased]: https://github.com/Eisem/MoonPart/compare/v0.1.0...HEAD
