import Vision
import CoreImage
import UIKit
import ImageIO

extension UIImage {
    func fixOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct DetectedFace {
    let boundingBox: CGRect // Normalized [0, 1]
    let landmarks5: [CGPoint] // Pixel coordinates: [leftEye, rightEye, nose, leftMouth, rightMouth]
    let confidence: Float
}

final class VisionFaceTracker {
    
    private let sequenceHandler = VNSequenceRequestHandler()
    
    // Standard InSwapper 128x128 destination 5-points (UIKit space: origin top-left, Y down)
    static let inswapperDst128_UIKit: [CGPoint] = [
        CGPoint(x: 46.2946, y: 51.6963), // Left eye
        CGPoint(x: 81.5318, y: 51.5014), // Right eye
        CGPoint(x: 64.0252, y: 71.7366), // Nose tip
        CGPoint(x: 49.5493, y: 92.3655), // Left mouth corner
        CGPoint(x: 78.7299, y: 92.2041)  // Right mouth corner
    ]
    
    // Standard ArcFace 112x112 destination 5-points (UIKit space: origin top-left, Y down)
    static let arcfaceDst112_UIKit: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041)
    ]
    
    // InSwapper 128x128 destination 5-points (Core Image space: origin bottom-left, Y up)
    static let inswapperDst128_CI: [CGPoint] = [
        CGPoint(x: 46.2946, y: 128.0 - 51.6963), // Left eye (~76.3)
        CGPoint(x: 81.5318, y: 128.0 - 51.5014), // Right eye (~76.5)
        CGPoint(x: 64.0252, y: 128.0 - 71.7366), // Nose tip (~56.3)
        CGPoint(x: 49.5493, y: 128.0 - 92.3655), // Left mouth (~35.6)
        CGPoint(x: 78.7299, y: 128.0 - 92.2041)  // Right mouth (~35.8)
    ]
    
    // Detect face in live camera CVPixelBuffer (returns landmarks in Core Image coordinate space: origin bottom-left, Y up)
    func detectFace(in pixelBuffer: CVPixelBuffer) -> DetectedFace? {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        let request = VNDetectFaceLandmarksRequest()
        request.preferBackgroundProcessing = false
        
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: CGImagePropertyOrientation.up)
            guard let observation = request.results?.first as? VNFaceObservation,
                  let landmarks = observation.landmarks else {
                return nil
            }
            
            return parseObservationCI(observation, landmarks: landmarks, imageWidth: width, imageHeight: height)
        } catch {
            return nil
        }
    }
    
    // Detect face in photo UIImage (returns landmarks in UIKit coordinate space: origin top-left, Y down)
    func detectFace(in image: UIImage) -> DetectedFace? {
        let normalized = image.fixOrientation()
        guard let cgImage = normalized.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation.up, options: [:])
        
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFaceObservation,
                  let landmarks = observation.landmarks else {
                return nil
            }
            return parseObservationUIKit(observation, landmarks: landmarks, imageWidth: width, imageHeight: height)
        } catch {
            return nil
        }
    }
    
    // Core Image coordinate space parser (Y=0 at bottom, Y increases upwards)
    private func parseObservationCI(_ observation: VNFaceObservation, landmarks: VNFaceLandmarks2D, imageWidth: CGFloat, imageHeight: CGFloat) -> DetectedFace? {
        let box = observation.boundingBox
        
        func toPixelCI(_ point: CGPoint) -> CGPoint {
            let px = (box.origin.x + point.x * box.width) * imageWidth
            let py = (box.origin.y + point.y * box.height) * imageHeight
            return CGPoint(x: px, y: py)
        }
        
        guard let leftEyePoints = landmarks.leftEye?.normalizedPoints, !leftEyePoints.isEmpty,
              let rightEyePoints = landmarks.rightEye?.normalizedPoints, !rightEyePoints.isEmpty,
              let nosePoints = landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints, !nosePoints.isEmpty,
              let outerLips = landmarks.outerLips?.normalizedPoints, outerLips.count >= 2 else {
            return nil
        }
        
        let leftEyeCenter = leftEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgLeftEye = CGPoint(x: leftEyeCenter.x / CGFloat(leftEyePoints.count), y: leftEyeCenter.y / CGFloat(leftEyePoints.count))
        
        let rightEyeCenter = rightEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgRightEye = CGPoint(x: rightEyeCenter.x / CGFloat(rightEyePoints.count), y: rightEyeCenter.y / CGFloat(rightEyePoints.count))
        
        let noseTip = nosePoints.last!
        let leftMouth = outerLips.first!
        let rightMouth = outerLips[outerLips.count / 2]
        
        return DetectedFace(
            boundingBox: box,
            landmarks5: [toPixelCI(avgLeftEye), toPixelCI(avgRightEye), toPixelCI(noseTip), toPixelCI(leftMouth), toPixelCI(rightMouth)],
            confidence: observation.confidence
        )
    }
    
    // UIKit coordinate space parser (Y=0 at top, Y increases downwards)
    private func parseObservationUIKit(_ observation: VNFaceObservation, landmarks: VNFaceLandmarks2D, imageWidth: CGFloat, imageHeight: CGFloat) -> DetectedFace? {
        let box = observation.boundingBox
        
        func toPixelUIKit(_ point: CGPoint) -> CGPoint {
            let px = (box.origin.x + point.x * box.width) * imageWidth
            let py = (1.0 - (box.origin.y + point.y * box.height)) * imageHeight
            return CGPoint(x: px, y: py)
        }
        
        guard let leftEyePoints = landmarks.leftEye?.normalizedPoints, !leftEyePoints.isEmpty,
              let rightEyePoints = landmarks.rightEye?.normalizedPoints, !rightEyePoints.isEmpty,
              let nosePoints = landmarks.noseCrest?.normalizedPoints ?? landmarks.nose?.normalizedPoints, !nosePoints.isEmpty,
              let outerLips = landmarks.outerLips?.normalizedPoints, outerLips.count >= 2 else {
            return nil
        }
        
        let leftEyeCenter = leftEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgLeftEye = CGPoint(x: leftEyeCenter.x / CGFloat(leftEyePoints.count), y: leftEyeCenter.y / CGFloat(leftEyePoints.count))
        
        let rightEyeCenter = rightEyePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avgRightEye = CGPoint(x: rightEyeCenter.x / CGFloat(rightEyePoints.count), y: rightEyeCenter.y / CGFloat(rightEyePoints.count))
        
        let noseTip = nosePoints.last!
        let leftMouth = outerLips.first!
        let rightMouth = outerLips[outerLips.count / 2]
        
        return DetectedFace(
            boundingBox: box,
            landmarks5: [toPixelUIKit(avgLeftEye), toPixelUIKit(avgRightEye), toPixelUIKit(noseTip), toPixelUIKit(leftMouth), toPixelUIKit(rightMouth)],
            confidence: observation.confidence
        )
    }
    
    /**
     * Umeyama 2D similarity transform mapping 5 source landmarks to 5 destination landmarks
     */
    static func computeAffineTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        guard src.count == 5 && dst.count == 5 else { return .identity }
        
        var srcMeanX: CGFloat = 0, srcMeanY: CGFloat = 0
        var dstMeanX: CGFloat = 0, dstMeanY: CGFloat = 0
        
        for i in 0..<5 {
            srcMeanX += src[i].x
            srcMeanY += src[i].y
            dstMeanX += dst[i].x
            dstMeanY += dst[i].y
        }
        srcMeanX /= 5.0
        srcMeanY /= 5.0
        dstMeanX /= 5.0
        dstMeanY /= 5.0
        
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syx: CGFloat = 0, syy: CGFloat = 0
        var srcVar: CGFloat = 0
        
        for i in 0..<5 {
            let sx = src[i].x - srcMeanX
            let sy = src[i].y - srcMeanY
            let dx = dst[i].x - dstMeanX
            let dy = dst[i].y - dstMeanY
            
            sxx += sx * dx
            sxy += sx * dy
            syx += sy * dx
            syy += sy * dy
            srcVar += sx * sx + sy * sy
        }
        
        let angle = atan2(sxy - syx, sxx + syy)
        let cosA = cos(angle)
        let sinA = sin(angle)
        
        let scale = srcVar > 1e-6 ? ((sxx + syy) * cosA + (sxy - syx) * sinA) / srcVar : 1.0
        
        let a = scale * cosA
        let b = scale * sinA
        let c = -scale * sinA
        let d = scale * cosA
        
        let tx = dstMeanX - (a * srcMeanX + c * srcMeanY)
        let ty = dstMeanY - (b * srcMeanX + d * srcMeanY)
        
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
