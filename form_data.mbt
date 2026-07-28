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
/// Returns the submitted filename without Unix or Windows directory
/// components. Generate a separate server-side storage path for the file.
pub fn UploadedFile::filename_basename(self : UploadedFile) -> String {
  filename_basename(self.filename)
}

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
/// Returns the first text value with the supplied field name.
pub fn FormData::text(self : FormData, name : String) -> String? {
  for entry in self.entries {
    match entry {
      Text(field) => if field.name == name { return Some(field.value) }
      File(_) => ()
    }
  }
  None
}

///|
/// Returns every text value with the supplied field name in wire order.
pub fn FormData::text_all(self : FormData, name : String) -> Array[String] {
  let values : Array[String] = []
  for entry in self.entries {
    match entry {
      Text(field) => if field.name == name { values.push(field.value) }
      File(_) => ()
    }
  }
  values
}

///|
/// Returns the first uploaded file with the supplied field name.
pub fn FormData::file(self : FormData, name : String) -> UploadedFile? {
  for entry in self.entries {
    match entry {
      File(file) => if file.field_name == name { return Some(file) }
      Text(_) => ()
    }
  }
  None
}

///|
/// Returns every uploaded file with the supplied field name in wire order.
pub fn FormData::files(self : FormData, name : String) -> Array[UploadedFile] {
  let files : Array[UploadedFile] = []
  for entry in self.entries {
    match entry {
      File(file) => if file.field_name == name { files.push(file) }
      Text(_) => ()
    }
  }
  files
}

///|
/// Resource bounds for the in-memory form collector. Text and file limits are
/// separate because applications commonly accept many small fields but only a
/// small number of larger uploads.
pub(all) struct FormDataLimits {
  max_field_size : Int
  max_file_size : Int
  max_field_count : Int
  max_file_count : Int
}

///|
pub fn FormDataLimits::default() -> FormDataLimits {
  FormDataLimits::{
    max_field_size: 1_048_576,
    max_file_size: 8_388_608,
    max_field_count: 1_000,
    max_file_count: 100,
  }
}

///|
/// A size override for one named form field. It applies to both text and file
/// parts and can only make the corresponding global limit stricter.
pub(all) struct FieldSizeLimit {
  name : String
  max_size : Int
} derive(Debug, Eq)

///|
/// Event consumer that builds an in-memory FormData value from a
/// StreamingParser. Use a future sink-based collector for very large files.
pub(all) struct FormDataCollector {
  entries : Array[FormEntry]
  buffer : @buffer.Buffer
  limits : FormDataLimits
  allowed_fields : Array[String]?
  field_size_limits : Array[FieldSizeLimit]
  mut current_headers : Array[Header]?
  mut current_size : Int
  mut field_count : Int
  mut file_count : Int
  mut finished : Bool
}

///|
pub fn FormDataCollector::new() -> FormDataCollector {
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    limits: FormDataLimits::default(),
    allowed_fields: None,
    field_size_limits: [],
    current_headers: None,
    current_size: 0,
    field_count: 0,
    file_count: 0,
    finished: false,
  }
}

///|
/// Creates an in-memory collector with a maximum size for one part body.
pub fn FormDataCollector::with_file_size_limit(
  max_file_size : Int,
) -> FormDataCollector {
  let limits = FormDataLimits::default()
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    limits: FormDataLimits::{ ..limits, max_file_size, },
    allowed_fields: None,
    field_size_limits: [],
    current_headers: None,
    current_size: 0,
    field_count: 0,
    file_count: 0,
    finished: false,
  }
}

///|
/// Creates an in-memory collector with separate text-field and file limits.
pub fn FormDataCollector::with_limits(
  limits : FormDataLimits,
) -> FormDataCollector {
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    limits,
    allowed_fields: None,
    field_size_limits: [],
    current_headers: None,
    current_size: 0,
    field_count: 0,
    file_count: 0,
    finished: false,
  }
}

///|
/// Creates a collector that rejects any part whose form field name is not in
/// `allowed_fields`. Repeated occurrences of an allowed name remain valid.
pub fn FormDataCollector::with_allowed_fields(
  allowed_fields : Array[String],
  limits? : FormDataLimits = FormDataLimits::default(),
) -> FormDataCollector {
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    limits,
    allowed_fields: Some(allowed_fields),
    field_size_limits: [],
    current_headers: None,
    current_size: 0,
    field_count: 0,
    file_count: 0,
    finished: false,
  }
}

///|
/// Creates a collector with global limits plus stricter per-field size limits.
pub fn FormDataCollector::with_field_size_limits(
  limits : FormDataLimits,
  field_size_limits : Array[FieldSizeLimit],
) -> FormDataCollector {
  FormDataCollector::{
    entries: [],
    buffer: @buffer.Buffer(),
    limits,
    allowed_fields: None,
    field_size_limits,
    current_headers: None,
    current_size: 0,
    field_count: 0,
    file_count: 0,
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
      match self.allowed_fields {
        Some(allowed) =>
          if !contains_string(allowed, name) {
            return Err(MultipartError::UnexpectedField(name))
          }
        None => ()
      }
      if find_parameter(disposition, "filename") is Some(_) {
        if self.file_count >= self.limits.max_file_count {
          return Err(
            MultipartError::FileCountExceeded(self.limits.max_file_count),
          )
        }
      } else if self.field_count >= self.limits.max_field_count {
        return Err(
          MultipartError::FieldCountExceeded(self.limits.max_field_count),
        )
      }
      self.buffer.reset()
      self.current_size = 0
      self.current_headers = Some(headers)
      Ok(())
    }
    PartData(data) => {
      guard self.current_headers is Some(headers) else {
        return Err(MultipartError::InvalidStreamEvent)
      }
      let next_size = self.current_size + data.length()
      guard find_header(headers, "content-disposition") is Some(disposition) else {
        return Err(MultipartError::MissingContentDisposition)
      }
      guard find_parameter(disposition, "name") is Some(name) else {
        return Err(MultipartError::MissingFieldName)
      }
      if find_parameter(disposition, "filename") is Some(_) {
        let limit = effective_field_size_limit(
          name,
          self.limits.max_file_size,
          self.field_size_limits,
        )
        if next_size > limit {
          return Err(MultipartError::FileTooLarge(limit))
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
      }
      self.buffer.write_bytes(data[:])
      self.current_size = next_size
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
          self.file_count = self.file_count + 1
        }
        None => {
          self.entries.push(
            FormEntry::Text(TextField::{
              name,
              value: @utf8.decode_lossy(data[:]),
            }),
          )
          self.field_count = self.field_count + 1
        }
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
fn contains_string(values : Array[String], expected : String) -> Bool {
  for value in values {
    if value == expected {
      return true
    }
  }
  false
}

///|
fn effective_field_size_limit(
  name : String,
  global_limit : Int,
  limits : Array[FieldSizeLimit],
) -> Int {
  let mut effective = global_limit
  for limit in limits {
    if limit.name == name && limit.max_size < effective {
      effective = limit.max_size
    }
  }
  effective
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
