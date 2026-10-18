### Fixed

- **Ejecting a DriverKit-mounted image releases its owned attachment.** The
  app retains the attachment identity returned by the agent and uses owned
  detach from both the volume sidebar and the File menu. The agent unmounts
  every volume before removing the media and closing the reader. Images
  attached with hdiutil still detach through hdiutil. Failed ejects retain
  their route for retry, and simultaneous sibling ejects share one request.
