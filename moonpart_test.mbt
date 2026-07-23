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
