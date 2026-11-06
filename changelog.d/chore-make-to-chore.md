### Changed

- The build runs through `chores.yml`, and the Makefile is gone: `chore vendor` builds the libraries the Xcode project links, `chore build` builds them and then the app, and `chore installable` and `chore install` replace `make installable` and `make installable-install`.

### Removed

- The `proto` target, whose `.proto` source went with the backend daemon, and the go-networkfs `force` and `add` targets, which set variables the build no longer reads.
