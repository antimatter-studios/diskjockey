### Added

- **The agent can serve DriverKit reads over a user-client connection.** The
  caller's readable file proof is checked before opening the image reader or
  connection. Malformed requests are refused, failed reads carry no payload,
  and disconnect closes the reader. The provisioned mount round trip follows.
