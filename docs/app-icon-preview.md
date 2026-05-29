# App Icon Preview

All sizes generated from the 1024×1024 source (`diskjockey.png`) via `sips`.

| Size | Slots | File |
|------|-------|------|
| 16×16 | 16@1x | [icon_16x16.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_16x16.png) |
| 32×32 | 16@2x · 32@1x | [icon_32x32.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_32x32.png) |
| 64×64 | 32@2x | [icon_64x64.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_64x64.png) |
| 128×128 | 128@1x | [icon_128x128.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_128x128.png) |
| 256×256 | 128@2x · 256@1x | [icon_256x256.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_256x256.png) |
| 512×512 | 256@2x · 512@1x | [icon_512x512.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_512x512.png) |
| 1024×1024 | 512@2x (source) | [diskjockey.png](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/diskjockey.png) |

## Preview

### 16×16
![16x16](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_16x16.png)

### 32×32
![32x32](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_32x32.png)

### 64×64
![64x64](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_64x64.png)

### 128×128
![128x128](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_128x128.png)

### 256×256
![256x256](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

### 512×512
![512x512](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/icon_512x512.png)

### 1024×1024 (source)
![1024x1024](../DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset/diskjockey.png)

## Regenerating

```sh
cd DiskJockeyApplication/Assets.xcassets/AppIcon.appiconset
for size in 16 32 64 128 256 512; do
  sips -z $size $size diskjockey.png --out "icon_${size}x${size}.png"
done
```
