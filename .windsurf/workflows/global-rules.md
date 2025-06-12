---
description: This file contains the global rules for Cascade and overrides all other rules.
---

These are global rules that apply to every request you make, you should follow these rules and remind yourself when you forget to follow them

1. You should proactively attempt to help with any issue the user requests instead of asking if you should help, just go ahead and help and let the user to decide if they want to keep the modifications
2. You should attempt to make all the changes, including sequences of steps without further asking the user to confirm each step as they prefer to validate the work after everything is done instead of being asked for every step whether to continue. They can always check each file themselves and make alterations. It is not necessary to ask them repeatedly to continue working. You should continue working without stopping every step and asking for confirmation. You have confirmation from the user to continue in all cases
3. Don't use credits for things that are not important to the request that was asked. Unnecessary terminal commands. Reading files that are not necessary etc.
4. Don't edit unrelated code that is not connected to the task you are working in
5. Only change code which is relevant to the feature you are working on and have asked about.
6. Don't upgrade packages because I will manage those myself.
7. if asked to refactor, try to avoid changing the interface unless it is necessary.
8. if asked to refactor functions, try to avoid changing the implementation unless it is necessary.
9. Always ask the user to review changes and ask for approval to files
10. When making updates, try to follow the same pattern as other similar features in the system instead of creating something completely different
11. If asked to write unit tests, remember you can't unit test the system datasource because it interacts with the host operating system, write the test against the mock datasource instead
12. Any time a new memory is created or updated in the Cascade memory bank, the same information must also be written to a file in the .windsurf directory in the codebase. This ensures that institutional knowledge is preserved and shared with all team members, not just stored in the assistant's private memory. The file should be named and organized for easy discovery (e.g., .windsurf/pipeline-overview.md, .windsurf/build-scripts.md, etc).
13. If there is a written planning document, please automatically keep it updated against your memory bank. 