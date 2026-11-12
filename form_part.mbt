///|
/// Validated form-data metadata cached for the lifetime of one part.
struct FormPartMetadata {
  headers : Array[Header]
  name : String
  filename : String?
  content_type : String
}

///|
/// Validates headers and extracts all metadata collectors need. This function
/// is deliberately usable for manually constructed StreamEvent values as well
/// as parser output.
fn parse_form_part_metadata(
  headers : Array[Header],
) -> Result[FormPartMetadata, MultipartError] {
  let mut disposition_count = 0
  let mut content_type_count = 0
  for header in headers {
    match header.name.to_lower() {
      "content-disposition" => disposition_count = disposition_count + 1
      "content-type" => content_type_count = content_type_count + 1
      _ => ()
    }
  }
  if disposition_count > 1 {
    return Err(MultipartError::DuplicateHeader("Content-Disposition"))
  }
  if content_type_count > 1 {
    return Err(MultipartError::DuplicateHeader("Content-Type"))
  }
  guard find_header(headers, "content-disposition") is Some(disposition) else {
    return Err(MultipartError::MissingContentDisposition)
  }
  let parsed = match parse_parameterized_value(disposition) {
    Ok(parsed) => parsed
    Err(_) => return Err(MultipartError::InvalidContentDisposition)
  }
  guard parsed.base.to_lower() == "form-data" else {
    return Err(MultipartError::InvalidContentDisposition)
  }
  guard parsed.parameter("name") is Some(name) else {
    return Err(MultipartError::MissingFieldName)
  }
  let filename = parsed.parameter("filename")
  let content_type = match find_header(headers, "content-type") {
    Some(value) => value
    None =>
      if filename is Some(_) {
        "application/octet-stream"
      } else {
        "text/plain"
      }
  }
  Ok(FormPartMetadata::{ headers, name, filename, content_type, })
}

///|
fn validate_form_data_headers(
  headers : Array[Header],
) -> Result[Unit, MultipartError] {
  match parse_form_part_metadata(headers) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}
