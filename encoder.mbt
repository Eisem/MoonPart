///|
enum EncoderState {
  AwaitingPart
  WritingPart
  Encoded
}

///|
/// Incrementally converts multipart events into binary wire chunks. The
/// encoder retains only its state and the boundary; returned chunks can be
/// written directly to an HTTP body sink.
pub struct StreamingEncoder {
  boundary : String
  mut state : EncoderState
  mut failed : MultipartError?
}

///|
/// Creates an encoder for a raw multipart boundary. Invalid boundaries are
/// reported by the first `push` call.
pub fn StreamingEncoder::new(boundary : String) -> StreamingEncoder {
  StreamingEncoder::{
    boundary,
    state: AwaitingPart,
    failed: if is_valid_boundary(boundary) {
      None
    } else {
      Some(MultipartError::InvalidBoundary)
    },
  }
}

///|
/// Creates an encoder from an HTTP multipart/form-data Content-Type value.
pub fn StreamingEncoder::from_content_type(
  content_type : String,
) -> Result[StreamingEncoder, MultipartError] {
  match boundary_from_content_type(content_type) {
    Ok(boundary) => Ok(StreamingEncoder::new(boundary))
    Err(error) => Err(error)
  }
}

///|
/// Returns a Content-Type value suitable for the encoded body.
pub fn StreamingEncoder::content_type(self : StreamingEncoder) -> String {
  "multipart/form-data; boundary=\"" + self.boundary + "\""
}

///|
/// Encodes one event. `PartBegin` emits a boundary and headers, `PartData`
/// returns the original binary payload without text conversion, `PartEnd`
/// emits the required CRLF, and `Finished` emits the closing boundary.
///
/// Events must follow `PartBegin`, zero or more `PartData`, `PartEnd`, then
/// another part or `Finished`. Any error is terminal.
pub fn StreamingEncoder::push(
  self : StreamingEncoder,
  event : StreamEvent,
) -> Result[Bytes, MultipartError] {
  match self.failed {
    Some(error) => return Err(error)
    None => ()
  }
  match self.encode_event(event) {
    Ok(chunk) => Ok(chunk)
    Err(error) => {
      self.failed = Some(error)
      Err(error)
    }
  }
}

///|
fn StreamingEncoder::encode_event(
  self : StreamingEncoder,
  event : StreamEvent,
) -> Result[Bytes, MultipartError] {
  match event {
    PartBegin(headers) => {
      guard self.state is AwaitingPart else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      match validate_form_data_headers(headers) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let mut output = "--" + self.boundary + "\r\n"
      for header in headers {
        guard is_valid_header_name(header.name) &&
          is_valid_header_value(header.value) else {
          return Err(
            MultipartError::InvalidHeader(header.name + ": " + header.value),
          )
        }
        output = output + header.name + ": " + header.value + "\r\n"
      }
      self.state = WritingPart
      Ok(@utf8.encode(output + "\r\n"))
    }
    PartData(data) => {
      guard self.state is WritingPart else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      Ok(data)
    }
    PartEnd => {
      guard self.state is WritingPart else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      self.state = AwaitingPart
      Ok(b"\r\n")
    }
    Finished => {
      guard self.state is AwaitingPart else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      self.state = Encoded
      Ok(@utf8.encode("--" + self.boundary + "--\r\n"))
    }
  }
}
