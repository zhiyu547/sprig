# Sprig

Sprig 意为一小枝新芽：短、轻、容易记，也呼应 Git 的分支。产品中文描述：轻量 Git 提交工作台。

## 图标

2026-09-22 选定「矿白负形」方案：暖白色圆角底板，黑色圆角六边形，内部用白色负形表达 Git 的三个提交节点与分支汇入。

采用黑白单色体系，用块面与留白形成清晰轮廓；兼顾 Dock、小尺寸工具栏和项目主页展示。

![Sprig 图标](../../native/Resources/Sprig.png)

- 生成方式：内置 ImageGen，基于视觉参考生成方案，选定后清理外沿透明区域。
- 原始资产：`native/Resources/Sprig.png`，1254 × 1254，RGBA。
- 打包：使用 macOS sips 生成 16–1024 px 标准分辨率，iconutil 生成 ICNS；不引入运行时图像库。
- 应用资源：`native/build/Sprig.app/Contents/Resources/Sprig.icns`。
- 应用窗口、欢迎页和关于页面共用应用图标；中英文 README 共用原始资产。

## 设计参考

研究了 [Linear 品牌规范](https://linear.app/brand)、[Raycast 官方素材](https://www.raycast.com/press) 和 [Things 官网](https://culturedcode.com/things/)中的留白、轮廓和材质处理。参考截图仅用于设计研究，不作为本项目的分发素材。

## 最终生成提示词

```text
Use case: logo-brand. Create one original finished premium macOS application icon for Sprig, a lightweight Git client.
Natural target: a single 1024 x 1024 icon with true transparent alpha outside the tile. Production-quality optical spacing, strong hierarchy, precise geometry.

Input roles: references 1–3 are official Linear, Raycast, Things screenshots for quality, geometry, breathing room and craft ONLY. Never copy their brands or marks. Reference 4 is an earlier Sprig idea rejected for looking like a generic enlarged toolbar button. Keep the concept of commits branching, but radically recompose its mark. User prefers one color family and obvious Git meaning. No text.

Direction "Mineral / negative-space seal".
A taut pale mineral-white continuous-corner macOS square tile, occupying 82% of canvas, equal margins, front view. Quiet, almost flat, fresh and crisp. No metallic rim or thick rounded bumper.
Centered within it, one striking custom BLACK SOLID EMBLEM, designed as a compact upright hexagonal pebble with very softly rounded vertices, NOT rotated into a diamond. The silhouette should be balanced, crisp, architectural, about 52% tile width and 57% tile height. Cut into this solid dark shape a clear WHITE NEGATIVE-SPACE GIT BRANCH GRAPH: three small round commit apertures, one near upper-left, one near lower-left, one near upper-right; the two left apertures linked vertically by a precise narrow channel, and the upper-right aperture joined to the left channel via one smooth diagonal merging turn. This entire white branching counter-shape is cut cleanly through the black body, with deliberate generous margins to every outer edge. Node diameter only modestly wider than track width, avoid enormous holes. The connected negative space is essential. The thick black silhouette and white branching void should lock together as a unique compact seal that remains recognizable with no tile at all. The outcome is a distinctive ownable emblem, not a stock stroke icon.
Use ONLY warm-white and near-black, no colored accents, no gradients on the symbol. A microscopic surface emboss at most, nearly print-flat, crisp and premium. Precise negative space like carefully cut typography, calm optical balance. Visible Git branch relationship with three terminals. Geometric restraint and immediate recognition rather than literal plant or monogram.
Single app icon only, no contact sheet. No words, watermark, smaller duplicate, UI, background scene, gray checkerboard. No official Git orange diamond, no copied reference symbol, no circuit-board decoration, no shadows within the logo, no shiny 3D or swollen plastic, no button bezel, no generic hollow-ring graph placed on a white square.
```

## 外沿清理提示词

```text
Use case: precise-object-edit.
Input image is the SELECTED FINAL Sprig macOS app icon. Perform production edge cleanup ONLY, not a redesign.
Preserve EXACTLY the central black rounded upright hexagon, the three-node white Git branch cutout, its geometry, position, proportions, palette, the subtle off-white tile tone, and the overall design composition.
Only fix the outermost silhouette of the white rounded-square macOS tile: remove all tiny white specks, jagged white protrusions and stray isolated pixels outside its intended continuous smooth rounded-square perimeter. Make the four outer edges and corners mathematically smooth, symmetrical and clean, with proper antialiasing against actual transparent alpha. Outside tile must be completely transparent, with no visible checkerboard or background. Keep the original equal outer margins and icon scale. Do not add a shadow, frame, border, bevel, text, decoration, or new material effect.
Return one square high resolution PNG icon with alpha. The chosen branding inside the tile must remain visually unchanged.
```

## 权利说明

Copyright © 2026 zhiyu（在可授予权利的范围内）。本图标为本项目生成；视觉研究参考的第三方名称、标识和截图归各自权利人所有，不随本项目分发，也不表示任何背书或合作关系。生成提示词不构成对独占版权或商标权的保证。项目图标遵守仓库许可，名称和标识不得用于冒充官方发布或暗示背书。
