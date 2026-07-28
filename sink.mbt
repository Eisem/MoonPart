///|
/// Metadata for a streamed file part. File contents are delivered separately
/// as `FileSinkEvent::Data` and are never retained by StreamingFormCollector.
pub(all) struct StreamedFile {
  field_name : String
  filename : String
  content_type : String
  headers : Array[Header]
} derive(Debug, Eq)

///|
/// Returns the submitted filename without Unix or Windows directory parts.
pub fn StreamedFile::filename_basename(self : StreamedFile) -> String {
  filename_basename(self.filename)
}

///|
/// Events sent to an application-provided file sink. Each Begin is followed by
/// zero or more Data events and exactly one End event.
pub(all) enum FileSinkEvent {
  Begin(StreamedFile)
  Data(Bytes)
  End
} derive(Debug)

///|
/// Result of sink-based form collection. Text fields are retained in memory;
/// files contain metadata only because their bytes have already reached the
/// sink.
pub(all) struct StreamedFormData {
  fields : Array[TextField]
  files : Array[StreamedFile]
} derive(Debug)

///|
/// Consumes multipart events while forwarding file bytes to a callback. An
/// empty `allowed_fields` list accepts every field name.
pub(all) struct StreamingFormCollector {
  fields : Array[TextField]
  files : Array[StreamedFile]
  text_buffer : @buffer.Buffer
  limits : FormDataLimits
  allowed_fields : Array[String]
  field_size_limits : Array[FieldSizeLimit]
  sink : (FileSinkEvent) -> Result[Unit, MultipartError]
  mut current_headers : Array[Header]?
  mut current_size : Int
  mut current_is_file : Bool
  mut field_count : Int
  mut file_count : Int
  mut finished : Bool
  mut failed : MultipartError?
}

///|
pub fn StreamingFormCollector::new(
  sink : (FileSinkEvent) -> Result[Unit, MultipartError],
  limits? : FormDataLimits = FormDataLimits::default(),
  allowed_fields? : Array[String] = [],
  field_size_limits? : Array[FieldSizeLimit] = [],
) -> StreamingFormCollector {
  StreamingFormCollector::{
    fields: [],
    files: [],
    text_buffer: @buffer.Buffer(),
    limits,
    allowed_fields,
    field_size_limits,
    sink,
    current_headers: None,
    current_size: 0,
    current_is_file: false,
    field_count: 0,
    file_count: 0,
    finished: false,
    failed: None,
  }
}

///|
/// Consumes one event produced by StreamingParser.
pub fn StreamingFormCollector::push(
  self : StreamingFormCollector,
  event : StreamEvent,
) -> Result[Unit, MultipartError] {
  match self.failed {
    Some(error) => return Err(error)
    None => ()
  }
  match self.push_event(event) {
    Ok(_) => Ok(())
    Err(error) => {
      self.failed = Some(error)
      Err(error)
    }
  }
}

///|
fn StreamingFormCollector::push_event(
  self : StreamingFormCollector,
  event : StreamEvent,
) -> Result[Unit, MultipartError] {
  if self.finished {
    return Err(MultipartError::InvalidStreamEvent)
  }
  match event {
    PartBegin(headers) => {
      guard self.current_headers is None else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      match validate_form_data_headers(headers) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      guard find_header(headers, "content-disposition") is Some(disposition) else {
        return Err(MultipartError::MissingContentDisposition)
      }
      guard find_parameter(disposition, "name") is Some(name) else {
        return Err(MultipartError::MissingFieldName)
      }
      if !self.allowed_fields.is_empty() &&
        !contains_string(self.allowed_fields, name) {
        return Err(MultipartError::UnexpectedField(name))
      }
      self.text_buffer.reset()
      self.current_size = 0
      match find_parameter(disposition, "filename") {
        Some(filename) => {
          if self.file_count >= self.limits.max_file_count {
            return Err(
              MultipartError::FileCountExceeded(self.limits.max_file_count),
            )
          }
          let content_type = match find_header(headers, "content-type") {
            Some(value) => value
            None => "application/octet-stream"
          }
          let file = StreamedFile::{
            field_name: name,
            filename,
            content_type,
            headers,
          }
          match (self.sink)(FileSinkEvent::Begin(file)) {
            Ok(_) => ()
            Err(error) => return Err(error)
          }
          self.files.push(file)
          self.current_is_file = true
        }
        None => {
          if self.field_count >= self.limits.max_field_count {
            return Err(
              MultipartError::FieldCountExceeded(self.limits.max_field_count),
            )
          }
          self.current_is_file = false
        }
      }
      self.current_headers = Some(headers)
      Ok(())
    }
    PartData(data) => {
      guard self.current_headers is Some(_) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      let next_size = self.current_size + data.length()
      guard self.current_headers is Some(headers) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      guard find_header(headers, "content-disposition") is Some(disposition) else {
        return Err(MultipartError::MissingContentDisposition)
      }
      guard find_parameter(disposition, "name") is Some(name) else {
        return Err(MultipartError::MissingFieldName)
      }
      if self.current_is_file {
        let limit = effective_field_size_limit(
          name,
          self.limits.max_file_size,
          self.field_size_limits,
        )
        if next_size > limit {
          return Err(MultipartError::FileTooLarge(limit))
        }
        match (self.sink)(FileSinkEvent::Data(data)) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      } else {
        let limit = effective_field_size_limit(
          name,
          self.limits.max_field_size,
          self.field_size_limits,
        )
        if next_size > limit {
          return Err(MultipartError::FieldTooLarge(limit))
        }
        self.text_buffer.write_bytes(data[:])
      }
      self.current_size = next_size
      Ok(())
    }
    PartEnd => {
      guard self.current_headers is Some(headers) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      if self.current_is_file {
        match (self.sink)(FileSinkEvent::End) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        self.file_count = self.file_count + 1
      } else {
        guard find_header(headers, "content-disposition") is Some(disposition) else {
          return Err(MultipartError::MissingContentDisposition)
        }
        guard find_parameter(disposition, "name") is Some(name) else {
          return Err(MultipartError::MissingFieldName)
        }
        self.fields.push(TextField::{
          name,
          value: @utf8.decode_lossy(self.text_buffer.to_bytes()[:]),
        })
        self.field_count = self.field_count + 1
      }
      self.current_headers = None
      self.current_is_file = false
      Ok(())
    }
    Finished => {
      guard self.current_headers is None else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      self.finished = true
      Ok(())
    }
  }
}

///|
/// Returns collected text fields and streamed file metadata after Finished.
pub fn StreamingFormCollector::finish(
  self : StreamingFormCollector,
) -> Result[StreamedFormData, MultipartError] {
  match self.failed {
    Some(error) => Err(error)
    None =>
      if self.finished && self.current_headers is None {
        Ok(StreamedFormData::{ fields: self.fields, files: self.files })
      } else {
        Err(MultipartError::InvalidStreamEvent)
      }
  }
}

///|
/// End-to-end multipart/form-data decoder that connects StreamingParser to a
/// StreamingFormCollector. File bytes go directly to the supplied sink.
pub(all) struct StreamingFormDecoder {
  parser : StreamingParser
  collector : StreamingFormCollector
  mut failed : MultipartError?
}

///|
/// Creates a decoder from a raw multipart boundary.
pub fn StreamingFormDecoder::new(
  boundary : String,
  sink : (FileSinkEvent) -> Result[Unit, MultipartError],
  stream_limits? : StreamLimits = StreamLimits::default(),
  form_limits? : FormDataLimits = FormDataLimits::default(),
  allowed_fields? : Array[String] = [],
  field_size_limits? : Array[FieldSizeLimit] = [],
) -> StreamingFormDecoder {
  StreamingFormDecoder::{
    parser: StreamingParser::with_limits(boundary, stream_limits),
    collector: StreamingFormCollector::new(
      sink,
      limits=form_limits,
      allowed_fields~,
      field_size_limits~,
    ),
    failed: None,
  }
}

///|
/// Creates a decoder directly from an HTTP Content-Type value.
pub fn StreamingFormDecoder::from_content_type(
  content_type : String,
  sink : (FileSinkEvent) -> Result[Unit, MultipartError],
  stream_limits? : StreamLimits = StreamLimits::default(),
  form_limits? : FormDataLimits = FormDataLimits::default(),
  allowed_fields? : Array[String] = [],
  field_size_limits? : Array[FieldSizeLimit] = [],
) -> Result[StreamingFormDecoder, MultipartError] {
  match boundary_from_content_type(content_type) {
    Ok(boundary) =>
      Ok(
        StreamingFormDecoder::new(
          boundary,
          sink,
          stream_limits~,
          form_limits~,
          allowed_fields~,
          field_size_limits~,
        ),
      )
    Err(error) => Err(error)
  }
}

///|
/// Feeds an arbitrary network body chunk through the parser and file sink.
pub fn StreamingFormDecoder::feed_bytes(
  self : StreamingFormDecoder,
  chunk : Bytes,
) -> Result[Unit, MultipartError] {
  match self.failed {
    Some(error) => return Err(error)
    None => ()
  }
  match self.feed_chunk(chunk) {
    Ok(_) => Ok(())
    Err(error) => {
      self.failed = Some(error)
      Err(error)
    }
  }
}

///|
fn StreamingFormDecoder::feed_chunk(
  self : StreamingFormDecoder,
  chunk : Bytes,
) -> Result[Unit, MultipartError] {
  match self.parser.feed_bytes(chunk) {
    Err(error) => Err(error)
    Ok(events) => {
      for event in events {
        match self.collector.push(event) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      Ok(())
    }
  }
}

///|
/// Validates the closing boundary and returns text fields plus file metadata.
pub fn StreamingFormDecoder::finish(
  self : StreamingFormDecoder,
) -> Result[StreamedFormData, MultipartError] {
  match self.failed {
    Some(error) => return Err(error)
    None => ()
  }
  match self.finish_stream() {
    Ok(form) => Ok(form)
    Err(error) => {
      self.failed = Some(error)
      Err(error)
    }
  }
}

///|
fn StreamingFormDecoder::finish_stream(
  self : StreamingFormDecoder,
) -> Result[StreamedFormData, MultipartError] {
  match self.parser.finish() {
    Err(error) => Err(error)
    Ok(events) => {
      for event in events {
        match self.collector.push(event) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
      self.collector.finish()
    }
  }
}
