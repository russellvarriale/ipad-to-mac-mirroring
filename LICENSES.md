# Licensing

This repository contains original MIT-licensed app code and a modified
GPL-licensed wireless receiver. It is **not an MIT-only distribution**.

| Part | License |
| --- | --- |
| Original Swift app (`Main.swift`, `WirelessReceiver.swift`, `WirelessVideo.swift`, `WirelessVideoTransport.swift`) | [MIT](LICENSE) |
| Original root build script, `scripts/build-wireless.sh`, icon generator, first-party test harnesses, documentation, and original artwork | [MIT](LICENSE) |
| UxPlay and the native receiver integration under `scripts/native/`, including local patches | GPL-3.0-or-later, except files with their own upstream license notices |
| UxPlay's bundled third-party source | Its existing file-level licenses; notices are preserved |
| Runtime dependencies used by the wireless helper | Their respective GPL/LGPL/Apache/MIT and other licenses; see [third-party notices](THIRD-PARTY-NOTICES.txt) |

The MIT grant for original portions permits their reuse, modification, and
commercial use while retaining the license notice. It is compatible with GPLv3.
It does not remove the obligations attached to the receiver or its dependencies.

For distribution of the combined application, preserve the GPL/LGPL rights and
comply with the applicable corresponding-source requirements. Do not describe
the complete bundled app as exclusively MIT-licensed or assume that a separate
helper process exempts a tightly integrated combination from GPL obligations.
The original portions remain separately available under MIT.

## Required attribution for original code

Keep the complete copyright and MIT permission notice when copying, forking, or
redistributing original code or substantial portions of it. That copyright
notice identifies **Russell Varriale** and the original repository:
<https://github.com/russellvarriale/ipad-to-mac-mirroring>.

A visible credit/link in your fork's README is appreciated. Standard MIT does
not require an advertisement, app-screen credit, or endorsement. Existing
third-party copyright/license notices must also be retained.

## Distributing a binary

Include `LICENSE`, this file, [the full GPL text](COPYING.GPL-3.0), and all bundled
third-party notices/license texts. Provide the modified receiver source, exact
dependency sources, and build/relinking materials alongside each binary release.
Follow the corresponding-source collection instructions under `scripts/native/`.
A source-only repository does not automatically supply every third-party source
needed by a separate prebuilt runtime release.

The included build is locally ad-hoc signed and is not notarized. Developer ID
signing and notarization are separate release steps; any distribution must
preserve users' applicable rights to rebuild/relink modified components.

## References

- [MIT license text — Open Source Initiative](https://opensource.org/license/mit)
- [MIT/Expat GPL compatibility — Free Software Foundation](https://www.gnu.org/licenses/license-list.html#Expat)
- [GPLv3 corresponding source and distribution](https://www.gnu.org/licenses/gpl-3.0.en.html)
- [FSF explanation of aggregation and IPC](https://www.gnu.org/licenses/gpl-faq.en.html#MereAggregation)

Existing upstream copyright notices remain with their source. Apple framework
and system-symbol use is governed separately by Apple's terms; the app icon is
original drawing code supplied in `scripts/make-icon.swift`.
