///|
/// A header belonging to one multipart body part. Header names are preserved
/// as received; use `Part::header` for case-insensitive lookup.
pub(all) struct Header {
  name : String
  value : String
} derive(Debug, Eq)

///|
/// One decoded multipart body part. `body` is text in this first core API;
/// the parser never interprets its contents.
pub(all) struct Part {
  headers : Array[Header]
  body : String
} derive(Debug, Eq)

///|
/// Errors reported when a multipart body is malformed or exceeds its limit.
pub(all) suberror MultipartError {
  InvalidBoundary
  BodyTooLarge(Int)
  MissingOpeningBoundary
  MissingHeaderTerminator
  InvalidHeader(String)
  MissingClosingBoundary
  UnexpectedBoundary
} derive(Debug)

///|
/// An incremental multipart collector. Chunks may be supplied at arbitrary
/// boundaries; parsing happens on `finish` so a delimiter split across chunks
/// is handled exactly like an unsplit delimiter.
pub(all) struct Parser {
  boundary : String
  max_body_size : Int
  mut buffer : String
  mut failed : MultipartError?
}

///|
/// Creates a parser for the supplied boundary. The boundary must be the raw
/// value from the Content-Type parameter, without the leading `--`.
pub fn Parser::new(
  boundary : String,
  max_body_size? : Int = 8_388_608,
) -> Parser {
  Parser::{ boundary, max_body_size, buffer: "", failed: None }
}

///|
/// Adds a body chunk. Chunks can be split at any character boundary.
pub fn Parser::feed(
  self : Parser,
  chunk : String,
) -> Result[Unit, MultipartError] {
  match self.failed {
    Some(error) => Err(error)
    None => {
      let next_size = self.buffer.length() + chunk.length()
      if next_size > self.max_body_size {
        let error = MultipartError::BodyTooLarge(self.max_body_size)
        self.failed = Some(error)
        Err(error)
      } else {
        self.buffer = self.buffer + chunk
        Ok(())
      }
    }
  }
}

///|
/// Parses all supplied chunks and returns body parts in wire order.
pub fn Parser::finish(self : Parser) -> Result[Array[Part], MultipartError] {
  match self.failed {
    Some(error) => Err(error)
    None => parse_body(self.boundary, self.buffer)
  }
}

///|
/// Returns a header value using ASCII case-insensitive comparison.
pub fn Part::header(self : Part, name : String) -> String? {
  let target = name.to_lower()
  for header in self.headers {
    if header.name.to_lower() == target {
      return Some(header.value)
    }
  }
  None
}

///|
/// Returns a parameter from Content-Disposition, such as `name` or
/// `filename`. Quoted parameter values are unquoted.
pub fn Part::disposition_parameter(self : Part, parameter : String) -> String? {
  match self.header("content-disposition") {
    None => None
    Some(value) => find_parameter(value, parameter)
  }
}

///|
/// Convenience accessor for the form field name.
pub fn Part::name(self : Part) -> String? {
  self.disposition_parameter("name")
}

///|
/// Convenience accessor for the submitted file name, when present.
pub fn Part::filename(self : Part) -> String? {
  self.disposition_parameter("filename")
}

///|
/// Encodes parts as a multipart body using the supplied boundary.
pub fn encode(boundary : String, parts : Array[Part]) -> String {
  let mut output = ""
  for part in parts {
    output = output + "--" + boundary + "\r\n"
    for header in part.headers {
      output = output + header.name + ": " + header.value + "\r\n"
    }
    output = output + "\r\n" + part.body + "\r\n"
  }
  output + "--" + boundary + "--\r\n"
}

///|
fn parse_body(
  boundary : String,
  body : String,
) -> Result[Array[Part], MultipartError] {
  guard boundary.length() > 0 &&
    !boundary.contains("\r") &&
    !boundary.contains("\n") else {
    return Err(MultipartError::InvalidBoundary)
  }
  let opening = "--" + boundary + "\r\n"
  guard body.has_prefix(opening) else {
    return Err(MultipartError::MissingOpeningBoundary)
  }
  let marker = "\r\n--" + boundary
  let parts : Array[Part] = []
  for cursor = opening.length() {
    let remaining = body[cursor:].to_owned()
    guard remaining.find("\r\n\r\n") is Some(header_offset) else {
      return Err(MultipartError::MissingHeaderTerminator)
    }
    let header_text = remaining[:header_offset].to_owned()
    let headers = match parse_headers(header_text) {
      Ok(parsed) => parsed
      Err(error) => return Err(error)
    }
    let content_start = cursor + header_offset + 4
    guard find_delimiter(body, marker, content_start)
      is Some((content_end, after_marker)) else {
      return Err(MultipartError::MissingClosingBoundary)
    }
    parts.push(Part::{
      headers,
      body: body[content_start:content_end].to_owned(),
    })
    let suffix = body[after_marker:].to_owned()
    if suffix.has_prefix("--") {
      let tail = suffix[2:].to_owned()
      if tail == "" || tail == "\r\n" {
        return Ok(parts)
      }
      return Err(MultipartError::UnexpectedBoundary)
    }
    if suffix.has_prefix("\r\n") {
      continue after_marker + 2
    }
    return Err(MultipartError::UnexpectedBoundary)
  }
}

///|
/// Finds the next syntactically valid delimiter. A body may legally contain a
/// marker-like byte sequence when it is not followed by CRLF or `--`, so that
/// sequence must remain part of the part body.
fn find_delimiter(body : String, marker : String, start : Int) -> (Int, Int)? {
  for scan = start {
    let remaining = body[scan:].to_owned()
    guard remaining.find(marker) is Some(offset) else { return None }
    let delimiter_start = scan + offset
    let after_marker = delimiter_start + marker.length()
    let suffix = body[after_marker:].to_owned()
    if suffix.has_prefix("--") || suffix.has_prefix("\r\n") {
      return Some((delimiter_start, after_marker))
    }
    continue after_marker
  }
}

///|
fn parse_headers(text : String) -> Result[Array[Header], MultipartError] {
  let headers : Array[Header] = []
  for line in text.split("\r\n") {
    let source = line.to_owned()
    guard source.split_once(":") is Some((name, value)) else {
      return Err(MultipartError::InvalidHeader(source))
    }
    let normalized_name = name.trim().to_owned()
    guard normalized_name.length() > 0 else {
      return Err(MultipartError::InvalidHeader(source))
    }
    headers.push(Header::{
      name: normalized_name,
      value: value.trim().to_owned(),
    })
  }
  Ok(headers)
}

///|
fn find_parameter(value : String, parameter : String) -> String? {
  let target = parameter.to_lower()
  for segment in value.split(";") {
    let item = segment.trim().to_owned()
    if item.split_once("=") is Some((key, raw_value)) &&
      key.trim().to_owned().to_lower() == target {
      let candidate = raw_value.trim().to_owned()
      if candidate.length() >= 2 &&
        candidate.has_prefix("\"") &&
        candidate.has_suffix("\"") {
        return Some(candidate[1:candidate.length() - 1].to_owned())
      }
      return Some(candidate)
    }
  }
  None
}
