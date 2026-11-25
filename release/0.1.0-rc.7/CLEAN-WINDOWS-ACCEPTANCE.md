# Clean-Windows acceptance for 0.1.0-rc.7

1. Verify the RC ZIP against its `.sha256` sidecar.
2. Extract the integrated user package in a clean Windows 11 x64 environment.
3. Run `Install.cmd`.
4. Confirm the installed PCHW Skill reports version `2.9.3`.
5. Confirm the Runtime reports `0.1.0-rc.7` and bundled Node `24.22.1`.
6. Invoke `$pc-hardware-workbench` in a current Codex conversation.
7. Confirm the panel opens only for the exact Runtime PID, port, and launch ID.
8. Confirm CSV analysis produces the current unresolved subject, charts,
   conclusions, evidence, and copy actions.
9. Restart Runtime with the same Task and confirm artifacts and unresolved state
   survive.
10. Run default uninstall and confirm Task data and backups remain.
11. Run explicit purge and confirm recognized package, Runtime, backup, engine,
    and data roots are removed.
12. Record hashes, process cleanup, residual paths, and user signoff.

Until this is completed, Clean Windows remains `PENDING` and the build remains a
public test build.
