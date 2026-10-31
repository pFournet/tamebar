# Security

Report security issues privately through GitHub's private vulnerability reporting: on
[pFournet/tamebar](https://github.com/pFournet/tamebar), open Security, then Report a vulnerability. Please
don't open a public issue for them.

Tamebar inspects local processes, signals them, and can permanently delete reviewed files, so these count as
security issues:

- Removing, trashing, or signaling something other than what the user reviewed.
- Bypassing protected paths, process-identity checks, or Keep running settings.
- Exposing credentials, process arguments, conversation contents, or private paths.
- Unsafe path handling such as symlink or race-condition tricks during cleanup.

Useful details to include:

- Tamebar version (bottom of Settings) and macOS version.
- Whether you used a downloaded build or a source build.
- Steps to reproduce, ideally with disposable test folders.
- Logs or screenshots with secrets and private paths removed.

Response times vary. We confirm receipt when we can and follow up once there is a fix or a clear mitigation.
