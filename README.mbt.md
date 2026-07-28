# MoonPart

MoonPart is a pure MoonBit multipart/form-data core library. It implements a
small, strict RFC 7578-oriented parser and encoder for HTTP form bodies.

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

Run the complete streaming example with:

```sh
moon run cmd/main
```

## Development

```sh
moon fmt
moon test
moon check
moon bench --target native
```

Continuous integration checks formatting and generated interfaces, then builds
and tests the Wasm, Wasm-GC, JavaScript, and native backends. It also runs
MoonBit's coverage analyzer on every push and pull request.

The implementation is original and takes RFC 7578 and RFC 2046 as behavioral
references. It is licensed under Apache-2.0.
