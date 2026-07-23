///|
/// Events emitted by the binary multipart decoder. Part bodies remain Bytes,
/// so file contents are never decoded as text.
pub(all) enum StreamEvent {
  PartBegin(Array[Header])
  PartData(Bytes)
  PartEnd
  Finished
} derive(Debug)

///|
/// Decodes a complete multipart body into binary-preserving events. This is
/// the one-shot companion to the upcoming incremental byte state machine.
pub fn decode_bytes(
  boundary : String,
  body : Bytes,
) -> Result[Array[StreamEvent], MultipartError] {
  guard is_valid_boundary(boundary) else {
    return Err(MultipartError::InvalidBoundary)
  }
  let opening = @utf8.encode("--" + boundary + "\r\n")
  guard body.has_prefix(opening[:]) else {
    return Err(MultipartError::MissingOpeningBoundary)
  }
  let marker = @utf8.encode("\r\n--" + boundary)
  let events : Array[StreamEvent] = []
  for cursor = opening.length() {
    let remaining = body.view(start=cursor)
    guard remaining.find(b"\r\n\r\n") is Some(header_offset) else {
      return Err(MultipartError::MissingHeaderTerminator)
    }
    let headers = match
      parse_headers(@utf8.decode_lossy(remaining.view(end=header_offset))) {
      Ok(parsed) => parsed
      Err(error) => return Err(error)
    }
    match validate_form_data_headers(headers) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    events.push(StreamEvent::PartBegin(headers))
    let content_start = cursor + header_offset + 4
    guard find_byte_delimiter(body, marker, content_start)
      is Some((content_end, after_marker)) else {
      return Err(MultipartError::MissingClosingBoundary)
    }
    let data = body.view(start=content_start, end=content_end).to_owned()
    if !data.is_empty() {
      events.push(StreamEvent::PartData(data))
    }
    events.push(StreamEvent::PartEnd)
    let suffix = body.view(start=after_marker)
    if suffix.has_prefix(b"--") {
      let tail = suffix.view(start=2)
      if tail.length() == 0 || tail.equal_to_bytes(b"\r\n") {
        events.push(StreamEvent::Finished)
        return Ok(events)
      }
      return Err(MultipartError::UnexpectedBoundary)
    }
    if suffix.has_prefix(b"\r\n") {
      continue after_marker + 2
    }
    return Err(MultipartError::UnexpectedBoundary)
  }
}

///|
fn find_byte_delimiter(
  body : Bytes,
  marker : Bytes,
  start : Int,
) -> (Int, Int)? {
  for scan = start {
    let remaining = body.view(start=scan)
    guard remaining.find(marker[:]) is Some(offset) else { return None }
    let delimiter_start = scan + offset
    let after_marker = delimiter_start + marker.length()
    let suffix = body.view(start=after_marker)
    if suffix.has_prefix(b"--") || suffix.has_prefix(b"\r\n") {
      return Some((delimiter_start, after_marker))
    }
    continue after_marker
  }
}
