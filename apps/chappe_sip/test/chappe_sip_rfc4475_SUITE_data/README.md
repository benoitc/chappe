# RFC 4475 SIP torture test corpus

The `rfc4475/` directory holds the 50 bit-exact test messages from RFC 4475
(*Session Initiation Protocol (SIP) Torture Test Messages*), decoded verbatim
from the base64 archive in Appendix A of the RFC. `chappe_sip_rfc4475_SUITE` drives
`chappe_sip_msg:parse/1` (and the URI/header parsers) against each one.

## Provenance and license

These `.dat` files are reproduced from RFC 4475 (February 2006). RFC material is
governed by the IETF Trust's Legal Provisions; the message archive in Appendix A
is included here unmodified for interoperability testing, with attribution to
the RFC. This is separate from, and does not affect, the Apache-2.0 license of
chappe_sip's own code.

Do not edit the `.dat` files: they are intentionally byte-exact (including
unusual whitespace, line folding, and escaping), which is the point of the
corpus.

## Classification

The suite maps each message to the outcome expected of *our* parser, which is
deliberately lenient (strict wire validation lives in sofia on the UDP path):

- Section 3.1.1 well-formed messages must parse (`{ok, _}`).
- Section 3.1.2 malformed messages must never crash the parser; those with a
  malformed start line are rejected (`{error, _}`), the rest are accepted under
  Postel's law and their deep-parse behavior (URI, name-addr, CSeq) is asserted
  separately.
- Section 3.2 / 3.3 / 3.4 messages are syntactically valid (their issues are
  transaction- or application-layer semantics), so they parse; the relevant
  semantic responses (400, 405, 420, 423, ...) are covered by the handling
  suites.

`test.dat` is an unnumbered artifact in the archive (its request line has no
SIP-Version) and is treated as a malformed-start-line reject.
