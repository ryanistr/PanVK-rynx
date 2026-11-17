# License

The driver binary produced by this repository is built from Mesa's `src/panfrost` code,
which is distributed under the MIT license. The source tree is the read-only third-party
fork `apexspan-svg/mesa-panvk-mali-g57`; all of its upstream copyright notices and license
terms remain in force in the built artifact.

Each patch under `patches/` keeps its own provenance: the `From:` lines name the origin of
patches derived from other trees, and the code they modify keeps that code's license.

The build scripts, release workflow, packaging metadata and documentation original to this
repository are provided under the MIT license:

> Copyright (c) 2026 PanVK-rynx contributors
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this
> software and associated documentation files (the "Software"), to deal in the Software
> without restriction, including without limitation the rights to use, copy, modify, merge,
> publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
> to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
> INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
> PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
> FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
> DEALINGS IN THE SOFTWARE.
