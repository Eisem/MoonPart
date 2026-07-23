///|
/// Minimal executable example. Run with `moon run cmd/main`.
fn main {
  let part = @lib.Part::{
    headers: [
      @lib.Header::{
        name: "Content-Disposition",
        value: "form-data; name=\"title\"",
      },
    ],
    body: "MoonBit",
  }
  let body = @lib.encode("MoonPartDemo", [part])
  let parser = @lib.Parser::new("MoonPartDemo")
  ignore(parser.feed(body))
  match parser.finish() {
    Ok(parts) =>
      println("decoded \{parts.length()} form field(s): \{parts[0].body}")
    Err(_) => println("failed to parse multipart demo")
  }
}
