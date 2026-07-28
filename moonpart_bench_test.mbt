///|
fn benchmark_body() -> Bytes {
  let body = @buffer.Buffer()
  body.write_utf8(
    "--benchmark\r\n" +
    "Content-Disposition: form-data; name=\"asset\"; filename=\"payload.bin\"\r\n" +
    "Content-Type: application/octet-stream\r\n\r\n",
  )
  body.write_utf8("x".repeat(65_536))
  body.write_utf8("\r\n--benchmark--\r\n")
  body.to_bytes()
}

///|
test "bench 64 KiB multipart parsing" (it : @bench.T) {
  let body = benchmark_body()
  it.bench(name="decode_bytes", count=5, fn() {
    it.keep(decode_bytes("benchmark", body))
  })
  it.bench(name="streaming_4KiB_chunks", count=5, fn() {
    let parser = StreamingParser::new("benchmark")
    for cursor = 0 {
      if cursor >= body.length() {
        break
      }
      let chunk_end = if cursor + 4_096 < body.length() {
        cursor + 4_096
      } else {
        body.length()
      }
      ignore(
        parser.feed_bytes(body.view(start=cursor, end=chunk_end).to_owned()),
      )
      continue chunk_end
    }
    it.keep(parser.finish())
  })
}
