///|
fn sample_body() -> String {
  "--MoonPartBoundary\r\n" +
  "Content-Disposition: form-data; name=\"title\"\r\n" +
  "\r\n" +
  "MoonBit\r\n" +
  "--MoonPartBoundary\r\n" +
  "Content-Disposition: form-data; name=\"asset\"; filename=\"logo.txt\"\r\n" +
  "Content-Type: text/plain\r\n" +
  "\r\n" +
  "hello from a file\r\n" +
  "--MoonPartBoundary--\r\n"
}

///|
test "parses fields and file metadata" {
  let parser = Parser::new("MoonPartBoundary")
  assert_true(parser.feed(sample_body()) is Ok(_))
  let result = parser.finish()
  guard result is Ok(parts) else { fail("multipart body should parse") }
  assert_eq(parts.length(), 2)
  assert_true(parts[0].name() == Some("title"))
  assert_eq(parts[0].body, "MoonBit")
  assert_eq(parts[0].content_type(), "text/plain")
  assert_false(parts[0].is_file())
  assert_true(parts[1].name() == Some("asset"))
  assert_true(parts[1].filename() == Some("logo.txt"))
  assert_true(parts[1].header("content-type") == Some("text/plain"))
  assert_eq(parts[1].content_type(), "text/plain")
  assert_true(parts[1].is_file())
  assert_eq(parts[1].body, "hello from a file")
}

///|
test "accepts delimiters split across chunks" {
  let source = sample_body()
  for split in 1..<source.length() {
    let parser = Parser::new("MoonPartBoundary")
    assert_true(parser.feed(source[:split].to_owned()) is Ok(_))
    assert_true(parser.feed(source[split:].to_owned()) is Ok(_))
    guard parser.finish() is Ok(parts) else {
      fail("split \{split} should parse")
    }
    assert_eq(parts.length(), 2)
    assert_eq(parts[1].body, "hello from a file")
  }
}

///|
test "encoder round trips parts" {
  let parts = [
    Part::{
      headers: [
        Header::{ name: "Content-Disposition", value: "form-data; name=\"q\"" },
      ],
      body: "moon",
    },
  ]
  let encoded = encode("roundtrip", parts)
  let parser = Parser::new("roundtrip")
  assert_true(parser.feed(encoded) is Ok(_))
  guard parser.finish() is Ok(decoded) else {
    fail("encoded body should parse")
  }
  assert_true(decoded == parts)
}

///|
test "keeps marker-like content that is not a delimiter" {
  let source = "--edge\r\n" +
    "Content-Disposition: form-data; name=\"note\"\r\n" +
    "\r\n" +
    "before\r\n--edgenot-a-delimiter\r\nafter\r\n" +
    "--edge--\r\n"
  let parser = Parser::new("edge")
  assert_true(parser.feed(source) is Ok(_))
  guard parser.finish() is Ok(parts) else {
    fail("marker-like content should not terminate a part")
  }
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].body, "before\r\n--edgenot-a-delimiter\r\nafter")
}

///|
test "rejects body above configured limit" {
  let parser = Parser::new("small", max_body_size=3)
  assert_true(parser.feed("1234") is Err(MultipartError::BodyTooLarge(3)))
  assert_true(parser.finish() is Err(MultipartError::BodyTooLarge(3)))
}

///|
test "extracts a quoted boundary from content type" {
  assert_true(
    boundary_from_content_type(
      "Multipart/Form-Data; charset=utf-8; boundary=\"part-42\"",
    )
    is Ok("part-42"),
  )
  assert_true(
    Parser::from_content_type("multipart/form-data; boundary=edge") is Ok(_),
  )
}

///|
test "rejects content types without a valid boundary" {
  assert_true(
    boundary_from_content_type("application/json")
    is Err(MultipartError::InvalidContentType),
  )
  assert_true(
    boundary_from_content_type("multipart/form-data; boundary=bad\r\nvalue")
    is Err(MultipartError::InvalidBoundary),
  )
}

///|
test "unescapes quoted disposition parameter values" {
  let source = "--quoted\r\n" +
    "Content-Disposition: form-data; name=\"asset\"; filename=\"say \\\"hi\\\".txt\"\r\n" +
    "\r\n" +
    "content\r\n" +
    "--quoted--\r\n"
  let parser = Parser::new("quoted")
  assert_true(parser.feed(source) is Ok(_))
  guard parser.finish() is Ok(parts) else {
    fail("quoted parameters should parse")
  }
  assert_true(parts[0].filename() == Some("say \"hi\".txt"))
}

///|
test "keeps semicolons inside quoted disposition parameters" {
  let source = "--semicolon\r\n" +
    "Content-Disposition: form-data; name=\"asset\"; filename=\"report;final.txt\"\r\n" +
    "\r\n" +
    "content\r\n" +
    "--semicolon--\r\n"
  let parser = Parser::new("semicolon")
  assert_true(parser.feed(source) is Ok(_))
  guard parser.finish() is Ok(parts) else {
    fail("quoted semicolons should parse")
  }
  assert_true(parts[0].filename() == Some("report;final.txt"))
}

///|
test "rejects parts without form-data disposition metadata" {
  let missing_header = "--strict\r\n" +
    "Content-Type: text/plain\r\n\r\n" +
    "content\r\n--strict--\r\n"
  let missing_name = "--strict\r\n" +
    "Content-Disposition: form-data\r\n\r\n" +
    "content\r\n--strict--\r\n"
  let wrong_disposition = "--strict\r\n" +
    "Content-Disposition: attachment; name=\"asset\"\r\n\r\n" +
    "content\r\n--strict--\r\n"
  let parser = Parser::new("strict")
  assert_true(parser.feed(missing_header) is Ok(_))
  assert_true(parser.finish() is Err(MultipartError::MissingContentDisposition))
  let parser = Parser::new("strict")
  assert_true(parser.feed(missing_name) is Ok(_))
  assert_true(parser.finish() is Err(MultipartError::MissingFieldName))
  let parser = Parser::new("strict")
  assert_true(parser.feed(wrong_disposition) is Ok(_))
  assert_true(parser.finish() is Err(MultipartError::InvalidContentDisposition))
}

///|
test "enforces header and part count limits" {
  let source = sample_body()
  let parser = Parser::with_limits("MoonPartBoundary", max_header_size=8)
  assert_true(parser.feed(source) is Ok(_))
  assert_true(parser.finish() is Err(MultipartError::HeaderTooLarge(8)))
  let parser = Parser::with_limits("MoonPartBoundary", max_part_count=1)
  assert_true(parser.feed(source) is Ok(_))
  assert_true(parser.finish() is Err(MultipartError::PartCountExceeded(1)))
}

///|
test "decodes binary file data without text conversion" {
  let source = b"--binary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"raw.bin\"\r\n\r\n\x00\xff\x10\r\n--binary--\r\n"
  guard decode_bytes("binary", source) is Ok(events) else {
    fail("binary multipart body should parse")
  }
  assert_eq(events.length(), 4)
  assert_true(events[0] is StreamEvent::PartBegin(_))
  assert_true(events[1] is StreamEvent::PartData(b"\x00\xff\x10"))
  assert_true(events[2] is StreamEvent::PartEnd)
  assert_true(events[3] is StreamEvent::Finished)
}

///|
test "streams multipart events across arbitrary chunks" {
  let parser = StreamingParser::new("stream")
  let chunks = [
    b"--stream\r\nContent-Dis", b"position: form-data; name=\"file\"; filename=\"a.bin\"\r\n\r\nab",
    b"cdef\r\n--stream--\r\n",
  ]
  let events : Array[StreamEvent] = []
  for chunk in chunks {
    guard parser.feed_bytes(chunk) is Ok(next) else {
      fail("chunk should be accepted")
    }
    for event in next {
      events.push(event)
    }
  }
  assert_true(parser.finish() is Ok(_))
  assert_eq(events.length(), 4)
  assert_true(events[0] is StreamEvent::PartBegin(_))
  assert_true(events[1] is StreamEvent::PartData(b"abcdef"))
  assert_true(events[2] is StreamEvent::PartEnd)
  assert_true(events[3] is StreamEvent::Finished)
}

///|
test "streaming parser preserves binary data at every split point" {
  let source = b"--split\r\nContent-Disposition: form-data; name=\"file\"; filename=\"raw.bin\"\r\n\r\n\x00\xff\x10payload\r\n--split--\r\n"
  let expected = b"\x00\xff\x10payload"
  for split in 1..<source.length() {
    let parser = StreamingParser::new("split")
    let received = @buffer.Buffer()
    let events = [
      parser.feed_bytes(source.view(end=split).to_owned()),
      parser.feed_bytes(source.view(start=split).to_owned()),
    ]
    for result in events {
      guard result is Ok(next) else { fail("split \{split} should parse") }
      for event in next {
        match event {
          StreamEvent::PartData(data) => received.write_bytes(data[:])
          _ => ()
        }
      }
    }
    assert_true(parser.finish() is Ok(_))
    assert_true(received.to_bytes() == expected)
  }
}

///|
test "streaming parser enforces body, header, count, and part limits" {
  let body_limited = StreamingParser::with_limits("limit", StreamLimits::{
    max_body_size: 3,
    max_part_count: 1,
    max_header_size: 64,
    max_part_size: 64,
  })
  assert_true(
    body_limited.feed_bytes(b"1234") is Err(MultipartError::BodyTooLarge(3)),
  )
  let header_limited = StreamingParser::with_limits("limit", StreamLimits::{
    max_body_size: 512,
    max_part_count: 1,
    max_header_size: 8,
    max_part_size: 64,
  })
  assert_true(
    header_limited.feed_bytes(
      b"--limit\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n",
    )
    is Err(MultipartError::HeaderTooLarge(8)),
  )
  let part_limited = StreamingParser::with_limits("limit", StreamLimits::{
    max_body_size: 512,
    max_part_count: 1,
    max_header_size: 64,
    max_part_size: 2,
  })
  assert_true(
    part_limited.feed_bytes(
      b"--limit\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nabc\r\n--limit--\r\n",
    )
    is Err(MultipartError::PartTooLarge(2)),
  )
  let count_limited = StreamingParser::with_limits("limit", StreamLimits::{
    max_body_size: 512,
    max_part_count: 1,
    max_header_size: 64,
    max_part_size: 64,
  })
  assert_true(
    count_limited.feed_bytes(
      b"--limit\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--limit\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--limit--\r\n",
    )
    is Err(MultipartError::PartCountExceeded(1)),
  )
}

///|
test "collects ordered text and file form entries from streaming events" {
  let text_prefix = "--collect\r\n" +
    "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" +
    "first\r\n" +
    "--collect\r\n" +
    "Content-Disposition: form-data; name=\"tag\"\r\n\r\n" +
    "second\r\n" +
    "--collect\r\n" +
    "Content-Disposition: form-data; name=\"asset\"; filename=\"raw.bin\"\r\n" +
    "Content-Type: application/octet-stream\r\n\r\n"
  let source = @buffer.Buffer()
  source.write_utf8(text_prefix)
  source.write_bytes(b"\x00\xff")
  source.write_utf8("\r\n--collect--\r\n")
  let parser = StreamingParser::new("collect")
  guard parser.feed_bytes(source.to_bytes()) is Ok(events) else {
    fail("stream should parse")
  }
  let collector = FormDataCollector::new()
  for event in events {
    assert_true(collector.push(event) is Ok(_))
  }
  guard collector.finish() is Ok(form) else { fail("collector should finish") }
  assert_eq(form.entries.length(), 3)
  match form.entries[0] {
    FormEntry::Text(field) => {
      assert_eq(field.name, "tag")
      assert_eq(field.value, "first")
    }
    _ => fail("first entry should be text")
  }
  match form.entries[1] {
    FormEntry::Text(field) => assert_eq(field.value, "second")
    _ => fail("second entry should be text")
  }
  match form.entries[2] {
    FormEntry::File(file) => {
      assert_eq(file.field_name, "asset")
      assert_eq(file.filename, "raw.bin")
      assert_true(file.data == b"\x00\xff")
    }
    _ => fail("third entry should be a file")
  }
}

///|
test "collector rejects a part that exceeds its memory limit" {
  let collector = FormDataCollector::with_file_size_limit(2)
  let headers = [
    Header::{ name: "Content-Disposition", value: "form-data; name=\"file\"" },
  ]
  assert_true(collector.push(StreamEvent::PartBegin(headers)) is Ok(_))
  assert_true(
    collector.push(StreamEvent::PartData(b"123"))
    is Err(MultipartError::FileTooLarge(2)),
  )
}
