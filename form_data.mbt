///|
/// A decoded text form field.
pub(all) struct TextField {
  name : String
  value : String
} derive(Debug, Eq)

///|
/// A decoded uploaded file. `data` preserves the original file bytes.
pub(all) struct UploadedFile {
  field_name : String
  filename : String
  content_type : String
  data : Bytes
} derive(Debug)

///|
/// A form entry in original wire order. Repeated names are intentionally kept.
pub(all) enum FormEntry {
  Text(TextField)
  File(UploadedFile)
} derive(Debug)

///|
/// Collected multipart/form-data entries in original wire order.
pub(all) struct FormData {
  entries : Array[FormEntry]
} derive(Debug)

///|
/// Event consumer that builds an in-memory FormData value from a
/// StreamingParser. Use a future sink-based collector for very large files.
pub(all) struct FormDataCollector {
  entries : Array[FormEntry]
  buffer : @buffer.Buffer
  mut current_headers : Array[Header]?
  mut finished : Bool
}

///|
pub fn FormDataCollector::new() -> FormDataCollector {
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    current_headers: None,
    finished: false,
  }
}

///|
/// Consumes one streaming event.
pub fn FormDataCollector::push(
  self : FormDataCollector,
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
      self.buffer.reset()
      self.current_headers = Some(headers)
      Ok(())
    }
    PartData(data) => {
      guard self.current_headers is Some(_) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      self.buffer.write_bytes(data[:])
      Ok(())
    }
    PartEnd => {
      guard self.current_headers is Some(headers) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      guard find_header(headers, "content-disposition") is Some(disposition) else {
        return Err(MultipartError::MissingContentDisposition)
      }
      guard find_parameter(disposition, "name") is Some(name) else {
        return Err(MultipartError::MissingFieldName)
      }
      let data = self.buffer.to_bytes()
      match find_parameter(disposition, "filename") {
        Some(filename) => {
          let content_type = match find_header(headers, "content-type") {
            Some(value) => value
            None => "application/octet-stream"
          }
          self.entries.push(
            FormEntry::File(UploadedFile::{
              field_name: name,
              filename,
              content_type,
              data,
            }),
          )
        }
        None =>
          self.entries.push(
            FormEntry::Text(TextField::{
              name,
              value: @utf8.decode_lossy(data[:]),
            }),
          )
      }
      self.current_headers = None
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
/// Returns the final collected data once the Finished event has been consumed.
pub fn FormDataCollector::finish(
  self : FormDataCollector,
) -> Result[FormData, MultipartError] {
  if self.finished && self.current_headers is None {
    Ok(FormData::{ entries: self.entries })
  } else {
    Err(MultipartError::InvalidStreamEvent)
  }
}
