import CoreImage

struct ScanEnhancementProfile {
    let background: CIImage?
    let contrast: Double
    var protectedContent: CIImage? = nil
    static let conservative = ScanEnhancementProfile(background: nil, contrast: 1.08)
}

/// Matches ColorEnhancement.kt: all statistics and division operate in sRGB, not linear light.
enum ScanColorEnhancement {
    static let analysisEdge: CGFloat = 768
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: colorSpace, .outputColorSpace: colorSpace])

    static func analyze(_ image: CIImage) -> ScanEnhancementProfile {
        let extent = image.extent
        let scale = min(1, analysisEdge / max(extent.width, extent.height))
        let w = max(2, Int((extent.width * scale).rounded()))
        let h = max(2, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height)).cropped(to: bounds)
        func closing(_ size: Int, source: CIImage? = nil) -> CIImage {
            let radius = max(1, Int((Double(size) * min(1, Double(max(extent.width, extent.height)) / 768)).rounded()) / 2)
            let parameters: [String: Any] = ["inputWidth": radius * 2 + 1, "inputHeight": radius * 2 + 1]
            return (source ?? small).clampedToExtent()
                .applyingFilter("CIMorphologyRectangleMaximum", parameters: parameters)
                .applyingFilter("CIMorphologyRectangleMinimum", parameters: parameters).cropped(to: bounds)
        }
        let pixels = bytes(small, width: w, height: h)
        var paper = bytes(closing(15), width: w, height: h)
        let broad = bytes(closing(31), width: w, height: h)
        let count = w * h
        var histograms = Array(repeating: Array(repeating: 0, count: 256), count: 3)
        var brightness = Array(repeating: 0, count: 256)
        for i in 0..<count {
            var total = 0
            // Morphology spreads resampling overshoot around text. Use actual samples
            // for the paper reference, not the upper tail of the closed image.
            for c in 0..<3 { histograms[c][Int(pixels[i * 4 + c])] += 1; total += Int(broad[i * 4 + c]) }
            brightness[total / 3] += 1
        }
        let reference = histograms.map { percentile($0, count: count, fraction: 0.9) }
        let referenceMean = Double(reference.reduce(0, +)) / 3
        guard referenceMean >= 90, Double(reference.max()! - reference.min()!) / referenceMean <= 0.35 else { return .conservative }
        let varying = percentile(brightness, count: count, fraction: 0.9) - percentile(brightness, count: count, fraction: 0.1) > 6
        var invalid = Array(repeating: false, count: count)
        var content = Array(repeating: false, count: count)
        for i in 0..<count {
            var low = 10.0, high = 0.0, difference = 0
            var colorLow = 10.0, colorHigh = 0.0, colorTotal = 0.0
            for c in 0..<3 {
                let ratio = Double(paper[i * 4 + c]) / Double(max(1, reference[c]))
                low = min(low, ratio); high = max(high, ratio)
                difference = max(difference, Int(broad[i * 4 + c]) - Int(paper[i * 4 + c]))
                let color = Double(broad[i * 4 + c]) / Double(max(1, reference[c]))
                colorLow = min(colorLow, color); colorHigh = max(colorHigh, color); colorTotal += color
            }
            invalid[i] = high - low > 0.12 || difference > 18
            content[i] = (colorHigh - colorLow) / max(0.01, colorTotal / 3) > 0.35
        }
        for top in stride(from: 0, to: h, by: 16) {
            for left in stride(from: 0, to: w, by: 16) {
                var dark = 0, edges = 0, samples = 0
                for y in top..<min(h, top + 16) {
                    for x in left..<min(w, left + 16) {
                        let i = (y * w + x) * 4
                        let value = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                        let background = Int(paper[i]) + Int(paper[i + 1]) + Int(paper[i + 2])
                        if Double(value) < Double(background) * 0.78 { dark += 1 }
                        if x > 0 {
                            let difference = abs(Int(pixels[i]) - Int(pixels[i - 4])) + abs(Int(pixels[i + 1]) - Int(pixels[i - 3])) + abs(Int(pixels[i + 2]) - Int(pixels[i - 2]))
                            if difference > 120 { edges += 1 }
                        }
                        samples += 1
                    }
                }
                if Double(dark) > Double(samples) * 0.4 && Double(edges) > Double(samples) * 0.45 {
                    for y in top..<min(h, top + 16) { for x in left..<min(w, left + 16) {
                        invalid[y * w + x] = true; content[y * w + x] = true
                    } }
                }
            }
        }
        protectPanels(paper, invalid: &content, width: w, height: h, reference: referenceMean)
        for i in 0..<count where content[i] { invalid[i] = true }
        guard Double(invalid.filter { $0 }.count) <= Double(count) * 0.45 else { return .conservative }
        let protected = expandMask(content, width: w, height: h, radius: 2)
        if varying {
            var luminance = pixels
            for i in 0..<count {
                let value = UInt8((Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) + 1) / 3)
                for c in 0..<3 { luminance[i * 4 + c] = value }
            }
            let gray = CIImage(bitmapData: Data(luminance), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
            let narrow = bytes(closing(5, source: gray), width: w, height: h)
            let wide = bytes(closing(15, source: gray), width: w, height: h)
            let ink = (0..<count).map { i in
                Double(luminance[i * 4]) < Double(narrow[i * 4]) * 0.97 || Double(luminance[i * 4]) < Double(wide[i * 4]) * 0.80
            }
            // A one-pixel margin removes colored JPEG fringes without bridging line gaps.
            var missingPaper = expandMask(ink, width: w, height: h, radius: 1)
            for i in 0..<count where protected[i] { missingPaper[i] = true }
            guard Double(missingPaper.filter { !$0 }.count) >= Double(count) * 0.05 else { return .conservative }
            var clean = pixels
            fillPaper(&clean, invalid: missingPaper, width: w, height: h)
            // Preserve real RGB triplets. Per-channel closing here creates blue paper
            // estimates around blue lettering, which become yellow correction halos.
            paper = clean
        } else { for i in 0..<count { for c in 0..<3 { paper[i * 4 + c] = UInt8(reference[c]) } } }

        var inkHistogram = Array(repeating: 0, count: 256), inkCount = 0
        for i in 0..<count {
            var total = 0.0, low = 255.0, high = 0.0
            for c in 0..<3 {
                // Identify ink before limiting gain; deeply shadowed paper is still paper.
                let value = min(255, Double(pixels[i * 4 + c]) * 255 / max(1, Double(paper[i * 4 + c])))
                total += value; low = min(low, value); high = max(high, value)
            }
            let value = Int((total / 3).rounded())
            if !invalid[i] && (20...190).contains(value) && high - low < 40 { inkHistogram[value] += 1; inkCount += 1 }
            paper[i * 4 + 3] = 255
        }
        let contrast = Double(inkCount) > Double(count) * 0.002
            ? min(1.6, max(1.08, 207 / Double(255 - percentile(inkHistogram, count: inkCount, fraction: 0.1)))) : 1.08
        let map = CIImage(bitmapData: Data(paper), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
            .clampedToExtent().applyingFilter("CIMedianFilter").cropped(to: bounds)
        // Materialize the small map once; neither preview nor export repeats analysis.
        guard let cgImage = context.createCGImage(map, from: bounds) else { return .conservative }
        var protection: CIImage?
        if protected.contains(true) {
            var mask = [UInt8](repeating: 255, count: count * 4)
            for i in 0..<count { for c in 0..<3 { mask[i * 4 + c] = protected[i] ? 255 : 0 } }
            protection = CIImage(bitmapData: Data(mask), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
        }
        return ScanEnhancementProfile(background: CIImage(cgImage: cgImage), contrast: contrast, protectedContent: protection)
    }

    static func apply(_ image: CIImage, profile: ScanEnhancementProfile) -> CIImage? {
        guard let background = profile.background else {
            return image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputBrightnessKey: -0.04])
        }
        let map = background.transformed(by: CGAffineTransform(scaleX: image.extent.width / background.extent.width,
            y: image.extent.height / background.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY)).clampedToExtent()
        let protection = profile.protectedContent?.transformed(by: CGAffineTransform(
            scaleX: image.extent.width / background.extent.width, y: image.extent.height / background.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY)).clampedToExtent()
            ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        return kernel?.apply(extent: image.extent, arguments: [image, map, protection, profile.contrast])
    }

    private static let kernel = CIColorKernel(source: """
        kernel vec4 enhanceDocument(__sample pixel, __sample background, __sample protection, float contrast) {
            vec3 corrected = min(pixel.rgb / max(background.rgb, vec3(0.25)), vec3(1.0));
            vec3 deficit = vec3(1.0) - corrected;
            float darkest = max(deficit.r, max(deficit.g, deficit.b));
            float t = clamp((darkest - 0.0083333333) / 0.05, 0.0, 1.0);
            float paperCurve = max(t * t * (3.0 - 2.0 * t), protection.r);
            return vec4(clamp(vec3(1.0) - deficit * paperCurve * contrast, 0.0, 1.0), 1.0);
        }
        """)

    private static func bytes(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        }
        return data
    }

    private static func neighbor(_ i: Int, _ direction: Int, _ w: Int, _ h: Int) -> Int {
        switch direction {
        case 0: return i % w > 0 ? i - 1 : -1
        case 1: return i % w + 1 < w ? i + 1 : -1
        case 2: return i >= w ? i - w : -1
        default: return i + w < w * h ? i + w : -1
        }
    }

    private static func protectPanels(_ paper: [UInt8], invalid: inout [Bool], width w: Int, height h: Int, reference: Double) {
        var visited = Array(repeating: false, count: w * h), queue = Array(repeating: 0, count: w * h)
        func dark(_ i: Int) -> Bool { return Double(Int(paper[i * 4]) + Int(paper[i * 4 + 1]) + Int(paper[i * 4 + 2])) < reference * 3 * 0.97 }
        for start in visited.indices {
            if visited[start] || !dark(start) { continue }
            var head = 0, tail = 1, x0 = w, y0 = h, x1 = 0, y1 = 0
            queue[0] = start; visited[start] = true
            while head < tail {
                let i = queue[head]; head += 1
                x0 = min(x0, i % w); x1 = max(x1, i % w); y0 = min(y0, i / w); y1 = max(y1, i / w)
                for direction in 0..<4 {
                    let next = neighbor(i, direction, w, h)
                    if next >= 0 && !visited[next] && dark(next) { visited[next] = true; queue[tail] = next; tail += 1 }
                }
            }
            if x0 > 1 && y0 > 1 && x1 < w - 2 && y1 < h - 2 && Double(tail) > Double(w * h) * 0.005 && Double(tail) < Double(w * h) * 0.4 && Double(tail) > Double((x1 - x0 + 1) * (y1 - y0 + 1)) * 0.9 {
                for j in 0..<tail { invalid[queue[j]] = true }
            }
        }
    }

    private static func fillPaper(_ paper: inout [UInt8], invalid: [Bool], width w: Int, height h: Int) {
        var known = invalid.map { !$0 }, queue = Array(repeating: 0, count: w * h)
        var head = 0, tail = 0
        for i in known.indices { if known[i] { queue[tail] = i; tail += 1 } }
        while head < tail {
            let i = queue[head]; head += 1
            for direction in 0..<4 {
                let next = neighbor(i, direction, w, h)
                if next >= 0 && !known[next] {
                    for c in 0..<3 { paper[next * 4 + c] = paper[i * 4 + c] }
                    known[next] = true; queue[tail] = next; tail += 1
                }
            }
        }
        var current = paper, next = paper
        if w > 2 && h > 2 {
            for _ in 0..<12 {
                for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                    let i = y * w + x
                    if invalid[i] { for c in 0..<3 {
                        let sum = Int(current[(i - 1) * 4 + c]) + Int(current[(i + 1) * 4 + c])
                            + Int(current[(i - w) * 4 + c]) + Int(current[(i + w) * 4 + c])
                        next[i * 4 + c] = UInt8((sum + 2) / 4)
                    } }
                } }
                swap(&current, &next)
            }
        }
        paper = current
    }

    private static func percentile(_ histogram: [Int], count: Int, fraction: Double) -> Int {
        let target = max(1, Int(ceil(Double(count) * fraction)))
        var total = 0
        for i in histogram.indices { total += histogram[i]; if total >= target { return i } }
        return 255
    }

    private static func expandMask(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        var expanded = mask
        // Antialiased borders around printed panels are not clean paper samples.
        for i in mask.indices where mask[i] {
            let x = i % w, y = i / w
            for yy in max(0, y - radius)...min(h - 1, y + radius) {
                for xx in max(0, x - radius)...min(w - 1, x + radius) { expanded[yy * w + xx] = true }
            }
        }
        return expanded
    }
}
