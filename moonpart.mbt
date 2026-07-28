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
  InvalidContentType
  BodyTooLarge(Int)
  MissingOpeningBoundary
  MissingHeaderTerminator
  InvalidHeader(String)
  MissingContentDisposition
  InvalidContentDisposition
  MissingFieldName
  HeaderTooLarge(Int)
  HeaderCountExceeded(Int)
  PartCountExceeded(Int)
  PartTooLarge(Int)
  InvalidStreamEvent
  FileTooLarge(Int)
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
  max_part_count : Int
  max_header_size : Int
  max_header_count : Int
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
  Parser::{
    boundary,
    max_body_size,
    max_part_count: 1_024,
    max_header_size: 16_384,
    max_header_count: 128,
    buffer: "",
    failed: None,
  }
}

///|
/// Creates a parser with explicit resource limits. The parser rejects a body
/// once any configured bound is exceeded.
pub fn Parser::with_limits(
  boundary : String,
  max_body_size? : Int = 8_388_608,
  max_part_count? : Int = 1_024,
  max_header_size? : Int = 16_384,
  max_header_count? : Int = 128,
) -> Parser {
  Parser::{
    boundary,
    max_body_size,
    max_part_count,
    max_header_size,
    max_header_count,
    buffer: "",
    failed: None,
  }
}

///|
/// Creates a parser directly from an HTTP Content-Type value.
pub fn Parser::from_content_type(
  content_type : String,
  max_body_size? : Int = 8_388_608,
) -> Result[Parser, MultipartError] {
  match boundary_from_content_type(content_type) {
    Ok(boundary) => Ok(Parser::new(boundary, max_body_size~))
    Err(error) => Err(error)
  }
}

///|
/// Extracts and validates the boundary parameter from a multipart/form-data
/// Content-Type header. Quoted boundary values are accepted.
pub fn boundary_from_content_type(
  content_type : String,
) -> Result[String, MultipartError] {
  guard content_type.split_once(";") is Some((media_type, parameters)) else {
    return Err(MultipartError::InvalidContentType)
  }
  guard media_type.trim().to_owned().to_lower() == "multipart/form-data" else {
    return Err(MultipartError::InvalidContentType)
  }
  let parameter_text = parameters.to_owned()
  guard find_parameter(parameter_text, "boundary") is Some(boundary) else {
    return Err(MultipartError::InvalidContentType)
  }
  guard is_valid_boundary(boundary) else {
    return Err(MultipartError::InvalidBoundary)
  }
  Ok(boundary)
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
    None =>
      parse_body(
        self.boundary,
        self.buffer,
        self.max_part_count,
        self.max_header_size,
        self.max_header_count,
      )
  }
}

///|
/// Returns a header value using ASCII case-insensitive comparison.
pub fn Part::header(self : Part, name : String) -> String? {
  find_header(self.headers, name)
}

///|
fn find_header(headers : Array[Header], name : String) -> String? {
  let target = name.to_lower()
  for header in headers {
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
/// Returns the part media type. RFC 7578 defaults an omitted Content-Type to
/// `text/plain` for form fields.
pub fn Part::content_type(self : Part) -> String {
  match self.header("content-type") {
    Some(value) => value
    None => "text/plain"
  }
}

///|
/// Reports whether this part carries a submitted file name.
pub fn Part::is_file(self : Part) -> Bool {
  self.filename() is Some(_)
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
  max_part_count : Int,
  max_header_size : Int,
  max_header_count : Int,
) -> Result[Array[Part], MultipartError] {
  guard is_valid_boundary(boundary) else {
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
    if header_offset > max_header_size {
      return Err(MultipartError::HeaderTooLarge(max_header_size))
    }
    if parts.length() >= max_part_count {
      return Err(MultipartError::PartCountExceeded(max_part_count))
    }
    let header_text = remaining[:header_offset].to_owned()
    let headers = match parse_headers(header_text, max_header_count~) {
      Ok(parsed) => parsed
      Err(error) => return Err(error)
    }
    match validate_form_data_headers(headers) {
      Ok(_) => ()
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
fn is_valid_boundary(boundary : String) -> Bool {
  guard boundary.length() > 0 && boundary.length() <= 70 else { return false }
  guard !boundary.has_suffix(" ") else { return false }
  for character in boundary {
    let allowed = character.is_ascii_digit() ||
      character.is_ascii_lowercase() ||
      character.is_ascii_uppercase() ||
      character == '\'' ||
      character == '(' ||
      character == ')' ||
      character == '+' ||
      character == '_' ||
      character == ',' ||
      character == '-' ||
      character == '.' ||
      character == '/' ||
      character == ':' ||
      character == '=' ||
      character == '?' ||
      character == ' '
    if !allowed {
      return false
    }
  }
  true
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
fn parse_headers(
  text : String,
  max_header_count? : Int = 128,
) -> Result[Array[Header], MultipartError] {
  let headers : Array[Header] = []
  for line in text.split("\r\n") {
    if headers.length() >= max_header_count {
      return Err(MultipartError::HeaderCountExceeded(max_header_count))
    }
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
fn validate_form_data_headers(
  headers : Array[Header],
) -> Result[Unit, MultipartError] {
  guard find_header(headers, "content-disposition") is Some(disposition) else {
    return Err(MultipartError::MissingContentDisposition)
  }
  let media_type = match disposition.split_once(";") {
    Some((value, _)) => value.trim().to_owned()
    None => disposition.trim().to_owned()
  }
  guard media_type.to_lower() == "form-data" else {
    return Err(MultipartError::InvalidContentDisposition)
  }
  guard find_parameter(disposition, "name") is Some(_) else {
    return Err(MultipartError::MissingFieldName)
  }
  Ok(())
}

///|
fn find_parameter(value : String, parameter : String) -> String? {
  let target = parameter.to_lower()
  let segment = StringBuilder()
  let mut quoted = false
  let mut escaped = false
  for character in value {
    if escaped {
      segment.write_char(character)
      escaped = false
    } else if quoted && character == '\\' {
      segment.write_char(character)
      escaped = true
    } else if character == '\"' {
      quoted = !quoted
      segment.write_char(character)
    } else if character == ';' && !quoted {
      match parameter_from_segment(segment.to_string(), target) {
        Some(result) => return Some(result)
        None => segment.reset()
      }
    } else {
      segment.write_char(character)
    }
  }
  parameter_from_segment(segment.to_string(), target)
}

///|
fn parameter_from_segment(segment : String, target : String) -> String? {
  let item = segment.trim().to_owned()
  if item.split_once("=") is Some((key, raw_value)) &&
    key.trim().to_owned().to_lower() == target {
    let candidate = raw_value.trim().to_owned()
    if candidate.length() >= 2 &&
      candidate.has_prefix("\"") &&
      candidate.has_suffix("\"") {
      return Some(unescape_quoted_value(candidate[1:candidate.length() - 1]))
    }
    return Some(candidate)
  }
  None
}

///|
/// Decodes quoted-string escapes used by MIME parameters. A backslash only
/// escapes the next character; a trailing backslash is retained verbatim.
fn unescape_quoted_value(value : StringView) -> String {
  let output = StringBuilder()
  let mut escaped = false
  for character in value {
    if escaped {
      output.write_char(character)
      escaped = false
    } else if character == '\\' {
      escaped = true
    } else {
      output.write_char(character)
    }
  }
  if escaped {
    output.write_char('\\')
  }
  output.to_string()
}
