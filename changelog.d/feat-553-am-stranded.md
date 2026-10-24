### Added

- **`am-stranded` finds merged pull requests whose work never reached
  main (#553).** Across the constellation, a merged pull request whose base
  was not the default branch is followed through each base branch's own
  pull request, merged after it, until a merge commit main reaches. A chain
  that ends first is stranded and printed with the chain it followed. A
  later pull request into main that names it re-lands it, and an open one
  that names it, `#N` or inside `#A through #B`, covers it.
  `chore stranded:list` lists them. `chore stranded:check` fails while any
  is neither re-landed nor covered, and a repository it cannot read fails
  the run.
