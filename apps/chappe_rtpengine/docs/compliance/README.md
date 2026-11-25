# Compliance catalogue

`requirements.tsv` lists the rtpengine NG protocol and bencode behaviours
chappe_rtpengine implements, one row each. How rows are written, claimed in
a test with a `%% req:` line and turned into the generated
[matrix](../compliance.md) is the same for every app: see the shared
[compliance page](https://github.com/benoitc/chappe/blob/main/docs/contributing/compliance.md).

What is specific here: ids are `RNG-<n>`, stable, never renumbered. The
[testing guide](../guides/testing.md#claim-a-protocol-requirement) shows a
claim in this app's suites.
