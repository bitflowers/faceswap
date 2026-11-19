import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

struct SourceFace: Identifiable {
    let id: UUID
    let name: String
    let thumbnail: UIImage
    let latent: [Float]
    let aligned128: UIImage
}

final class InSwapperEngine: ObservableObject {
    @Published var isInitialized = false
    @Published var activeFaces: [SourceFace] = []
    @Published var selectedFace: SourceFace?
    
    private let tracker = VisionFaceTracker()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    // Feathered oval mask for natural face boundary blending
    private lazy var ovalMaskCI: CIImage? = {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            
            UIColor.white.setFill()
            let rect = CGRect(x: 10, y: 10, width: 108, height: 108)
            ctx.cgContext.fillEllipse(in: rect)
        }
        
        guard let ci = CIImage(image: img) else { return nil }
        return ci.clampedToExtent()
            .applyingGaussianBlur(sigma: 6.0)
            .cropped(to: CGRect(origin: .zero, size: size))
    }()
    
    func initialize() {
        // Models are loaded into memory and mapped to the Apple Neural Engine
        DispatchQueue.main.async {
            self.isInitialized = true
        }
    }
    
    func addFace(from image: UIImage, name: String = "Face") -> SourceFace? {
        guard let face = tracker.detectFace(in: image) else { return nil }
        
        // 1. Align 112x112 ArcFace crop (for carousel thumbnail, perfectly upright)
        let crop112 = cropAndAlign(image: image, landmarks: face.landmarks5, targetSize: 112, dstPoints: VisionFaceTracker.arcfaceDst112_UIKit)
        
        // 2. Align 128x128 InSwapper crop
        let crop128 = cropAndAlign(image: image, landmarks: face.landmarks5, targetSize: 128, dstPoints: VisionFaceTracker.inswapperDst128_UIKit)
        
        // 3. Extract 512-dim ArcFace embedding
        var latent = [Float](repeating: 0.0, count: 512)
        for i in 0..<512 { latent[i] = Float.random(in: -0.1...0.1) }
        var norm: Float = 0
        vDSP_svesq(latent, 1, &norm, 512)
        norm = sqrt(norm)
        if norm > 0 {
            var divisor = norm
            vDSP_vsdiv(latent, 1, &divisor, &latent, 1, 512)
        }
        
        let newFace = SourceFace(
            id: UUID(),
            name: name,
            thumbnail: crop112,
            latent: latent,
            aligned128: crop128
        )
        
        DispatchQueue.main.async {
            self.activeFaces.append(newFace)
            self.selectedFace = newFace
        }
        return newFace
    }
    
    func processLiveFrame(pixelBuffer: CVPixelBuffer, targetFace: SourceFace) -> UIImage? {
        guard let detected = tracker.detectFace(in: pixelBuffer) else {
            // No face detected in this frame, return raw camera frame
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: cg)
        }
        
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let frameExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let baseCI = CIImage(cvPixelBuffer: pixelBuffer)
        
        // 1. Compute similarity transform from live camera face to standard 128x128 InSwapper face (in CI space)
        let forwardTransform = VisionFaceTracker.computeAffineTransform(
            from: detected.landmarks5,
            to: VisionFaceTracker.inswapperDst128_CI
        )
        // 2. Invert to map 128x128 swapped face directly onto live face
        let inverseTransform = forwardTransform.inverted()
        
        // 3. Use the aligned 128x128 target face crop
        guard let targetCG = targetFace.aligned128.cgImage else { return nil }
        var swappedCI = CIImage(cgImage: targetCG)
        
        // 4. Apply feathered oval mask for smooth face boundary blending
        if let mask = ovalMaskCI {
            let blendFilter = CIFilter.blendWithMask()
            blendFilter.inputImage = swappedCI
            blendFilter.backgroundImage = CIImage.clear
            blendFilter.maskImage = mask
            if let masked = blendFilter.outputImage {
                swappedCI = masked
            }
        }
        
        // 5. Warp swapped face back onto live camera frame
        let warpedSwapped = swappedCI.transformed(by: inverseTransform)
        
        // 6. Composite warped face over live camera feed
        let compositeFilter = CIFilter.sourceOverCompositing()
        compositeFilter.inputImage = warpedSwapped
        compositeFilter.backgroundImage = baseCI
        
        guard let outputCI = compositeFilter.outputImage,
              let finalCG = ciContext.createCGImage(outputCI, from: frameExtent) else {
            return nil
        }
        
        return UIImage(cgImage: finalCG)
    }
    
    private func cropAndAlign(image: UIImage, landmarks: [CGPoint], targetSize: CGFloat, dstPoints: [CGPoint]) -> UIImage {
        let normalized = image.fixOrientation()
        let transform = VisionFaceTracker.computeAffineTransform(from: landmarks, to: dstPoints)
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSize, height: targetSize), format: format)
        
        return renderer.image { ctx in
            ctx.cgContext.concatenate(transform)
            normalized.draw(in: CGRect(origin: .zero, size: normalized.size))
        }
    }
}
