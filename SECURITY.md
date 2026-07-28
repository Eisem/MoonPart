# Security Policy

## Supported versions

Until the first stable release, security fixes are applied to the latest
published `0.x` version and the default branch.

## Reporting a vulnerability

Do not publish exploit details in a public Issue. Use GitHub's private
vulnerability reporting feature for this repository. If that feature is not
available, contact the repository owner through the contact method on the
GitHub profile and request a private reporting channel.

Include the affected API, a minimal multipart input, expected and observed
behavior, and the MoonBit target used to reproduce the issue. You should receive
an acknowledgement within seven days.

## Security model

MoonPart validates multipart syntax and enforces configured resource limits,
but callers remain responsible for:

- choosing limits appropriate for the service;
- authenticating and authorizing the request;
- generating trusted server-side storage paths;
- scanning or validating uploaded content;
- applying request timeouts and transport-level limits;
- making sink callbacks atomic or cleaning up partial writes after failure.

`filename_basename` removes path components; it does not make a submitted
filename safe or unique.
