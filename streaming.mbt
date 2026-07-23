///|
/// Internal state of an incremental binary multipart decoder.
pub(all) enum StreamState {
  AwaitingOpening
  AwaitingHeaders
  ReadingBody
  Done
} derive(Debug)

///|
/// Incremental multipart decoder. `feed_bytes` emits completed protocol events
/// as soon as they are known, retaining only a short possible-boundary suffix.
pub(all) struct StreamingParser {
  boundary : String
  opening : Bytes
  marker : Bytes
  mut pending : Bytes
  mut state : StreamState
}

///|
pub fn StreamingParser::new(boundary : String) -> StreamingParser {
  StreamingParser::{
    boundary,
    opening: @utf8.encode("--" + boundary + "\r\n"),
    marker: @utf8.encode("\r\n--" + boundary),
    pending: b"",
    state: AwaitingOpening,
  }
}

///|
/// Feeds one arbitrary body chunk and returns events now known to be complete.
pub fn StreamingParser::feed_bytes(
  self : StreamingParser,
  chunk : Bytes,
) -> Result[Array[StreamEvent], MultipartError] {
  guard is_valid_boundary(self.boundary) else {
    return Err(MultipartError::InvalidBoundary)
  }
  self.pending = concat_bytes(self.pending, chunk)
  self.drain([])
}

///|
/// Finishes the stream. A complete body must already have emitted Finished.
pub fn StreamingParser::finish(
  self : StreamingParser,
) -> Result[Array[StreamEvent], MultipartError] {
  match self.state {
    Done =>
      if self.pending.is_empty() || self.pending == b"\r\n" {
        Ok([])
      } else {
        Err(MultipartError::UnexpectedBoundary)
      }
    _ => Err(MultipartError::MissingClosingBoundary)
  }
}

///|
fn StreamingParser::drain(
  self : StreamingParser,
  events : Array[StreamEvent],
) -> Result[Array[StreamEvent], MultipartError] {
  match self.state {
    AwaitingOpening => {
      if self.pending.length() < self.opening.length() {
        return Ok(events)
      }
      guard self.pending.has_prefix(self.opening[:]) else {
        return Err(MultipartError::MissingOpeningBoundary)
      }
      self.pending = self.pending.view(start=self.opening.length()).to_owned()
      self.state = AwaitingHeaders
      self.drain(events)
    }
    AwaitingHeaders => {
      guard self.pending.find(b"\r\n\r\n") is Some(header_end) else {
        return Ok(events)
      }
      let headers = match
        parse_headers(@utf8.decode_lossy(self.pending.view(end=header_end))) {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
      match validate_form_data_headers(headers) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      self.pending = self.pending.view(start=header_end + 4).to_owned()
      self.state = ReadingBody
      events.push(StreamEvent::PartBegin(headers))
      self.drain(events)
    }
    ReadingBody => self.drain_body(events)
    Done => Ok(events)
  }
}

///|
fn StreamingParser::drain_body(
  self : StreamingParser,
  events : Array[StreamEvent],
) -> Result[Array[StreamEvent], MultipartError] {
  match self.pending.find(self.marker[:]) {
    None => {
      let keep = self.marker.length() - 1
      if self.pending.length() <= keep {
        return Ok(events)
      }
      let emit_end = self.pending.length() - keep
      events.push(
        StreamEvent::PartData(self.pending.view(end=emit_end).to_owned()),
      )
      self.pending = self.pending.view(start=emit_end).to_owned()
      Ok(events)
    }
    Some(marker_start) => {
      let after_marker = marker_start + self.marker.length()
      if self.pending.length() < after_marker + 2 {
        if marker_start > 0 {
          events.push(
            StreamEvent::PartData(
              self.pending.view(end=marker_start).to_owned(),
            ),
          )
          self.pending = self.pending.view(start=marker_start).to_owned()
        }
        return Ok(events)
      }
      let suffix = self.pending.view(start=after_marker)
      if suffix.has_prefix(b"--") || suffix.has_prefix(b"\r\n") {
        if marker_start > 0 {
          events.push(
            StreamEvent::PartData(
              self.pending.view(end=marker_start).to_owned(),
            ),
          )
        }
        self.pending = self.pending.view(start=after_marker + 2).to_owned()
        events.push(StreamEvent::PartEnd)
        if suffix.has_prefix(b"--") {
          self.state = Done
          events.push(StreamEvent::Finished)
          return Ok(events)
        }
        self.state = AwaitingHeaders
        return self.drain(events)
      }
      let emit_end = marker_start + 1
      events.push(
        StreamEvent::PartData(self.pending.view(end=emit_end).to_owned()),
      )
      self.pending = self.pending.view(start=emit_end).to_owned()
      self.drain_body(events)
    }
  }
}

///|
fn concat_bytes(left : Bytes, right : Bytes) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_bytes(left[:])
  buffer.write_bytes(right[:])
  buffer.to_bytes()
}
