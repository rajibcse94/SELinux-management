# Contributing

Thanks for your interest in improving the SELinux Management Toolkit!

## Reporting issues

When opening an issue, please include:

- Your distribution and version (`cat /etc/os-release`)
- SELinux mode and policy (`sestatus`)
- The exact command you ran and its full output
- What you expected to happen

## Development

The whole tool is a single Bash script (`selinux-toolkit.sh`) plus docs, so the
bar to contribute is low.

Before opening a pull request:

1. Keep it POSIX-friendly Bash; the script targets `bash` 4+.
2. Lint with [ShellCheck](https://www.shellcheck.net/):

   ```bash
   shellcheck selinux-toolkit.sh install.sh
   ```

3. Syntax-check:

   ```bash
   bash -n selinux-toolkit.sh
   ```

4. Test the affected subcommands on a real SELinux host (a RHEL-family VM is
   ideal). Note in the PR what you tested.

## Style

- Every action that changes the system must require root and confirm before
  doing anything destructive.
- Prefer printing what *will* happen and letting the user apply it, over silent
  automatic changes (this is why `suggest` does not auto-install policy).
- Keep output readable; reuse the existing `info`/`ok`/`warn`/`err` helpers.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.
