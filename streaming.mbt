///|
/// Internal state of an incremental binary multipart decoder.
enum StreamState {
  AwaitingOpening
  AwaitingHeaders
  ReadingBody
  Done
} derive(Debug)

///|
/// Resource bounds for the incremental decoder. They mirror the limits that
/// production multipart readers use to prevent unbounded header or body
/// buffering.
pub(all) struct StreamLimits {
  max_body_size : Int
  max_part_count : Int
  max_header_size : Int
  max_header_count : Int
  max_part_size : Int
}

///|
pub fn StreamLimits::default() -> StreamLimits {
  StreamLimits::{
    max_body_size: 8_388_608,
    max_part_count: 1_024,
    max_header_size: 16_384,
    max_header_count: 128,
    max_part_size: 8_388_608,
  }
}

///|
/// Incremental multipart decoder. `feed_bytes` emits completed protocol events
/// as soon as they are known, retaining only a short possible-boundary suffix.
pub struct StreamingParser {
  boundary : String
  opening : Bytes
  marker : Bytes
  limits : StreamLimits
  mut pending : Bytes
  mut state : StreamState
  mut received_size : Int
  mut part_count : Int
  mut current_part_size : Int
  mut failed : MultipartError?
}

///|
pub fn StreamingParser::new(boundary : String) -> StreamingParser {
  StreamingParser::with_limits(boundary, StreamLimits::default())
}

///|
/// Creates an incremental decoder with explicit bounds for the complete wire
/// body, each header block, the part count, and each individual part body.
pub fn StreamingParser::with_limits(
  boundary : String,
  limits : StreamLimits,
) -> StreamingParser {
  StreamingParser::{
    boundary,
    opening: @utf8.encode("--" + boundary + "\r\n"),
    marker: @utf8.encode("\r\n--" + boundary),
    limits,
    pending: b"",
    state: AwaitingOpening,
    received_size: 0,
    part_count: 0,
    current_part_size: 0,
    failed: None,
  }
}

///|
/// Creates an incremental decoder from a multipart/form-data Content-Type
/// value, including a quoted boundary parameter.
pub fn StreamingParser::from_content_type(
  content_type : String,
  limits? : StreamLimits = StreamLimits::default(),
) -> Result[StreamingParser, MultipartError] {
  match boundary_from_content_type(content_type) {
    Ok(boundary) => Ok(StreamingParser::with_limits(boundary, limits))
    Err(error) => Err(error)
  }
}

///|
/// Feeds one arbitrary body chunk and returns events now known to be complete.
pub fn StreamingParser::feed_bytes(
  self : StreamingParser,
  chunk : Bytes,
) -> Result[Array[StreamEvent], MultipartError] {
  match self.failed {
    Some(error) => return Err(error)
    None => ()
  }
  guard is_valid_boundary(self.boundary) else {
    let error = MultipartError::InvalidBoundary
    self.failed = Some(error)
    return Err(error)
  }
  let next_size = self.received_size + chunk.length()
  if next_size > self.limits.max_body_size {
    let error = MultipartError::BodyTooLarge(self.limits.max_body_size)
    self.failed = Some(error)
    return Err(error)
  }
  self.received_size = next_size
  if self.state is Done {
    let trailing = concat_bytes(self.pending, chunk)
    if trailing == b"" || trailing == b"\r" || trailing == b"\r\n" {
      self.pending = trailing
      return Ok([])
    }
    let error = MultipartError::UnexpectedBoundary
    self.failed = Some(error)
    return Err(error)
  }
  self.pending = concat_bytes(self.pending, chunk)
  match self.drain([]) {
    Ok(events) => Ok(events)
    Err(error) => {
      self.failed = Some(error)
      Err(error)
    }
  }
}

///|
/// Finishes the stream. A complete body must already have emitted Finished.
pub fn StreamingParser::finish(
  self : StreamingParser,
) -> Result[Array[StreamEvent], MultipartError] {
  match self.failed {
    Some(error) => Err(error)
    None =>
      match self.state {
        AwaitingOpening => Err(MultipartError::MissingOpeningBoundary)
        AwaitingHeaders => Err(MultipartError::MissingHeaderTerminator)
        ReadingBody => Err(MultipartError::MissingClosingBoundary)
        Done =>
          if self.pending.is_empty() || self.pending == b"\r\n" {
            Ok([])
          } else {
            Err(MultipartError::UnexpectedBoundary)
          }
      }
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
      let header_end = match self.pending.find(b"\r\n\r\n") {
        None => {
          if self.pending.length() > self.limits.max_header_size + 3 {
            return Err(
              MultipartError::HeaderTooLarge(self.limits.max_header_size),
            )
          }
          return Ok(events)
        }
        Some(header_end) => {
          if header_end > self.limits.max_header_size {
            return Err(
              MultipartError::HeaderTooLarge(self.limits.max_header_size),
            )
          }
          header_end
        }
      }
      if self.part_count >= self.limits.max_part_count {
        return Err(
          MultipartError::PartCountExceeded(self.limits.max_part_count),
        )
      }
      let headers = match
        parse_headers(
          @utf8.decode_lossy(self.pending.view(end=header_end)),
          max_header_count=self.limits.max_header_count,
        ) {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
      match validate_form_data_headers(headers) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      self.pending = self.pending.view(start=header_end + 4).to_owned()
      self.state = ReadingBody
      self.part_count = self.part_count + 1
      self.current_part_size = 0
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
      let data = self.pending.view(end=emit_end).to_owned()
      match self.emit_part_data(events, data) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      self.pending = self.pending.view(start=emit_end).to_owned()
      Ok(events)
    }
    Some(marker_start) => {
      let after_marker = marker_start + self.marker.length()
      if self.pending.length() < after_marker + 2 {
        if marker_start > 0 {
          let data = self.pending.view(end=marker_start).to_owned()
          match self.emit_part_data(events, data) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
          self.pending = self.pending.view(start=marker_start).to_owned()
        }
        return Ok(events)
      }
      let suffix = self.pending.view(start=after_marker)
      if suffix.has_prefix(b"--") || suffix.has_prefix(b"\r\n") {
        if marker_start > 0 {
          let data = self.pending.view(end=marker_start).to_owned()
          match self.emit_part_data(events, data) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
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
      // The complete marker is known not to be a delimiter. A valid marker
      // cannot begin inside it because boundaries cannot contain CR or LF, so
      // emit it in one step instead of rescanning almost the same bytes.
      let emit_end = after_marker
      let data = self.pending.view(end=emit_end).to_owned()
      match self.emit_part_data(events, data) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      self.pending = self.pending.view(start=emit_end).to_owned()
      self.drain_body(events)
    }
  }
}

///|
fn StreamingParser::emit_part_data(
  self : StreamingParser,
  events : Array[StreamEvent],
  data : Bytes,
) -> Result[Unit, MultipartError] {
  let next_size = self.current_part_size + data.length()
  if next_size > self.limits.max_part_size {
    return Err(MultipartError::PartTooLarge(self.limits.max_part_size))
  }
  self.current_part_size = next_size
  events.push(StreamEvent::PartData(data))
  Ok(())
}

///|
fn concat_bytes(left : Bytes, right : Bytes) -> Bytes {
  if left.is_empty() {
    return right
  }
  if right.is_empty() {
    return left
  }
  let buffer = @buffer.Buffer(size_hint=left.length() + right.length())
  buffer.write_bytes(left[:])
  buffer.write_bytes(right[:])
  buffer.to_bytes()
}
