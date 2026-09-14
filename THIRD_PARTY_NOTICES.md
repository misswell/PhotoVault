# Third-party notices

PhotoVault's AI photo search runs entirely on device: no photo, embedding, OCR
result or query ever leaves the device. This file records the third-party
components involved and their licenses.

Verified against the shipped artifacts on 2026-09-13.

## Redistributed inside the app bundle

### SigLIP2 — `google/siglip2-base-patch16-256`

- **License:** Apache License 2.0 (read from the upstream model card:
  `license: apache-2.0`)
- **Upstream:** <https://huggingface.co/google/siglip2-base-patch16-256>
- **Shipped as:** `SigLIP2Vision.mlpackage`, `SigLIP2Text.mlpackage`,
  `tokenizer-v1.bin`
- **Modifications made by this project.** The weights are used as published; no
  training, fine-tuning or distillation was performed. The following changes were
  made for on-device use, and are the reason this notice exists:
  - the PyTorch checkpoint was converted to Core ML, in a float16 build and an
    int8-weight-quantized build;
  - the vision tower's MAP attention-pooling head was re-implemented so it
    expresses no operation outside Core ML's supported set;
  - embedding L2 normalization was folded into the exported graph;
  - the text tower was exported with a static `[1, 64]` input and no attention
    mask, since padding to a fixed length is semantically required by this
    model's pooling;
  - the SentencePiece model was converted to a project-specific binary BPE
    artifact (`tokenizer-v1.bin`), reproducing the upstream tokenizer exactly
    rather than depending on a tokenizer runtime.

  These are format and packaging changes only. The license of the derived
  artifacts is unchanged: **Apache-2.0**.

- **NOTICE file:** the upstream distribution contains no `NOTICE` file, so
  Apache-2.0 section 4(d) imposes no additional attribution to propagate.

### No other third-party code is redistributed

The app links only Apple-provided frameworks at runtime (PhotoKit, Vision,
CoreML, Metal, Accelerate, SwiftUI, UIKit, SQLite). There are **no** Swift Package
Manager, CocoaPods or Carthage dependencies in `PhotoVault.xcodeproj`
(`XCRemoteSwiftPackageReference` appears zero times), so there is no other
bundled third-party source or binary.

## Build-time only — not redistributed

These produced the artifacts above and are not part of the app. Listed for
reproducibility and for anyone auditing the conversion.

| Component | Version | License |
|---|---|---|
| [coremltools](https://github.com/apple/coremltools) | 9.0 | BSD-3-Clause |
| [PyTorch](https://github.com/pytorch/pytorch) | 2.5.0 | BSD-3-Clause |
| [Transformers](https://github.com/huggingface/transformers) | 4.53.3 | Apache-2.0 |
| [Pillow](https://github.com/python-pillow/Pillow) | — | MIT-CMU |
| [NumPy](https://numpy.org) | — | BSD-3-Clause |
| [sentencepiece](https://github.com/google/sentencepiece) | — | Apache-2.0 |

`Pillow` matters more than its build-time role suggests: the Swift preprocessing
path (`PILResampler`) deliberately reproduces PIL's resampling arithmetic,
including its widened triangle support and its 8-bit clamp after each pass,
because approximating it produced embeddings the converted model had never seen.
It is a specification this project ports, not code it links.

## The offline gazetteer

`GazetteerData.swift` contains 252 place names with approximate coordinates, used
to turn a place mentioned in a query into a bounding box without a network call.
The coordinates are **hand-curated to roughly 10 km and are not authoritative**:
they are adequate for "photos taken around Beijing" and are not suitable for
navigation, surveying or any use where a wrong coordinate matters. No third-party
dataset is redistributed; the values were compiled for this project.

## Apache License 2.0 — full text

The following applies to SigLIP2 and to the `tokenizer-v1.bin` derived from it.

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```
