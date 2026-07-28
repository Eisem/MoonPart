///|
/// Runnable end-to-end streaming example. Run with `moon run cmd/main`.
fn main {
  let uploaded = @buffer.Buffer()
  let sink = fn(
    event : @lib.FileSinkEvent,
  ) -> Result[Unit, @lib.MultipartError] {
    match event {
      Data(bytes) => uploaded.write_bytes(bytes[:])
      _ => ()
    }
    Ok(())
  }
  guard @lib.StreamingFormDecoder::from_content_type(
      "multipart/form-data; boundary=MoonPartDemo",
      sink,
      allowed_fields=["title", "asset"],
    )
    is Ok(decoder) else {
    println("invalid multipart content type")
    return
  }
  let chunks = [
    b"--MoonPartDemo\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nMoon",
    b"Bit\r\n--MoonPartDemo\r\nContent-Disposition: form-data; name=\"asset\"; filename=\"demo.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n\x00\xff",
    b"payload\r\n--MoonPartDemo--\r\n",
  ]
  for chunk in chunks {
    guard decoder.feed_bytes(chunk) is Ok(_) else {
      println("failed to decode multipart chunk")
      return
    }
  }
  guard decoder.finish() is Ok(form) else {
    println("multipart body ended unexpectedly")
    return
  }
  println(
    "decoded \{form.fields.length()} text field(s), streamed " +
    "\{form.files.length()} file(s) / \{uploaded.length()} bytes",
  )
}
