# Security Policy

## Supported Versions

Security fixes go into the latest release of each app. The latest bundle
(`vYYYY.MM.N` on the [releases page](https://github.com/benoitc/chappe/releases))
lists those versions. The vendored sofia-sip is kept at the pinned version
named in [AGENTS.md](AGENTS.md#conventions), and every app requires
Erlang/OTP 29.1.2 or later.

| Version | Supported |
| ------- | --------- |
| The app versions in the latest bundle | yes |
| Older app versions | no |

## What is a security issue

Private reports are for problems that are not a deviation from a
specification chappe implements:

- code execution, including memory corruption in the sofia-sip NIF or
  its C engine;
- a peer accepted without the authentication the configuration asks for:
  digest authentication, TLS certificate and hostname checks, the
  FreeSWITCH event socket address list and password, the Erlang
  distribution cookie;
- one call's signalling, media, recording or keys reaching another party
  or another call;
- chappe weakening TLS or SRTP below what the configuration allows.

## What is a bug

When the fix is to make chappe follow a specification it implements (SIP
and its extensions, SDP, RTP, RTCP, SRTP, WebSocket and the others listed
in [AGENTS.md](AGENTS.md#specifications)), it is a bug. That holds even
when the report describes it as amplification, denial of service or a
remote crash of an Erlang process. Report it as a public bug and cite the
specification section; see
[Security issues and specification bugs](CONTRIBUTING.md#security-issues-and-specification-bugs).
We don't publish advisories or request CVEs for these, and advisories filed
for them are closed as bugs with a link to the fix.

Write the report in plain English, with a minimal reproduction, as described
in [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it).

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub's
[Private Vulnerability Reporting](https://github.com/benoitc/chappe/security/advisories/new).

Do not open public issues or pull requests for security problems.

When reporting, include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept (a SIPp scenario or a pcap
  helps most).
- The app versions or bundle, the OTP version and the platform.
- Any suggested fix or mitigation.

You can expect an initial acknowledgement within 7 days. We will work with
you on a fix and coordinate disclosure once a patched release is available.
Credit will be given in the advisory unless you prefer to remain anonymous.
