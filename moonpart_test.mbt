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
  assert_true(parts[1].name() == Some("asset"))
  assert_true(parts[1].filename() == Some("logo.txt"))
  assert_true(parts[1].header("content-type") == Some("text/plain"))
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
