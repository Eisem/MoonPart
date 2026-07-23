# MoonPart

MoonPart is a pure MoonBit multipart/form-data core library. It implements a
small, strict RFC 7578-oriented parser and encoder for HTTP form bodies.

## Current status

The initial release provides a text-based incremental collector: call `feed`
with chunks at arbitrary boundaries, then call `finish`. Boundary delimiters
split between chunks are handled correctly. The next milestone is a byte-based
event parser that can stream file contents without retaining full bodies.

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

## Development

```sh
moon fmt
moon test
moon check
```

The implementation is original and takes RFC 7578 and RFC 2046 as behavioral
references. It is licensed under Apache-2.0.
