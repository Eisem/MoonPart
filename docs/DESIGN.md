# MoonPart Design

## Purpose

MoonPart is a reusable multipart/form-data core for MoonBit applications. It
separates protocol parsing from transport and storage so the same code works
across MoonBit backends and HTTP frameworks.

## Processing pipeline

```text
HTTP request chunks
        |
        v
StreamingParser
  boundary framing + strict headers + wire limits
        |
        v
StreamEvent: PartBegin / PartData / PartEnd / Finished
        |
        +-----------------------+
        |                       |
        v                       v
FormDataCollector       StreamingFormCollector
small forms             text in memory, files to sink
        |                       |
        v                       v
FormData                StreamedFormData
```

`StreamingFormDecoder` composes the parser and streaming collector for the
common HTTP-handler path. `Parser` remains the convenience API for small,
text-oriented complete bodies.

## State-machine invariants

The streaming parser advances through opening-boundary, headers, body, and
finished states. It emits each transition once and rejects input after a
terminal success or failure.

While reading a body, the parser retains only bytes that could still become a
delimiter when the next chunk arrives. Confirmed body bytes are emitted
immediately. This keeps parser memory proportional to the configured header
limit and boundary length rather than uploaded file size.

Resource accounting is monotonic:

- total wire bytes cannot exceed `max_body_size`;
- emitted bytes for one part cannot exceed `max_part_size`;
- a header block and its field count are bounded;
- the number of parts is bounded;
- collectors independently bound text fields, files, and per-field sizes.

A sink error is terminal. No later file events are delivered after the
collector records a failure.

## Header policy

Part headers use strict CRLF framing. Header names must use HTTP token
characters; control characters, obsolete folding, malformed fields, and
ambiguous duplicate `Content-Disposition` values are rejected.

The parser requires a form-data disposition with a field name before collectors
accept a part. Missing Content-Type values use the RFC 7578 `text/plain`
default.

## Binary and text boundaries

The streaming path treats bodies as `Bytes`; no encoding conversion occurs.
Text collectors decode field bytes only at the form-collection boundary. Large
or arbitrary binary uploads should use a sink callback.

## Failure and cleanup responsibilities

MoonPart reports protocol, limit, and sink failures as `MultipartError`.
Storage is application-owned: after a sink failure, the application is
responsible for deleting or rolling back any partial file/object it created.

## Non-goals

MoonPart does not implement HTTP transport, recursive MIME parsing, asynchronous
I/O, temporary files, content-transfer decoding, media sniffing, upload
quarantine, or storage naming.

## Compatibility and maintenance

The public concrete types live in the root package, matching the ownership rule
in the official MoonBit agent guide. Generated `.mbti` files are the reviewable
public interface. Behavior changes should add black-box tests and update this
document; public interface changes require a SemVer decision.

The implementation is original. RFC 7578 and RFC 2046 are behavioral
references, not copied source code.
