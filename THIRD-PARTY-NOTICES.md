# Third-party notices

StarPulse is released under the MIT License (see `LICENSE`). It builds on the work below.

## Dishylink (MIT)

The dish and router protocol details (endpoints, protobuf field numbers, ring-buffer decoding,
throughput tracking, alignment test, obstruction grid orientation, speed-test method, device pause
and DNS request shapes), the feature set and the original visual tokens follow
[Dishylink](https://github.com/DaveyHert/dishylink).

```text
MIT License

Copyright (c) 2026 daveyhert

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Files taken from Dishylink:

- `Tests/StarPulseCoreTests/Fixtures/sample-status.json` and `sample-history.json` (schema samples)
- `Sources/StarPulseCore/Resources/oui.json` (manufacturer table compiled from the public IEEE OUI registry)

## Fonts (SIL Open Font License 1.1)

- D-DIN, by Datto (https://www.datto.com/fonts/d-din), Reserved Font Name "D-DIN", used unmodified.
  License: `Sources/StarPulse/Resources/Fonts/OFL-D-DIN.txt`
- IBM Plex Mono, Copyright 2017 IBM Corp., Reserved Font Name "Plex".
  License: `Sources/StarPulse/Resources/Fonts/OFL-IBMPlexMono.txt`

## Data sources used at run time

- Orbital elements: [CelesTrak](https://celestrak.org) supplemental Starlink set (supplied by SpaceX)
  and the standard GP group. Downloaded on demand; not redistributed.
- Speed test: Cloudflare's public speed endpoints (`speed.cloudflare.com`).

## Not affiliated

StarPulse is an unofficial, independent project with no affiliation to SpaceX or Starlink. It is not affiliated with, endorsed by or sponsored by
SpaceX, Starlink, Apple, Cloudflare, Datto, CelesTrak, the DNS providers mentioned in the
documentation, or the Dishylink authors. "Starlink" is a trademark of Space Exploration
Technologies Corp.
