# Security policy

OpenConnectMenu includes a helper that runs as root, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private vulnerability reporting ("Security" tab → "Report a vulnerability") and include:

- what you found and which version is affected;
- how to reproduce it;
- the impact you think it has.

You will get an answer as soon as the maintainer can look at it. Please allow time for a fix before disclosing the problem publicly.

## Scope

The parts that matter most are described in the [security model](README.md#security-model): the XPC connection between the app and the helper, the validation of the data the helper receives, the pinning of the `openconnect` and `vpnc-script` binaries, and the handling of the password and the TOTP secret.

Known limits are listed there too (for example, the Homebrew libraries loaded by `openconnect` are not verified). Vulnerabilities in `openconnect` itself should be reported to that project.

## Supported versions

Only the latest release is supported.
