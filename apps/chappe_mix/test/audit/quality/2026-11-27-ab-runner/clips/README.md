# Speech clips

These are the eight speech clips the HD room A/B plays, committed so that a
runner can play them without taq or its download of the corpus. Each one is a
clip prepared by taq from the CSTR VCTK Corpus 0.92; `SHA256SUMS` pins each
file to the prepared sha256 in taq's clip list (`clips/vctk-0.92.json` in the
taq repository).

```sh
shasum -a 256 -c SHA256SUMS
```

## What "prepared" means

taq made each clip from two or three utterances of one speaker (`wav48_silence_trimmed`,
microphone `mic1`):

- each utterance faded in and out over 5 ms;
- the utterances joined with 0.3 s of silence;
- the level set to -26 dBov (ITU-T P.56 active speech level);
- 0.5 s of silence added before and after;
- written as a 48 kHz, mono, 16-bit PCM WAV.

`../pad.py` adds 2 s of silence to each one before a run, as `taq live` does.

## License and attribution

The CSTR VCTK Corpus is licensed under the Creative Commons Attribution 4.0
International license (CC BY 4.0,
<https://creativecommons.org/licenses/by/4.0/legalcode>).

Yamagishi, Junichi; Veaux, Christophe; MacDonald, Kirsten. (2019). CSTR VCTK
Corpus: English Multi-speaker Corpus for CSTR Voice Cloning Toolkit (version
0.92), [sound]. University of Edinburgh. The Centre for Speech Technology
Research (CSTR). <https://doi.org/10.7488/ds/2645>.

Changes: excerpted, concatenated, faded, level-normalised to -26 dBov and
padded with silence, as listed above.

| File | Speaker |
| --- | --- |
| `vctk092-p225-01.wav` | p225 |
| `vctk092-p226-01.wav` | p226 |
| `vctk092-p234-01.wav` | p234 |
| `vctk092-p237-01.wav` | p237 |
| `vctk092-p245-01.wav` | p245 |
| `vctk092-p248-01.wav` | p248 |
| `vctk092-p294-01.wav` | p294 |
| `vctk092-p326-01.wav` | p326 |
