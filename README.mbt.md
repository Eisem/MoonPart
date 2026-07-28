# MoonPart

[![CI](https://github.com/Eisem/MoonPart/actions/workflows/ci.yml/badge.svg)](https://github.com/Eisem/MoonPart/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

MoonPart is a pure MoonBit multipart/form-data core library. It implements a
small, strict RFC 7578-oriented parser and encoder for HTTP form bodies.

## Installation

After the `0.1.0` release is published to mooncakes.io:

```sh
moon add eisem/moonpart@0.1.0
```

Before publication, clone this repository and run the example and tests from
the repository root.

## Current status

The library includes both a convenient text collector and `StreamingParser`, a
byte-preserving event parser. `StreamingParser::feed_bytes` accepts arbitrary
network chunks and emits `PartBegin`, `PartData`, `PartEnd`, and `Finished`
events as soon as they are known. It keeps only a possible-boundary suffix,
rather than retaining whole uploaded files.

`StreamLimits` bounds the complete wire body, header blocks, number of parts,
and each part body. This is suitable for HTTP handlers that must reject hostile
or accidental oversized uploads early.

Each decoded `Part` retains headers and exposes `name`, `filename`, `is_file`,
and `content_type` convenience accessors. Missing part Content-Type values use
the RFC 7578 `text/plain` default.

For uploaded files, prefer `decode_bytes`. It returns `StreamEvent` values and
keeps every part body as `Bytes`, so arbitrary binary data is preserved:

```mbt check
///|
test "read a binary file field" {
  let body = b"--bin\r\nContent-Disposition: form-data; name=\"file\"; filename=\"raw.bin\"\r\n\r\n\x00\xff\r\n--bin--\r\n"
  match @moonpart.decode_bytes("bin", body) {
    Ok(
      [
        @moonpart.StreamEvent::PartBegin(_),
        @moonpart.StreamEvent::PartData(data),
        ..,
      ]
    ) => assert_eq(data.length(), 2)
    _ => fail("invalid multipart body")
  }
}
```

## Example

```mbt check
///|
test "parse one field" {
  let parser = @moonpart.Parser::new("MyBoundary")
  ignore(
    parser.feed(
      "--MyBoundary\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nMoonBit\r\n--MyBoundary--\r\n",
    ),
  )
  match parser.finish() {
    Ok(parts) => println(parts[0].body)
    Err(_) => println("invalid multipart body")
  }
}
```

## Streaming an upload

```mbt check
///|
test "handle an upload incrementally" {
  let parser = @moonpart.StreamingParser::from_content_type(
    "multipart/form-data; boundary=upload",
  )
  guard parser is Ok(parser) else { fail("invalid content type") }
  let chunks = [
    b"--upload\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n\r\nabc",
    b"\r\n--upload--\r\n",
  ]
  for chunk in chunks {
    guard parser.feed_bytes(chunk) is Ok(events) else {
      fail("invalid multipart body")
    }
    for event in events {
      match event {
        @moonpart.StreamEvent::PartData(data) =>
          // Write data to a file, socket, or other application sink here.
          assert_true(data.length() > 0)
        _ => ()
      }
    }
  }
  assert_true(parser.finish() is Ok(_))
}
```

For small forms, feed the same events to `FormDataCollector`; it preserves the
wire order and repeated field names while exposing text fields and raw file
bytes. Its configurable per-part memory limit makes its buffering explicit.

Submitted filenames are untrusted input. `filename_basename` removes Unix and
Windows directory components, but applications should still generate their own
server-side storage paths rather than writing directly to a submitted name.

For large uploads, use `StreamingFormCollector`. Its callback receives
`FileSinkEvent::Begin`, incremental `Data(Bytes)` chunks, and `End`. The
collector retains text fields and file metadata only; applications can forward
file chunks directly to a filesystem, object store, hash function, or network
sink without constructing the complete file in memory.

`StreamingFormDecoder` connects content-type boundary parsing, incremental body
decoding, limits, field validation, and sink delivery behind one `feed_bytes`
API for HTTP handlers.

Use `FieldSizeLimit` when a specific field needs a stricter cap than the global
text or file limit, for example a short `title` alongside a larger `asset`.

## Choosing an API

| Use case | API | Body storage |
| --- | --- | --- |
| Small text-oriented forms | `Parser` | Complete body as `String` |
| Binary body decoded at once | `decode_bytes` | Events contain raw `Bytes` |
| Incremental protocol parsing | `StreamingParser` | Possible-boundary suffix only |
| Small forms collected in memory | `FormDataCollector` | Text and file bodies |
| Large files sent to a sink | `StreamingFormDecoder` | Text fields and file metadata |

Run the complete streaming example with:

```sh
moon run cmd/main
```

## Scope and non-goals

MoonPart owns multipart/form-data boundary parsing, strict part-header parsing,
encoding, resource limits, form collection, and sink-oriented file delivery.
It deliberately does not provide an HTTP server/client, asynchronous filesystem
I/O, temporary-file management, MIME sniffing, antivirus scanning, or trusted
storage paths. Integrations should supply request chunks and decide how emitted
file bytes are persisted.

The current release targets RFC 7578 form-data behavior. It is not a general
recursive MIME message parser and does not decode content-transfer encodings.

## Security

All limits should be selected for the surrounding HTTP service. Submitted
filenames, media types, headers, and text values remain untrusted. See
[SECURITY.md](SECURITY.md) for the supported security model and vulnerability
reporting process.

## Development

```sh
moon fmt
moon info
moon check --target all
moon build --target all
moon test --target all
moon coverage analyze
moon bench --target native
moon run cmd/main
```

Continuous integration checks formatting and generated interfaces, then builds
and tests the Wasm, Wasm-GC, JavaScript, and native backends. It also runs
MoonBit's coverage analyzer on every push and pull request.

The implementation design is documented in [docs/DESIGN.md](docs/DESIGN.md).
See [CONTRIBUTING.md](CONTRIBUTING.md) for the change workflow and
[CHANGELOG.md](CHANGELOG.md) for release notes. The latest reproducible
competition checklist is in [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md).

The implementation is original and takes RFC 7578 and RFC 2046 as behavioral
references. It is licensed under Apache-2.0.
