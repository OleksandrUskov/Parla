import Foundation

/// Third-party attribution data for the in-app Acknowledgements screen (mirrors THIRD_PARTY_NOTICES.md).
/// The app itself is source-available under PolyForm Noncommercial 1.0.0; the bundled components keep their own
/// licenses, listed here. License texts are the standard upstream texts and are intentionally NOT localized.
public enum Acknowledgements {

    public struct Component: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let license: String
        public let copyright: String
    }

    /// App version, read from the bundle (CFBundleShortVersionString).
    public static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    public static let components: [Component] = [
        .init(name: "WhisperKit",            license: "MIT",          copyright: "© 2024 argmax, inc."),
        .init(name: "KeyboardShortcuts",     license: "MIT",          copyright: "© Sindre Sorhus"),
        .init(name: "mlx-swift",             license: "MIT",          copyright: "© 2023 ml-explore"),
        .init(name: "mlx-swift-lm",          license: "MIT",          copyright: "© 2024 ml-explore"),
        .init(name: "yyjson",                license: "MIT",          copyright: "© 2020 YaoYuan"),
        .init(name: "swift-transformers",    license: "Apache-2.0",   copyright: "© Hugging Face"),
        .init(name: "swift-jinja",           license: "Apache-2.0",   copyright: "© Hugging Face"),
        .init(name: "swift-argument-parser", license: "Apache-2.0",   copyright: "© Apple Inc."),
        .init(name: "swift-asn1",            license: "Apache-2.0",   copyright: "© The SwiftASN1 Project"),
        .init(name: "swift-collections",     license: "Apache-2.0",   copyright: "© Apple Inc."),
        .init(name: "swift-crypto",          license: "Apache-2.0",   copyright: "© The SwiftCrypto Project"),
        .init(name: "swift-numerics",        license: "Apache-2.0",   copyright: "© Apple Inc."),
        .init(name: "swift-syntax",          license: "Apache-2.0",   copyright: "© Apple Inc."),
        .init(name: "libopus",               license: "BSD-3-Clause", copyright: "© 2001–2023 Xiph.Org, et al."),
        .init(name: "libogg",                license: "BSD-3-Clause", copyright: "© 2002 Xiph.org Foundation"),
        .init(name: "FFmpeg",                license: "LGPL-2.1",     copyright: "© the FFmpeg developers (macOS helper)"),
    ]

    /// The full upstream license texts, shown verbatim in the Acknowledgements sheet. English only (legal text).
    public static let licenseTexts: String = """
    ────────────────────────────────────────
    MIT License
    (WhisperKit, KeyboardShortcuts, mlx-swift, mlx-swift-lm, yyjson)
    ────────────────────────────────────────
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

    ────────────────────────────────────────
    Apache License 2.0
    (swift-transformers, swift-jinja, swift-argument-parser, swift-asn1,
     swift-collections, swift-crypto, swift-numerics, swift-syntax)
    ────────────────────────────────────────
    Licensed under the Apache License, Version 2.0 (the "License"); you may not use
    these files except in compliance with the License. You may obtain a copy of the
    License at http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software distributed
    under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
    CONDITIONS OF ANY KIND, either express or implied. See the License for the
    specific language governing permissions and limitations under the License.

    NOTICE (Apache-2.0 §4d): swift-crypto © 2019 The SwiftCrypto Project and
    swift-asn1 © 2019 The SwiftASN1 Project each ship a NOTICE file, licensed to you
    under the Apache License 2.0; swift-crypto includes test vectors from Google's
    wycheproof and derivations from SwiftNIO, also under Apache-2.0.

    The full Apache-2.0 text and per-project NOTICE files are reproduced in
    THIRD_PARTY_NOTICES.md in the source repository.

    ────────────────────────────────────────
    BSD-3-Clause — libopus
    © 2001–2023 Xiph.Org, Skype Limited, Octasic, Jean-Marc Valin,
    Timothy B. Terriberry, CSIRO, Gregory Maxwell, Mark Borgerding,
    Erik de Castro Lopo, Mozilla, Amazon
    ────────────────────────────────────────
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    - Redistributions of source code must retain the above copyright notice, this
      list of conditions and the following disclaimer.
    - Redistributions in binary form must reproduce the above copyright notice,
      this list of conditions and the following disclaimer in the documentation
      and/or other materials provided with the distribution.
    - Neither the name of Internet Society, IETF or IETF Trust, nor the names of
      specific contributors, may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
    ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DAMAGES ARISING IN ANY WAY
    OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
    DAMAGE. (Opus is subject to royalty-free patent licenses; see the IETF IPR
    disclosures 1524, 1914, 1526.)

    ────────────────────────────────────────
    BSD-3-Clause — libogg
    © 2002 Xiph.org Foundation
    ────────────────────────────────────────
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the conditions above (retain notice,
    reproduce notice, no-endorsement) are met. THIS SOFTWARE IS PROVIDED "AS IS"
    AND ANY WARRANTIES ARE DISCLAIMED; IN NO EVENT SHALL THE FOUNDATION OR
    CONTRIBUTORS BE LIABLE FOR ANY DAMAGES ARISING OUT OF THE USE OF THIS SOFTWARE.

    ────────────────────────────────────────
    GNU LGPL 2.1-or-later — FFmpeg (macOS only)
    © the FFmpeg developers
    ────────────────────────────────────────
    FFmpeg is used on macOS only, as a separate helper executable built LGPL-clean
    (--disable-gpl --disable-nonfree). The full LGPL-2.1 text and the corresponding
    source / relink notice ship with the binary (LICENSE.LGPL + ffmpeg-SOURCE.md).
    """
}
