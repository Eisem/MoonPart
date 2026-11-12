///|
/// One normalized MIME parameter. Names are stored in lowercase so duplicate
/// detection and lookup use the same case-insensitive semantics.
priv struct MediaParameter {
  name : String
  value : String
}

///|
/// A Content-Type or Content-Disposition value split into its base token and
/// strictly parsed parameters.
priv struct ParameterizedValue {
  base : String
  parameters : Array[MediaParameter]
}

///|
fn ParameterizedValue::parameter(
  self : ParameterizedValue,
  name : String,
) -> String? {
  let target = name.to_lower()
  for parameter in self.parameters {
    if parameter.name == target {
      return Some(parameter.value)
    }
  }
  None
}

///|
/// Parses a parameterized MIME value while preserving semicolons inside quoted
/// strings. Malformed quoting, invalid tokens, empty segments, and duplicate
/// parameter names are rejected.
fn parse_parameterized_value(
  value : String,
) -> Result[ParameterizedValue, Unit] {
  let segments : Array[String] = []
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
      segments.push(segment.to_string())
      segment.reset()
    } else {
      segment.write_char(character)
    }
  }
  if quoted || escaped {
    return Err(())
  }
  segments.push(segment.to_string())
  let base = segments[0].trim().to_owned()
  if base.is_empty() {
    return Err(())
  }
  let parameters : Array[MediaParameter] = []
  for index in 1..<segments.length() {
    guard parse_parameter_segment(segments[index]) is Some(parameter) else {
      return Err(())
    }
    for existing in parameters {
      if existing.name == parameter.name {
        return Err(())
      }
    }
    parameters.push(parameter)
  }
  Ok(ParameterizedValue::{ base, parameters, })
}

///|
fn parse_parameter_segment(segment : String) -> MediaParameter? {
  let item = segment.trim().to_owned()
  guard !item.is_empty() else { return None }
  guard item.split_once("=") is Some((raw_name, raw_value)) else { return None }
  let name = raw_name.trim().to_owned().to_lower()
  guard is_valid_header_name(name) else { return None }
  let candidate = raw_value.trim().to_owned()
  guard !candidate.is_empty() else { return None }
  let parsed_value = if candidate.has_prefix("\"") {
    guard candidate.length() >= 2 && candidate.has_suffix("\"") else {
      return None
    }
    unescape_quoted_value(candidate[1:candidate.length() - 1])
  } else {
    guard is_valid_header_name(candidate) else { return None }
    candidate
  }
  Some(MediaParameter::{ name, value: parsed_value, })
}

///|
/// Returns one parameter from a valid parameterized value.
fn find_parameter(value : String, parameter : String) -> String? {
  match parse_parameterized_value(value) {
    Ok(parsed) => parsed.parameter(parameter)
    Err(_) => None
  }
}

///|
/// Decodes quoted-string escapes used by MIME parameters.
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
  output.to_string()
}
