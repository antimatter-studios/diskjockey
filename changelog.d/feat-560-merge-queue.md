### Added

- **`am-queue` lists every pull request waiting in a merge queue across the
  constellation (#560).** Project, position, state, when it was queued and
  the pull request, from one GraphQL request for every project whose answer
  is stale rather than one per project. When that request fails each project
  is asked on its own, so an unreadable one is a FETCH FAILED row and exit 4;
  a rate limit stops the run with exit 5. Each answer is kept for
  `AM_GITHUB_CACHE_TTL` seconds, 300 by default, and `--no-cache` asks
  anyway. `chore queue:list` runs it.
