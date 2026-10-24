### Fixed

- **`am-queue` lists the queue of each repository's default branch (#562),**
  not `main`'s by name, so a repository whose default branch is another one
  no longer reads as an empty queue. One queued pull request is counted in
  the singular.
